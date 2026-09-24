import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/app_theme.dart';
import '../../utils/search_normalize.dart';
import '../../widgets/official_badge.dart';
import '../../services/follow_service.dart';
import '../../services/invite_service.dart';
import '../../services/notification_service.dart';
import '../profile/user_profile_screen.dart';

class FollowSearchScreen extends StatefulWidget {
  const FollowSearchScreen({super.key});

  @override
  State<FollowSearchScreen> createState() => _FollowSearchScreenState();
}

class _FollowSearchScreenState extends State<FollowSearchScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  User? get _currentUser => FirebaseAuth.instance.currentUser;

  // ID・ニックネーム検索
  final _idController = TextEditingController();
  bool _idSearching = false;
  List<Map<String, dynamic>> _idResults = [];

  final Set<String> _togglingIds = {};
  String _mySearchId = '';

  // uid → 所属チーム名の取得Future（同名ユーザーの見分け用）。
  // Future自体をキャッシュして、再ビルドでも同じ結果を使い回し、重複クエリを防ぐ。
  final Map<String, Future<String?>> _teamNameFutures = {};

  /// ユーザーの所属チーム名を1件取得（検索結果の見分け用）。
  Future<String?> _resolveTeamName(String uid) {
    if (uid.isEmpty) return Future.value(null);
    return _teamNameFutures.putIfAbsent(uid, () async {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('teams')
            .where('memberIds', arrayContains: uid)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          final d = snap.docs.first.data();
          final n = (d['name'] ?? d['teamName'] ?? '').toString();
          if (n.isNotEmpty) return n;
        }
        return null;
      } catch (_) {
        return null;
      }
    });
  }

  // 招待コード（もらう：入力／渡す：自分のコード表示）
  final _redeemController = TextEditingController();
  bool _redeeming = false;
  String? _myInviteCode;
  bool _generatingCode = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // QRタブ（渡す側）を初めて開いたときに自分の招待コードを発行する
    _tabController.addListener(() {
      if (_tabController.index == 1 && _myInviteCode == null && !_generatingCode) {
        _generateMyCode();
      }
    });
    _loadMySearchId();
    FollowService.instance.addListener(_onFollowChanged);
  }

  Future<void> _generateMyCode() async {
    setState(() => _generatingCode = true);
    try {
      final code = await InviteService.createInvite();
      if (mounted) setState(() => _myInviteCode = code);
    } catch (_) {
      // 失敗時は QR とリンクがあるので致命的ではない
    } finally {
      if (mounted) setState(() => _generatingCode = false);
    }
  }

  // ── 招待コードを引き換える（友達・チーム・大会共通） ──
  Future<void> _redeemInviteCode() async {
    final code = _redeemController.text.trim();
    if (code.isEmpty || _redeeming) return;
    setState(() => _redeeming = true);
    try {
      final result = await InviteService.redeemInvite(code);
      if (!mounted) return;
      _redeemController.clear();
      FocusScope.of(context).unfocus();

      final referrerName = (result['referrerName'] ?? '') as String? ?? '';
      final teamName = (result['teamName'] ?? '') as String? ?? '';
      final requestedTeam = result['requestedTeam'] == true;
      final joinedTeam = result['joinedTeam'] == true;

      final messages = <String>[];
      if (referrerName.isNotEmpty) messages.add('$referrerNameさんと友達になりました');
      if (teamName.isNotEmpty) {
        if (requestedTeam) {
          messages.add('チーム「$teamName」に参加リクエストを送りました（承認待ち）');
        } else if (joinedTeam) {
          messages.add('チーム「$teamName」に参加しました');
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(messages.isEmpty ? '招待コードを引き換えました！' : '${messages.join(' / ')}！'),
        backgroundColor: AppTheme.success,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('招待コードが無効か、期限切れの可能性があります'), backgroundColor: AppTheme.warning));
      }
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  void _onFollowChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadMySearchId() async {
    if (_currentUser == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .get();
    if (doc.exists && mounted) {
      setState(() {
        _mySearchId = (doc.data()?['searchId'] as String?) ?? '';
      });
    }
  }

  @override
  void dispose() {
    FollowService.instance.removeListener(_onFollowChanged);
    _tabController.dispose();
    _idController.dispose();
    _redeemController.dispose();
    super.dispose();
  }

  // ── ID・ニックネーム検索 ──
  // ①完全一致（searchId／正規化ID） → ②正規化フィールドの前置一致クエリ
  // → ③あいまい一致（部分一致＋編集距離1のタイポ救済）の3段構え。
  // 正規化（カナ→かな・全角→半角・空白除去・小文字化）は保存側の
  // nicknameNorm / searchIdNorm（syncUserSearchNorm が自動維持）と同一仕様。
  Future<void> _searchById() async {
    final query = _idController.text.trim().replaceAll('@', '');
    if (query.isEmpty) return;
    final qNorm = normalizeForSearch(query);
    setState(() => _idSearching = true);

    try {
      final users = FirebaseFirestore.instance.collection('users');
      List<Map<String, dynamic>> results = [];
      final addedUids = <String>{};

      void addDocs(Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
        for (final doc in docs) {
          if (doc.id == _currentUser?.uid) continue;
          if (addedUids.contains(doc.id)) continue;
          final data = doc.data();
          data['uid'] = doc.id;
          results.add(data);
          addedUids.add(doc.id);
        }
      }

      // ① 完全一致（従来の searchId ＋ 正規化ID）
      final exactSnaps = await Future.wait([
        users.where('searchId', isEqualTo: query).limit(5).get(),
        if (qNorm.isNotEmpty) users.where('searchIdNorm', isEqualTo: qNorm).limit(5).get(),
      ]);
      for (final s in exactSnaps) {
        addDocs(s.docs);
      }

      // ② 正規化フィールドの前置一致（インデックスで引くのでユーザー数が増えてもOK）
      if (qNorm.isNotEmpty) {
        final prefixEnd = '$qNorm\uf8ff';
        final prefixSnaps = await Future.wait([
          users
              .where('nicknameNorm', isGreaterThanOrEqualTo: qNorm)
              .where('nicknameNorm', isLessThan: prefixEnd)
              .limit(20)
              .get(),
          users
              .where('searchIdNorm', isGreaterThanOrEqualTo: qNorm)
              .where('searchIdNorm', isLessThan: prefixEnd)
              .limit(20)
              .get(),
        ]);
        for (final s in prefixSnaps) {
          addDocs(s.docs);
        }
      }

      // ③ ヒットが少なければ、あいまい一致（部分一致＋編集距離1）にフォールバック。
      //    正規化フィールド未設定の旧データもここで拾える。
      if (qNorm.isNotEmpty && results.length < 5) {
        final allSnap = await users.limit(500).get();
        // 公式アカウントは limit で漏れないよう必ず検索対象に含める
        final officialSnap = await users.where('isOfficial', isEqualTo: true).get();
        for (final doc in [...allSnap.docs, ...officialSnap.docs]) {
          if (doc.id == _currentUser?.uid) continue;
          if (addedUids.contains(doc.id)) continue;
          final data = doc.data();
          final sid = normalizeForSearch((data['searchId'] ?? '').toString());
          final nick = normalizeForSearch((data['nickname'] ?? '').toString());
          final hit = sid.contains(qNorm) ||
              nick.contains(qNorm) ||
              isEditDistanceLe1(sid, qNorm) ||
              isEditDistanceLe1(nick, qNorm) ||
              (nick.length > qNorm.length && isEditDistanceLe1(nick.substring(0, qNorm.length), qNorm));
          if (hit) {
            data['uid'] = doc.id;
            results.add(data);
            addedUids.add(doc.id);
          }
        }
      }

      setState(() {
        _idResults = results;
        _idSearching = false;
      });
    } catch (e) {
      setState(() => _idSearching = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('検索エラー: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  // ── フォロー切替 ──
  Future<void> _toggleFollow(String targetUid, String targetName) async {
    if (_currentUser == null || _togglingIds.contains(targetUid)) return;
    final myUid = _currentUser!.uid;
    final wasFollowing = FollowService.instance.isFollowing(targetUid);

    setState(() => _togglingIds.add(targetUid));

    try {
      // 通知用に自分の情報を先に取得
      String myNickname = '不明';
      String myAvatarUrl = '';
      if (!wasFollowing) {
        final myDoc = await FirebaseFirestore.instance.collection('users').doc(myUid).get();
        final myData = myDoc.data() ?? {};
        myNickname = (myData['nickname'] as String?) ?? '不明';
        myAvatarUrl = (myData['avatarUrl'] as String?) ?? '';
      }

      await FollowService.instance.toggleFollow(
        targetUid: targetUid,
        targetNickname: targetName,
      );
      // UI は FollowService のリスナー (_onFollowChanged) が自動更新

      if (!wasFollowing) {
        NotificationService.sendFollowNotification(
          targetUserId: targetUid,
          senderId: myUid,
          senderName: myNickname,
          senderAvatar: myAvatarUrl,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(wasFollowing
                ? '$targetNameさんのフォローを解除しました'
                : '$targetNameさんをフォローしました！'),
            backgroundColor: wasFollowing ? AppTheme.warning : AppTheme.success));
      }
    } catch (e) {
      debugPrint('フォロー切替エラー: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('フォロー操作に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _togglingIds.remove(targetUid));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('友達をさがす'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: AppTheme.accentColor,
          indicatorWeight: 3,
          tabs: const [
            Tab(text: 'ID・ニックネーム検索'),
            Tab(text: 'QRコード'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildIdSearchTab(),
          _buildQrCodeTab(),
        ],
      ),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━
  // ID検索タブ
  // ━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildIdSearchTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          // ── 招待コードを入力（もらった側の入口） ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.confirmation_number_outlined, size: 18, color: AppTheme.accentColor),
                  SizedBox(width: 6),
                  Text('招待コードをもらった方',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _redeemController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        hintText: '例: A2K7PQ',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _redeeming ? null : _redeemInviteCode,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 46),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _redeeming
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('引き換え', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha:0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: AppTheme.primaryColor, size: 20),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '相手のIDまたはニックネームで検索できます。',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _idController,
            builder: (context, value, child) {
              return TextField(
                controller: _idController,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: '例: @nakamura123 またはニックネーム',
                  hintStyle: const TextStyle(fontSize: 15, color: AppTheme.textHint),
                  prefixIcon: const Icon(Icons.alternate_email, size: 22),
                  suffixIcon: value.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _idController.clear();
                            setState(() => _idResults = []);
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey[300]!)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey[300]!)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                ),
                onSubmitted: (_) => _searchById(),
              );
            },
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _idController,
            builder: (context, value, child) {
              return ElevatedButton(
                onPressed: value.text.isNotEmpty ? _searchById : null,
                style: ElevatedButton.styleFrom(disabledBackgroundColor: Colors.grey[300]),
                child: _idSearching
                    ? const SizedBox(height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('検索する', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              );
            },
          ),
          if (_idResults.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('${_idResults.length}件見つかりました',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            ..._idResults.map((u) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildUserCard(u),
                )),
          ] else if (!_idSearching && _idController.text.isNotEmpty && _idResults.isEmpty) ...[
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  Icon(Icons.person_off_outlined, size: 48, color: AppTheme.textHint),
                  const SizedBox(height: 12),
                  const Text('ユーザーが見つかりませんでした',
                      style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━
  // QRコードタブ
  // ━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildQrCodeTab() {
    final qrData = _mySearchId.isNotEmpty ? 'sofvo://friend/$_mySearchId' : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha:0.04), blurRadius: 8, offset: const Offset(0, 2)),
              ],
            ),
            child: Column(
              children: [
                const Text('マイQRコード',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                const SizedBox(height: 4),
                const Text('相手にこのQRコードを読み取ってもらいましょう',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                const SizedBox(height: 20),
                if (qrData.isNotEmpty)
                  Column(
                    children: [
                      QrImageView(
                        data: qrData,
                        version: QrVersions.auto,
                        size: 180,
                        backgroundColor: Colors.white,
                      ),
                      const SizedBox(height: 12),
                      Text('@$_mySearchId',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                    ],
                  )
                else
                  Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.qr_code_2, size: 48, color: AppTheme.textHint),
                        SizedBox(height: 8),
                        Text('IDが未設定です', style: TextStyle(fontSize: 13, color: AppTheme.textHint)),
                        Text('プロフィールでIDを設定してください', style: TextStyle(fontSize: 11, color: AppTheme.textHint)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── 自分の招待コード（QRを読めない相手にはコード/リンクで） ──
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
              ],
            ),
            child: Column(
              children: [
                const Text('わたしの招待コード',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                const SizedBox(height: 4),
                const Text('コードを伝えると、相手は登録画面や「招待コードをもらった方」で入力するだけで友達になれます',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
                const SizedBox(height: 16),
                if (_myInviteCode == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: CircularProgressIndicator(color: AppTheme.primaryColor),
                  )
                else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _myInviteCode!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 6, color: AppTheme.primaryColor),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: InviteService.shareText(code: _myInviteCode!)));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('招待メッセージをコピーしました'), backgroundColor: AppTheme.success));
                        },
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('コピー', style: TextStyle(fontSize: 14)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryColor,
                          side: const BorderSide(color: AppTheme.primaryColor),
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          final text = Uri.encodeComponent(InviteService.shareText(code: _myInviteCode!));
                          launchUrl(Uri.parse('https://line.me/R/share?text=$text'),
                              mode: LaunchMode.externalApplication);
                        },
                        icon: const Icon(Icons.chat_bubble, size: 18),
                        label: const Text('LINE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF06C755),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _openFriendScanner,
            icon: const Icon(Icons.qr_code_scanner, size: 22),
            label: const Text('QRコードを読み取る', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _openFriendScanner() {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('カメラ機能はネイティブアプリで利用できます'), backgroundColor: AppTheme.info),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FriendQRScannerPage(
          onScanned: (code) async {
            Navigator.pop(context);
            await _handleFriendQR(code);
          },
        ),
      ),
    );
  }

  Future<void> _handleFriendQR(String code) async {
    // フォーマット: sofvo://friend/{searchId}
    if (!code.startsWith('sofvo://friend/')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('友達追加用のQRコードではありません'), backgroundColor: AppTheme.warning),
        );
      }
      return;
    }

    final searchId = code.replaceFirst('sofvo://friend/', '').trim();
    if (searchId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('QRコードの形式が正しくありません'), backgroundColor: AppTheme.warning),
        );
      }
      return;
    }

    // 自分自身チェック
    if (searchId == _mySearchId) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自分のQRコードです'), backgroundColor: AppTheme.info),
        );
      }
      return;
    }

    // ユーザー検索
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('searchId', isEqualTo: searchId)
        .limit(1)
        .get();

    if (snap.docs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ユーザーが見つかりませんでした'), backgroundColor: AppTheme.warning),
        );
      }
      return;
    }

    final userId = snap.docs.first.id;
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UserProfileScreen(userId: userId)),
      );
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━
  // ユーザーカード
  // ━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildUserCard(Map<String, dynamic> user) {
    final uid = user['uid'] ?? '';
    final nickname = (user['nickname'] ?? '名無し').toString();
    final searchId = (user['searchId'] ?? '').toString();
    final experience = (user['experience'] ?? '').toString();
    final avatarUrl = (user['avatarUrl'] ?? '').toString();
    final area = user['area'] is String
        ? user['area']
        : user['area'] is Map
            ? '${(user['area'] as Map)['prefecture'] ?? ''}'
            : '';
    final bio = (user['bio'] ?? '').toString();
    final isFollowing = FollowService.instance.isFollowing(uid);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => UserProfileScreen(userId: uid)),
        );
      },
      child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha:0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          avatarUrl.isNotEmpty
              ? CircleAvatar(radius: 26, backgroundImage: NetworkImage(avatarUrl),
                  backgroundColor: AppTheme.primaryColor.withValues(alpha:0.12))
              : CircleAvatar(
                  radius: 26,
                  backgroundColor: AppTheme.primaryColor.withValues(alpha:0.12),
                  child: Text(nickname.isNotEmpty ? nickname[0] : '?',
                      style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold, fontSize: 20)),
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(nickname,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (user['isOfficial'] == true)
                      const OfficialBadge(size: 16),
                    if (experience.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: AppTheme.accentColor.withValues(alpha:0.1), borderRadius: BorderRadius.circular(8)),
                        child: Text(experience,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.accentColor)),
                      ),
                    ],
                  ],
                ),
                if (searchId.isNotEmpty)
                  Text('@$searchId', style: const TextStyle(fontSize: 13, color: AppTheme.textHint)),
                if (area.isNotEmpty)
                  Row(children: [
                    const Icon(Icons.location_on, size: 12, color: AppTheme.textSecondary),
                    const SizedBox(width: 2),
                    Flexible(child: Text(area,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        overflow: TextOverflow.ellipsis)),
                  ]),
                // 所属チーム名（同名の人を見分けやすくする）
                FutureBuilder<String?>(
                  future: _resolveTeamName(uid),
                  builder: (context, snap) {
                    final team = snap.data;
                    if (team == null || team.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(children: [
                        const Icon(Icons.groups, size: 12, color: AppTheme.textSecondary),
                        const SizedBox(width: 3),
                        Flexible(child: Text(team,
                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                            overflow: TextOverflow.ellipsis)),
                      ]),
                    );
                  },
                ),
                if (bio.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(bio, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          isFollowing
              ? OutlinedButton(
                  onPressed: () => _toggleFollow(uid, nickname),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                      side: BorderSide(color: Colors.grey[300]!),
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                  child: const Text('フォロー中', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                )
              : ElevatedButton(
                  onPressed: () => _toggleFollow(uid, nickname),
                  style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                  child: const Text('フォロー', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ),
        ],
      ),
    ),
    );
  }
}

// ━━━ 友達QRスキャナーページ ━━━
class _FriendQRScannerPage extends StatefulWidget {
  final Function(String) onScanned;
  const _FriendQRScannerPage({required this.onScanned});

  @override
  State<_FriendQRScannerPage> createState() => _FriendQRScannerPageState();
}

class _FriendQRScannerPageState extends State<_FriendQRScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _hasScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('友達のQRコードをスキャン'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_hasScanned) return;
              final barcode = capture.barcodes.firstOrNull;
              if (barcode?.rawValue != null) {
                setState(() => _hasScanned = true);
                widget.onScanned(barcode!.rawValue!);
              }
            },
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.accentColor, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: const Text(
              '相手のQRコードを枠内に合わせてください',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
