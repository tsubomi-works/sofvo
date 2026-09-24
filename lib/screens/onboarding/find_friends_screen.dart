import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';
import '../../main.dart' show navigatorKey;
import '../../services/follow_service.dart';
import '../../services/invite_service.dart';
import '../../services/notification_service.dart';
import '../follow/follow_search_screen.dart';
import '../tournament/tournament_detail_screen.dart';

/// 初回登録後（オンボーディング説明の最後）に表示する「仲間を見つけよう」画面。
///
/// - 招待コードの入れ忘れ・追加引き換えの救済（何度でも引き換え可能）
/// - 同じ都道府県のおすすめユーザーをその場でフォロー
/// - ID・ニックネーム検索（既存の FollowSearchScreen を再利用）
///
/// すべてスキップ可能。マイページの「招待コードを入力」からも同じ引き換えができる。
class FindFriendsScreen extends StatefulWidget {
  const FindFriendsScreen({super.key});

  @override
  State<FindFriendsScreen> createState() => _FindFriendsScreenState();
}

class _FindFriendsScreenState extends State<FindFriendsScreen> {
  final _codeController = TextEditingController();
  User? get _currentUser => FirebaseAuth.instance.currentUser;

  bool _redeeming = false;
  bool _loadingRecommend = true;
  List<Map<String, dynamic>> _recommended = [];
  String _myPrefecture = '';
  final Set<String> _togglingIds = {};

  @override
  void initState() {
    super.initState();
    final uid = _currentUser?.uid ?? '';
    if (uid.isNotEmpty) {
      FollowService.instance.startListening(uid);
    }
    _loadRecommendations();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _finish() {
    // AuthGate を残すため popUntil（オンボーディングと同じ理由）
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // ── おすすめユーザー（同じ都道府県） ──
  Future<void> _loadRecommendations() async {
    final uid = _currentUser?.uid ?? '';
    if (uid.isEmpty) {
      if (mounted) setState(() => _loadingRecommend = false);
      return;
    }
    try {
      final myDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final rawArea = myDoc.data()?['area'];
      // area は文字列（都道府県名）が基本。旧データはマップ {prefecture, city} の場合あり
      final pref = rawArea is String
          ? rawArea
          : (rawArea is Map ? (rawArea['prefecture'] ?? '').toString() : '');
      _myPrefecture = pref;

      if (pref.isEmpty) {
        if (mounted) setState(() => _loadingRecommend = false);
        return;
      }

      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('area', isEqualTo: pref)
          .limit(30)
          .get();

      final results = <Map<String, dynamic>>[];
      for (final doc in snap.docs) {
        if (doc.id == uid) continue;
        final data = doc.data();
        if (data['isOfficial'] == true) continue;
        if (FollowService.instance.isFollowing(doc.id)) continue;
        results.add({
          'uid': doc.id,
          'nickname': (data['nickname'] ?? '名前なし').toString(),
          'avatarUrl': (data['avatarUrl'] ?? '').toString(),
          'experience': (data['experience'] ?? '').toString(),
        });
        if (results.length >= 15) break;
      }
      if (mounted) {
        setState(() {
          _recommended = results;
          _loadingRecommend = false;
        });
      }
    } catch (e) {
      debugPrint('おすすめユーザー取得失敗: $e');
      if (mounted) setState(() => _loadingRecommend = false);
    }
  }

  // ── 招待コード引き換え ──
  Future<void> _redeemCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty || _redeeming) return;
    setState(() => _redeeming = true);
    try {
      final result = await InviteService.redeemInvite(code);
      if (!mounted) return;
      _codeController.clear();

      final referrerName = (result['referrerName'] ?? '') as String? ?? '';
      final teamName = (result['teamName'] ?? '') as String? ?? '';
      final tournamentId = (result['tournamentId'] ?? '') as String? ?? '';
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
      if (messages.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${messages.join(' / ')}！'), backgroundColor: AppTheme.success),
        );
      }

      // 大会招待なら大会詳細へ（この画面は閉じてホームの上に積む）
      if (tournamentId.isNotEmpty) {
        final doc = await FirebaseFirestore.instance.collection('tournaments').doc(tournamentId).get();
        if (doc.exists && mounted) {
          final data = doc.data()!;
          data['id'] = doc.id;
          _finish();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            navigatorKey.currentState?.push(
              MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournament: data)),
            );
          });
          return;
        }
      }

      // フォロー状態が変わったのでおすすめを更新
      _loadRecommendations();
    } catch (e) {
      debugPrint('招待コードの引き換えに失敗: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('招待コードが無効か、期限切れの可能性があります'), backgroundColor: AppTheme.warning),
        );
      }
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  // ── フォロー切替（FollowSearchScreen と同じ流儀） ──
  Future<void> _toggleFollow(String targetUid, String targetName) async {
    if (_currentUser == null || _togglingIds.contains(targetUid)) return;
    final myUid = _currentUser!.uid;
    final wasFollowing = FollowService.instance.isFollowing(targetUid);
    setState(() => _togglingIds.add(targetUid));
    try {
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
        myNickname: myNickname,
      );
      if (!wasFollowing) {
        NotificationService.sendFollowNotification(
          targetUserId: targetUid,
          senderId: myUid,
          senderName: myNickname,
          senderAvatar: myAvatarUrl,
        );
      }
    } catch (e) {
      debugPrint('フォロー切替エラー: $e');
    } finally {
      if (mounted) setState(() => _togglingIds.remove(targetUid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // ヘッダー（スキップ）
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text('あとで', style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('仲間を見つけよう',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                    const SizedBox(height: 8),
                    const Text(
                      '友達をフォローすると、大会のエントリーや\nタイムラインがもっと楽しくなります。',
                      style: TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.6),
                    ),
                    const SizedBox(height: 24),

                    // ── 招待コード ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(children: [
                            Icon(Icons.confirmation_number_outlined, size: 18, color: AppTheme.primaryColor),
                            SizedBox(width: 6),
                            Text('招待コードを持っていますか？',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                          ]),
                          const SizedBox(height: 6),
                          const Text(
                            '友達・チーム・大会の招待コードをここで引き換えられます（複数OK・あとからマイページでも入力できます）',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
                          ),
                          const SizedBox(height: 12),
                          Row(children: [
                            Expanded(
                              child: TextField(
                                controller: _codeController,
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
                              onPressed: _redeeming ? null : _redeemCode,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryColor,
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
                    const SizedBox(height: 24),

                    // ── おすすめユーザー ──
                    Text(
                      _myPrefecture.isNotEmpty ? '$_myPrefectureのプレイヤー' : 'おすすめのプレイヤー',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                    ),
                    const SizedBox(height: 12),
                    if (_loadingRecommend)
                      const Center(
                          child: Padding(
                              padding: EdgeInsets.all(24),
                              child: CircularProgressIndicator(color: AppTheme.primaryColor)))
                    else if (_recommended.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                            color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                        child: const Text('近くのプレイヤーが見つかりませんでした。\n下の検索から友達を探せます。',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.6)),
                      )
                    else
                      AnimatedBuilder(
                        animation: FollowService.instance,
                        builder: (context, _) => Column(
                          children: _recommended.map((u) {
                            final uid = u['uid'] as String;
                            final nickname = u['nickname'] as String;
                            final avatar = u['avatarUrl'] as String;
                            final experience = u['experience'] as String;
                            final isFollowing = FollowService.instance.isFollowing(uid);
                            final toggling = _togglingIds.contains(uid);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.backgroundColor,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(children: [
                                avatar.isNotEmpty
                                    ? CircleAvatar(radius: 20, backgroundImage: NetworkImage(avatar))
                                    : CircleAvatar(
                                        radius: 20,
                                        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                                        child: Text(nickname.isNotEmpty ? nickname[0] : '?',
                                            style: const TextStyle(
                                                color: AppTheme.primaryColor, fontWeight: FontWeight.bold))),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(nickname,
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                          overflow: TextOverflow.ellipsis),
                                      if (experience.isNotEmpty)
                                        Text(experience,
                                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 96,
                                  child: isFollowing
                                      ? OutlinedButton(
                                          onPressed: toggling ? null : () => _toggleFollow(uid, nickname),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: AppTheme.textSecondary,
                                            side: BorderSide(color: Colors.grey[300]!),
                                            minimumSize: const Size(0, 34),
                                            padding: EdgeInsets.zero,
                                            shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(17)),
                                          ),
                                          child: const Text('フォロー中', style: TextStyle(fontSize: 12)),
                                        )
                                      : ElevatedButton(
                                          onPressed: toggling ? null : () => _toggleFollow(uid, nickname),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: AppTheme.primaryColor,
                                            foregroundColor: Colors.white,
                                            minimumSize: const Size(0, 34),
                                            padding: EdgeInsets.zero,
                                            elevation: 0,
                                            shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(17)),
                                          ),
                                          child: const Text('フォロー',
                                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                        ),
                                ),
                              ]),
                            );
                          }).toList(),
                        ),
                      ),
                    const SizedBox(height: 8),

                    // ── ID・ニックネーム検索 ──
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const FollowSearchScreen()));
                        },
                        icon: const Icon(Icons.search, size: 20),
                        label: const Text('IDやニックネームで友達を探す',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryColor,
                          side: const BorderSide(color: AppTheme.primaryColor),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            // ── はじめるボタン ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _finish,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Sofvo をはじめる',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
