import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import '../../config/app_theme.dart';
import '../../utils/tournament_status.dart';
import '../../utils/official_permissions.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'score_input_screen.dart';
import 'team_match_results_screen.dart';
import 'post_event_action_screen.dart';
import 'checkin_screen.dart';
import 'tournament_checkin_scan_screen.dart';
import 'tournament_finance_screen.dart';
import 'tournament_rules_screen.dart';
import 'venue_search_screen.dart';
import '../../services/csv_download.dart';
import '../../services/follow_service.dart';
import '../../services/result_share_service.dart';
import '../../services/match_generator.dart';
import '../../widgets/official_badge.dart';
import '../../widgets/certified_badge.dart';
import '../../widgets/invite_share_sheet.dart';
import '../../widgets/follower_member_picker.dart';
import '../profile/user_profile_screen.dart';
import 'tournament_summary_download_screen.dart';
import '../chat/chat_screen.dart';
import '../../services/notification_service.dart';
import '../../services/point_service.dart';

class TournamentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> tournament;
  final bool autoCheckIn;
  final String? initialTab; // 'overview', 'matches', 'standings', 'teams', 'board', 'photo'
  const TournamentDetailScreen({super.key, required this.tournament, this.autoCheckIn = false, this.initialTab});
  @override
  State<TournamentDetailScreen> createState() => _TournamentDetailScreenState();
}

class _TournamentDetailScreenState extends State<TournamentDetailScreen>
    with SingleTickerProviderStateMixin {
  // 承認待ちエントリー招待を「開いた（既読）」記録の二重送信防止
  final Set<String> _markedSeenDraftIds = {};

  void _markEntryDraftSeenIfNeeded(String draftId) {
    if (_markedSeenDraftIds.contains(draftId)) return;
    _markedSeenDraftIds.add(draftId);
    FirebaseFunctions.instance.httpsCallable('markEntryDraftSeen').call({
      'tournamentId': _tournamentId,
      'draftId': draftId,
    }).catchError((_) {});
  }

  void _syncFollowingFromService() {
    if (_viewerIsOfficial != true) return;
    if (!mounted) return;
    final v = _computeIsFollowingOrganizer();
    if (v != _isFollowing) setState(() => _isFollowing = v);
  }

  bool _computeIsFollowingOrganizer() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final oid = widget.tournament['organizerId'] as String? ?? '';
    if (uid.isEmpty || oid.isEmpty) return true;
    if (oid == uid) return true;
    return FollowService.instance.isFollowing(oid);
  }

  /// エントリーに必要なときだけ主催者をフォローする（閲覧だけなら不要）
  Future<bool> _ensureFollowingForEntry() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final oid = widget.tournament['organizerId'] as String? ?? '';
    if (uid.isEmpty) return false;
    if (oid.isEmpty || oid == uid) return true;
    if (FollowService.instance.isFollowing(oid)) {
      if (!_isFollowing) setState(() => _isFollowing = true);
      return true;
    }
    await _followOrganizer();
    if (!mounted) return false;
    final ok = FollowService.instance.isFollowing(oid);
    if (ok) setState(() => _isFollowing = true);
    return ok;
  }

  late TabController _tabController;
  late bool _isEntryDeadlinePassed;
  late bool _isFollowing;
  /// null: 未読込。公式（閲覧用拡張）のみ true のとき FollowService 連動・下部ボタン拡張を有効にする。
  bool? _viewerIsOfficial;
  bool _officialFollowListenerRegistered = false;
  final _firestore = FirebaseFirestore.instance;
  List<String> _myTeamIds = [];
  final _postController = TextEditingController();
  bool _isBoardTeam = false; // false=大会掲示板, true=チーム掲示板
  XFile? _selectedBoardImage;
  String _myEntryTeamId = "";
  bool _isAdmin = false;

  bool _canManageTournament(Map<String, dynamic> t) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return canManageTournament(
      uid: uid,
      tournament: t,
      isAdmin: _isAdmin,
      viewerIsOfficial: _viewerIsOfficial == true,
    );
  }
  bool _showOnlyMyCourts = true;
  Set<String> _myCourtIds = {};
  final Map<int, String?> _selectedCourtFilter = {}; // roundNum -> (null=全て, 'MY'=自分のコート, courtId=特定コート) default: MY
  final Map<int, bool> _collapsedRounds = {}; // roundNum -> 折りたたみ状態
  final Map<String, bool> _collapsedBrackets = {}; // bracketId -> 折りたたみ状態
  final Map<String, String?> _selectedBracketCourtFilter = {}; // bracketId -> courtFilter (null=全て, 'MY'=自分のコート, courtId=特定コート)
  Map<String, String> _entryNameCache = {}; // teamId -> teamName

  String get _tournamentId => widget.tournament['id'] as String? ?? '';

  int _resolveInitialTab() {
    final tab = widget.initialTab;
    // 6タブ: 概要(0), 対戦表(1), 順位表(2), チーム(3), 掲示板(4), フォト(5)
    // 4タブ: 概要(0), チーム(1), 掲示板(2), フォト(3)
    if (tab != null) {
      if (_isEntryDeadlinePassed) {
        switch (tab) {
          case 'matches': return 1;
          case 'standings': return 2;
          case 'teams': return 3;
          case 'board': return 4;
          case 'photo': return 5;
          default: return 0;
        }
      } else {
        switch (tab) {
          case 'teams': return 1;
          case 'board': return 2;
          case 'photo': return 3;
          default: return 0;
        }
      }
    }
    // 大会当日は対戦表タブを初期表示
    if (_isEntryDeadlinePassed && _isTournamentToday()) return 1;
    return 0;
  }

  @override
  void initState() {
    super.initState();
    final status = normalizeTournamentStatus(
      widget.tournament['status'],
      emptyAsPreparing: false,
    );
    _isEntryDeadlinePassed = status == 'エントリー締切' || status == '大会準備中' || status == '満員' || status == '開催済み' || status == '開催中' || status == '決勝中' || status == '順位決定中' || status == '終了' || status.contains('完了') || widget.tournament['organizerId'] == FirebaseAuth.instance.currentUser?.uid || _isAdmin;
    _isFollowing = widget.tournament['isFollowing'] as bool? ?? true;
    _tabController = TabController(
      length: _isEntryDeadlinePassed ? 6 : 4,
      vsync: this,
      initialIndex: _resolveInitialTab(),
    );
    _loadUserFlags();
    _loadMyTeams().then((_) {
      if (mounted && widget.autoCheckIn) _performSelfCheckIn();
    }).catchError((_) {});
    _recordView();
  }

  /// 大会詳細の閲覧を記録する（主催者向けの閲覧数表示用）。
  /// stats/summary に延べアクセス数(viewCount)とユニーク閲覧者数(uniqueViewCount)を、
  /// views/{uid} に各ユーザーの初回・最終閲覧時刻と回数を保存する。
  /// 主催者自身のアクセスはカウントしない。
  Future<void> _recordView() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _tournamentId.isEmpty) return;
    final organizerId = widget.tournament['organizerId'] as String?;
    if (organizerId != null && organizerId == uid) return; // 主催者自身は除外
    final tRef = _firestore.collection('tournaments').doc(_tournamentId);
    final viewRef = tRef.collection('views').doc(uid);
    final statRef = tRef.collection('stats').doc('summary');
    try {
      final viewDoc = await viewRef.get();
      final isNew = !viewDoc.exists;
      await statRef.set({
        'viewCount': FieldValue.increment(1),
        if (isNew) 'uniqueViewCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await viewRef.set({
        'lastViewedAt': FieldValue.serverTimestamp(),
        'count': FieldValue.increment(1),
        if (isNew) 'firstViewedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // 閲覧記録の失敗は無視（閲覧体験を妨げない）
    }
  }

  @override
  void dispose() {
    if (_officialFollowListenerRegistered) {
      FollowService.instance.removeListener(_syncFollowingFromService);
    }
    _tabController.dispose();
    _postController.dispose();
    super.dispose();
  }

  Future<void> _loadUserFlags() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      if (mounted) setState(() => _viewerIsOfficial = false);
      return;
    }
    final userDoc = await _firestore.collection('users').doc(uid).get();
    if (!mounted) return;
    final data = userDoc.data();
    final isAdmin = data?['isAdmin'] == true;
    final isOfficial = data?['isOfficial'] == true;
    setState(() {
      _isAdmin = isAdmin;
      _viewerIsOfficial = isOfficial;
      if (isOfficial) {
        _isFollowing = _computeIsFollowingOrganizer();
        if (!_officialFollowListenerRegistered) {
          FollowService.instance.addListener(_syncFollowingFromService);
          _officialFollowListenerRegistered = true;
        }
      }
    });
  }

  Future<void> _loadMyTeams() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty || _tournamentId.isEmpty) return;
    final allEntries = await _firestore.collection('tournaments').doc(_tournamentId)
        .collection('entries').get();
    // enteredBy / leaderUid / memberUids のいずれかに自分のUIDが含まれるエントリーを検索
    final myDocs = allEntries.docs.where((d) {
      final data = d.data();
      if (data['enteredBy'] == uid) return true;
      if (data['leaderUid'] == uid) return true;
      final memberUids = data['memberUids'];
      if (memberUids is List && memberUids.contains(uid)) return true;
      return false;
    });
    // teamId フィールドが無い古いエントリーは doc.id を teamId として扱う（取りこぼし防止）
    final teamIds = myDocs.map((d) {
      final tid = (d.data()['teamId'] as String?) ?? '';
      return tid.isNotEmpty ? tid : d.id;
    }).where((id) => id.isNotEmpty).toList();
    // エントリー名キャッシュを構築（チームID→チーム名）
    final nameCache = <String, String>{};
    for (final d in allEntries.docs) {
      final data = d.data();
      final teamId = data['teamId'] as String? ?? d.id;
      final teamName = data['teamName'] as String? ?? '';
      if (teamId.isNotEmpty && teamName.isNotEmpty) {
        nameCache[teamId] = teamName;
        if (d.id != teamId) nameCache[d.id] = teamName;
      }
    }
    if (mounted) setState(() {
      _myTeamIds = teamIds;
      _myEntryTeamId = teamIds.isNotEmpty ? teamIds.first : "";
      _entryNameCache = nameCache;
    });
  }
  /// セルフチェックイン（参加者が会場の大会QRをスキャン、または主催者が手動登録したあとに記録）
  Future<void> _performSelfCheckIn() async {
    // 自分のエントリーを自動検出できないケース（主催者がCSV/手動でチームを登録した・
    // 古いデータでアカウントとエントリーが紐づいていない 等）でも行き止まりにせず、
    // エントリー一覧から自分のチームを選んでチェックインできるようにする。
    if (_myEntryTeamId.isEmpty) {
      await _promptSelectTeamForCheckIn();
      return;
    }
    await _checkInTeam(_myEntryTeamId, teamNameHint: _entryNameCache[_myEntryTeamId]);
  }

  /// 指定したチームをチェックイン登録する（重複チェック・チーム名解決つき）
  Future<void> _checkInTeam(String teamId, {String? teamNameHint}) async {
    if (teamId.isEmpty) return;
    // 重複チェック
    final existing = await _firestore.collection('tournaments').doc(_tournamentId)
        .collection('checkIns').where('teamId', isEqualTo: teamId).limit(1).get();
    if (existing.docs.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('すでにチェックイン済みです'), backgroundColor: AppTheme.warning),
        );
      }
      return;
    }
    // チーム名取得（ヒントが無ければエントリーから解決）
    var teamName = teamNameHint ?? '';
    if (teamName.isEmpty) {
      final entrySnap = await _firestore.collection('tournaments').doc(_tournamentId)
          .collection('entries').where('teamId', isEqualTo: teamId).limit(1).get();
      teamName = entrySnap.docs.isNotEmpty
          ? (entrySnap.docs.first.data()['teamName'] ?? '')
          : (_entryNameCache[teamId] ?? '');
    }
    // チェックイン登録
    await _firestore.collection('tournaments').doc(_tournamentId).collection('checkIns').add({
      'teamId': teamId,
      'teamName': teamName,
      'checkedInAt': FieldValue.serverTimestamp(),
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text('$teamName チェックイン完了！')),
          ]),
          backgroundColor: AppTheme.success,
        ),
      );
    }
  }

  /// 自分のエントリーが自動検出できないとき、エントリー一覧から自分のチームを選ばせる
  Future<void> _promptSelectTeamForCheckIn() async {
    final entriesSnap = await _firestore.collection('tournaments').doc(_tournamentId)
        .collection('entries').get();
    if (!mounted) return;
    if (entriesSnap.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この大会にはまだエントリーがありません'), backgroundColor: AppTheme.warning),
      );
      return;
    }
    // checkIns 済みの teamId を取得（重複表示を抑止するため）
    final checkInSnap = await _firestore.collection('tournaments').doc(_tournamentId)
        .collection('checkIns').get();
    if (!mounted) return;
    final checkedIds = checkInSnap.docs
        .map((d) => (d.data()['teamId'] as String?) ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final teams = entriesSnap.docs.map((d) {
      final data = d.data();
      final tid = (data['teamId'] as String?)?.isNotEmpty == true ? data['teamId'] as String : d.id;
      final name = (data['teamName'] as String?) ?? '名称未設定';
      return MapEntry(tid, name);
    }).toList();

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              const Text('チェックインするチームを選択', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'あなたのアカウントがエントリーに紐づいていないため、自分のチームを選んでください。',
                style: TextStyle(fontSize: 13, height: 1.45, color: AppTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: teams.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final entry = teams[i];
                    final isChecked = checkedIds.contains(entry.key);
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isChecked ? AppTheme.success.withValues(alpha: 0.4) : Colors.grey[200]!),
                      ),
                      child: ListTile(
                        title: Text(entry.value, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: isChecked ? const Text('チェックイン済み', style: TextStyle(fontSize: 12, color: AppTheme.success)) : null,
                        trailing: Icon(isChecked ? Icons.check_circle : Icons.chevron_right,
                            color: isChecked ? AppTheme.success : AppTheme.textHint),
                        onTap: isChecked ? null : () {
                          Navigator.pop(ctx);
                          _checkInTeam(entry.key, teamNameHint: entry.value);
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 大会チャットを開く or 作成 ──
  Future<void> _openOrCreateTournamentChat() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty || _tournamentId.isEmpty) return;

    // linkedId で大会に紐づくチャットを検索
    final existing = await _firestore
        .collection('chats')
        .where('type', isEqualTo: 'tournament')
        .where('linkedId', isEqualTo: _tournamentId)
        .get();

    String chatId;
    if (existing.docs.isNotEmpty) {
      chatId = existing.docs.first.id;
      // 自分がmembersに入っていなければ追加
      final members = List<String>.from(existing.docs.first['members'] ?? []);
      if (!members.contains(uid)) {
        final userDoc = await _firestore.collection('users').doc(uid).get();
        final myName = (userDoc.data()?['nickname'] as String?) ?? 'ユーザー';
        await _firestore.collection('chats').doc(chatId).update({
          'members': FieldValue.arrayUnion([uid]),
          'memberNames.$uid': myName,
        });
      }
    } else {
      // 新規作成：自分だけで作成（他の参加者はチャットを開いた時に追加される）
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final myName = (userDoc.data()?['nickname'] as String?) ?? 'ユーザー';
      final tournamentName = widget.tournament['name'] as String? ?? '大会チャット';

      final ref = await _firestore.collection('chats').add({
        'type': 'tournament',
        'name': tournamentName,
        'linkedId': _tournamentId,
        'members': [uid],
        'memberNames': {uid: myName},
        'lastMessage': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      chatId = ref.id;
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatTitle: widget.tournament['name'] as String? ?? '大会チャット',
            chatType: 'tournament',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tournament;

    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId).snapshots(),
      builder: (_, statusSnap) {
        final liveData = (statusSnap.hasData && statusSnap.data!.exists)
            ? statusSnap.data!.data() as Map<String, dynamic>? ?? {}
            : <String, dynamic>{};
        final status = normalizeTournamentStatus(liveData['status'] ?? t['status'] ?? '準備中');
        Color statusColor;
        switch (status) {
          case '募集中': statusColor = AppTheme.success; break;
          case 'エントリー締切': statusColor = AppTheme.accentColor; break;
          case '大会準備中':
            statusColor = AppTheme.primaryLight;
            break;
          case '準備中': statusColor = AppTheme.warning; break;
          case '開催中': statusColor = AppTheme.primaryColor; break;
          case '予選1完了': statusColor = AppTheme.info; break;
          case '予選2完了': statusColor = AppTheme.info; break;
          case '決勝中': statusColor = Colors.amber; break;
          case '順位決定中': statusColor = Colors.amber; break;
          default: statusColor = AppTheme.textSecondary;
        }

        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: statusColor == AppTheme.primaryColor
                ? Colors.white.withValues(alpha: 0.15)
                : statusColor.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: statusColor == AppTheme.primaryColor
                  ? Colors.white.withValues(alpha: 0.5)
                  : statusColor.withValues(alpha: 0.5),
            ),
          ),
          child: Text(status, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
        ),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.share), onPressed: () => _showShareOptions(context)),
          IconButton(icon: const Icon(Icons.picture_as_pdf), onPressed: _openSummaryDownload),
        ],
      ),
      body: Column(
        children: [
          _buildHeader(t, status, statusColor),
          _buildEntryDraftBanner(),
          if (!_isFollowing) _buildFollowBanner(),
          _buildTabBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _KeepAlivePage(child: _buildOverviewTab()),
                if (_isEntryDeadlinePassed) _KeepAlivePage(child: _buildMatchTableTab()),
                if (_isEntryDeadlinePassed) _KeepAlivePage(child: _buildStandingsTab()),
                _KeepAlivePage(child: _buildTeamsTab()),
                _KeepAlivePage(child: _buildTimelineTab()),
                _KeepAlivePage(child: _buildPhotoGalleryTab()),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomButtons(),
    );
      },
    );
  }

  Widget _buildHeader(Map<String, dynamic> t, String status, Color statusColor) {
    final currentTeams = t['currentTeams'] is int ? t['currentTeams'] as int : 0;
    final maxTeams = t['maxTeams'] is int ? t['maxTeams'] as int : 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [AppTheme.primaryDark, AppTheme.primaryColor, AppTheme.primaryLight],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 大会名 + カテゴリ
          Row(
            children: [
              Expanded(
                child: Row(children: [
                  Flexible(child: Text((t['name'] ?? t['title'] ?? '') as String,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (t['isCertified'] == true) const CertifiedBadge(size: 16),
                ]),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: AppTheme.accentColor.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(10)),
                child: Text((t['type'] ?? '') as String, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 日付・場所
          Row(children: [
            const Icon(Icons.calendar_today, size: 13, color: Colors.white70),
            const SizedBox(width: 4),
            Text((t['date'] ?? '') as String, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(width: 12),
            const Icon(Icons.location_on, size: 13, color: Colors.white70),
            const SizedBox(width: 3),
            Expanded(
              child: Text(t['location'] as String? ?? t['venue'] as String? ?? '',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        ],
      ),
    );
  }

  Future<void> _followOrganizer() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final organizerId = widget.tournament['organizerId'] as String? ?? '';
    if (organizerId.isEmpty || organizerId == uid) return;

    if (FollowService.instance.isFollowing(organizerId)) {
      setState(() => _isFollowing = true);
      return;
    }

    setState(() => _isFollowing = true);

    try {
      final targetDoc = await _firestore.collection('users').doc(organizerId).get();
      final targetNickname = (targetDoc.data()?['nickname'] as String?) ?? '主催者';
      await FollowService.instance.toggleFollow(
        targetUid: organizerId,
        targetNickname: targetNickname,
      );
    } catch (e) {
      if (mounted) setState(() => _isFollowing = false);
    }
  }

  Widget _buildFollowBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.warning.withValues(alpha:0.1),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: AppTheme.warning),
          const SizedBox(width: 10),
          Expanded(
              child: Text(
                  _viewerIsOfficial == true
                      ? '大会情報の閲覧はこのままでも可能です。エントリーやメンバー募集には主催者のフォローが必要です。'
                      : '大会主催者をフォローするとエントリーできます',
                  style: TextStyle(fontSize: 13, color: AppTheme.warning))),
          TextButton(
            onPressed: () async {
              await _followOrganizer();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('大会主催者をフォローしました！'), backgroundColor: AppTheme.success),
                );
              }
            },
            child: const Text('フォローする', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: Colors.white,
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelColor: AppTheme.primaryColor,
        unselectedLabelColor: AppTheme.textSecondary,
        indicatorColor: AppTheme.primaryColor,
        indicatorWeight: 3,
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 14),
        tabs: [
          const Tab(text: '概要'),
          if (_isEntryDeadlinePassed) const Tab(text: '対戦表'),
          if (_isEntryDeadlinePassed) const Tab(text: '順位表'),
          const Tab(text: 'チーム'),
          const Tab(text: '掲示板'),
          const Tab(text: 'フォト'),
        ],
      ),
    );
  }

  // ━━━ 概要タブ ━━━
  Widget _buildOverviewTab() {
    final t = widget.tournament;
    final currentTeams = t['currentTeams'] is int ? t['currentTeams'] as int : 0;
    final maxTeams = t['maxTeams'] is int ? t['maxTeams'] as int : 1;
    final progress = maxTeams > 0 ? currentTeams / maxTeams : 0.0;
    final rules = t['rules'] as Map<String, dynamic>? ?? {};
    final preliminary = rules['preliminary'] as Map<String, dynamic>? ?? {};
    final finalRules = rules['final'] as Map<String, dynamic>? ?? {};
    final scoring = rules['scoring'] as Map<String, dynamic>? ?? {};
    final management = rules['management'] as Map<String, dynamic>? ?? {};
    final other = rules['other'] as Map<String, dynamic>? ?? {};
    final courts = t['courts'] ?? 0;

    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId).snapshots(),
      builder: (context, snap) {
        // Use live data if available
        Map<String, dynamic> live = {};
        if (snap.hasData && snap.data!.exists) {
          live = snap.data!.data() as Map<String, dynamic>? ?? {};
        }
        final liveCurrentTeams = (live['currentTeams'] as num?)?.toInt() ?? currentTeams;
        final liveMaxTeams = (live['maxTeams'] as num?)?.toInt() ?? maxTeams;
        final liveProgress = liveMaxTeams > 0 ? liveCurrentTeams / liveMaxTeams : 0.0;
        final liveStatusRaw = live['status'] ?? t['status'];
        final liveStatus = normalizeTournamentStatus(liveStatusRaw, emptyAsPreparing: false);
        final liveRules = live['rules'] as Map<String, dynamic>? ?? rules;
        final livePrelim = liveRules['preliminary'] as Map<String, dynamic>? ?? preliminary;
        final liveFinal = liveRules['final'] as Map<String, dynamic>? ?? finalRules;
        final liveScoring = liveRules['scoring'] as Map<String, dynamic>? ?? scoring;
        final liveManagement = liveRules['management'] as Map<String, dynamic>? ?? management;
        final liveOther = liveRules['other'] as Map<String, dynamic>? ?? other;
        final liveCourts = live['courts'] ?? courts;
        final liveDate = live['date'] as String? ?? t['date'] as String? ?? '';
        final liveLocation = live['location'] as String? ?? t['location'] as String? ?? t['venue'] as String? ?? '';
        final liveAddress = (live['venueAddress'] ?? t['venueAddress'] ?? '').toString();
        final liveType = live['type'] ?? t['type'] ?? '混合';
        final liveEntryFee = () { final f = live['entryFee'] ?? t['entryFee'] ?? t['fee']; return f is int ? '¥$f' : (f ?? '').toString(); }();
        final liveDeadline = (live['deadline'] ?? t['deadline'] ?? '').toString();
        final liveDescription = (live['description'] ?? t['description'] ?? '').toString();

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ━━━ 大会情報カード ━━━
            _buildCard(
              title: '大会情報',
              titleIcon: Icons.info_outline,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // 日時
                _buildDetailInfoRow(Icons.calendar_today, '日時', liveDate),
                const Divider(height: 1),
                // 会場
                _buildDetailInfoRow(Icons.location_on, '会場', liveLocation, subtitle: liveAddress.isNotEmpty ? liveAddress : null, onSubtitleTap: liveAddress.isNotEmpty ? () {
                  final encoded = Uri.encodeComponent(liveAddress);
                  launchUrl(Uri.parse('https://www.google.com/maps/search/$encoded'), mode: LaunchMode.externalApplication);
                } : null),
                const Divider(height: 1),
                // 種別
                _buildDetailInfoRow(Icons.category, '種別', liveType),
                const Divider(height: 1),
                // 参加費
                _buildDetailInfoRow(Icons.payments, '参加費', liveEntryFee),
                const Divider(height: 1),
                // 募集チーム数
                _buildDetailInfoRow(Icons.groups, '募集チーム数', '$liveMaxTeams チーム'),
                const Divider(height: 1),
                // コート数
                _buildDetailInfoRow(Icons.grid_view, 'コート数', '${liveCourts}コート'),
                // 締切
                if (liveDeadline.isNotEmpty) ...[
                  const Divider(height: 1),
                  _buildDetailInfoRow(Icons.event_busy, 'エントリー締切', liveDeadline, valueColor: AppTheme.warning),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _openSummaryDownload(),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('大会要項をダウンロード', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryColor,
                      side: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),

            // ━━━ 募集状況 ━━━
            StreamBuilder<QuerySnapshot>(
              stream: _firestore.collection('tournaments').doc(_tournamentId).collection('entries').snapshots(),
              builder: (context, entriesSnap) {
                final entryCount = entriesSnap.data?.docs.length ?? 0;
                final entryProgress = liveMaxTeams > 0 ? entryCount / liveMaxTeams : 0.0;
                return _buildCard(
                  title: '募集状況',
                  titleIcon: Icons.groups,
                  child: Column(children: [
                    Row(children: [
                      Text('$entryCount', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                      Text(' / $liveMaxTeams チーム', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: entryProgress >= 1.0 ? AppTheme.error.withValues(alpha: 0.1) : AppTheme.success.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(entryProgress >= 1.0 ? '満員' : '残り${liveMaxTeams - entryCount}枠',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                                color: entryProgress >= 1.0 ? AppTheme.error : AppTheme.success)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: entryProgress.clamp(0.0, 1.0),
                        backgroundColor: Colors.grey[200],
                        valueColor: AlwaysStoppedAnimation<Color>(
                          entryProgress >= 1.0 ? AppTheme.error : entryProgress >= 0.8 ? AppTheme.warning : AppTheme.success),
                        minHeight: 10,
                      ),
                    ),
                  ]),
                );
              },
            ),
            const SizedBox(height: 16),

            // ━━━ 閲覧数（主催者のみ） ━━━
            if (_canManageTournament(live.isNotEmpty ? live : t)) ...[
              _buildViewStatsCard(),
              const SizedBox(height: 16),
            ],

            // ━━━ 獲得ポイント ━━━
            _buildCard(
              title: '獲得ポイント',
              titleIcon: Icons.star_rounded,
              child: Builder(builder: (context) {
                // 実参加チーム数（currentTeams）基準。未エントリー時は募集枠で仮表示
                final pointTable = PointService.getPointTable(
                    PointService.effectiveTeamCount(
                        currentTeams: liveCurrentTeams, maxTeams: liveMaxTeams));
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('この大会で獲得できるポイント（参加チーム数に応じて変動）',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    const SizedBox(height: 10),
                    _buildPointTableRow(Icons.military_tech, '優勝', '${pointTable['優勝']}pt', Colors.amber),
                    _buildPointTableRow(Icons.star, '準優勝', '${pointTable['準優勝']}pt', AppTheme.primaryColor),
                    _buildPointTableRow(Icons.emoji_events_outlined, '3位', '${pointTable['3位']}pt', const Color(0xFFCD7F32)),
                    _buildPointTableRow(Icons.looks_4_outlined, '4位', '${pointTable['4位']}pt', AppTheme.textSecondary),
                    _buildPointTableRow(Icons.sports_volleyball, '参加', '${pointTable['参加']}pt', AppTheme.textSecondary),
                  ],
                );
              }),
            ),
            const SizedBox(height: 16),

            // ━━━ 当日スケジュール（タイムライン形式） ━━━
            Builder(builder: (_) {
              bool _hasTime(String? v) => v != null && v.isNotEmpty && v != '--:--';
              final scheduleItems = <Map<String, dynamic>>[
                {'time': live['openTime'] as String? ?? t['openTime'] as String? ?? '', 'label': '開場', 'icon': Icons.location_on},
                {'time': live['receptionTime'] as String? ?? t['receptionTime'] as String? ?? '', 'label': '受付開始', 'icon': Icons.how_to_reg},
                {'time': live['captainMeetingTime'] as String? ?? t['captainMeetingTime'] as String? ?? '', 'label': 'キャプテン会議', 'icon': Icons.groups},
                {'time': live['openingTime'] as String? ?? t['openingTime'] as String? ?? '', 'label': '開会式', 'icon': Icons.campaign},
                {'time': live['matchStartTime'] as String? ?? t['matchStartTime'] as String? ?? '', 'label': '試合開始', 'icon': Icons.sports_volleyball},
                {'time': live['finalTime'] as String? ?? t['finalTime'] as String? ?? '', 'label': '終了', 'icon': Icons.flag},
                {'time': live['closingTime'] as String? ?? t['closingTime'] as String? ?? '', 'label': '完全撤退', 'icon': Icons.exit_to_app},
              ].where((item) => _hasTime(item['time'] as String?)).toList();
              if (scheduleItems.isEmpty) return const SizedBox.shrink();
              return _buildCard(
                title: 'タイムスケジュール',
                titleIcon: Icons.schedule,
                child: Column(children: [
                  for (int i = 0; i < scheduleItems.length; i++)
                    _buildTimelineRow(
                      scheduleItems[i]['time'] as String,
                      scheduleItems[i]['label'] as String,
                      scheduleItems[i]['icon'] as IconData,
                      isLast: i == scheduleItems.length - 1,
                    ),
                ]),
              );
            }),
            const SizedBox(height: 16),

            // ━━━ Organizer ━━━
            GestureDetector(
              onTap: () {
                final organizerId = live['organizerId'] as String? ?? t['organizerId'] as String?;
                if (organizerId != null && organizerId.isNotEmpty) {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => UserProfileScreen(userId: organizerId),
                  ));
                }
              },
              child: FutureBuilder<DocumentSnapshot>(
                future: (() {
                  final orgId = live['organizerId'] as String? ?? t['organizerId'] as String? ?? '';
                  return orgId.isNotEmpty ? _firestore.collection('users').doc(orgId).get() : null;
                })(),
                builder: (context, userSnap) {
                  final userData = userSnap.data?.data() as Map<String, dynamic>? ?? {};
                  final avatarUrl = (userData['avatarUrl'] ?? '') as String;
                  final userNickname = (userData['nickname'] as String?) ?? '';
                  final organizerName = userNickname.isNotEmpty
                      ? userNickname
                      : live['organizerName'] as String? ?? t['organizer'] as String? ?? t['organizerName'] as String? ?? '主催者';
                  final isOrgOfficial = userData['isOfficial'] == true;
                  return _buildCard(
                child: Row(children: [
                  avatarUrl.isNotEmpty
                      ? CircleAvatar(radius: 22, backgroundImage: NetworkImage(avatarUrl))
                      : CircleAvatar(radius: 22, backgroundColor: AppTheme.primaryColor.withValues(alpha:0.12),
                          child: Text(organizerName.isNotEmpty ? organizerName[0] : '主', style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold, fontSize: 16))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(
                        children: [
                          Flexible(child: Text(organizerName,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                              overflow: TextOverflow.ellipsis)),
                          if (isOrgOfficial) const OfficialBadge(size: 15),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(children: [
                        Icon(Icons.star, size: 14, color: AppTheme.accentColor),
                        const SizedBox(width: 4),
                        Text('大会主催者', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      ]),
                    ]),
                  ),
                  Icon(Icons.chevron_right, color: AppTheme.textHint),
                ]),
              );
                },
              ),
            ),
            const SizedBox(height: 16),

            // ━━━ Description ━━━
            if (liveDescription.isNotEmpty) ...[
              _buildCard(
                title: '大会説明・備考',
                titleIcon: Icons.description_outlined,
                child: Text(liveDescription,
                    style: const TextStyle(fontSize: 14, height: 1.6, color: AppTheme.textPrimary)),
              ),
              const SizedBox(height: 16),
            ],

            // ━━━ ルール ━━━
            _buildCard(
              title: 'ルール',
              titleIcon: Icons.gavel,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // 予選
                () {
                  final rounds = livePrelim['rounds'] ?? 1;
                  final hasR2 = rounds == 2;
                  // 2ラウンド形式: round1/round2に分かれている
                  final r1Data = hasR2 ? (livePrelim['round1'] as Map<String, dynamic>? ?? {}) : livePrelim;
                  final r2Data = hasR2 ? (livePrelim['round2'] as Map<String, dynamic>? ?? {}) : <String, dynamic>{};
                  final r1Sets = r1Data['sets'] ?? 2;
                  final r2Sets = r2Data['sets'] ?? r1Sets;
                  final r1Deuce = r1Data['deuce'] ?? false;
                  final r2Deuce = r2Data['deuce'] ?? r1Deuce;
                  final r1DeuceCap = r1Data['deuceCap'] ?? 17;
                  final r2DeuceCap = r2Data['deuceCap'] ?? r1DeuceCap;

                  if (!hasR2) {
                    // 1ラウンドのみ
                    return _buildRuleSectionCard(
                      '予選',
                      Icons.sports_volleyball,
                      AppTheme.primaryColor,
                      [
                        _buildRuleTableRow('セット形式', _setFormatDisplayLabel(r1Sets)),
                        _buildRuleTableRow('デュース', r1Deuce ? 'あり（${r1DeuceCap}点キャップ）' : 'なし'),
                      ],
                    );
                  } else {
                    // 2ラウンド → ルールが同じなら1つにまとめる
                    final sameRules = r1Sets == r2Sets && r1Deuce == r2Deuce && r1DeuceCap == r2DeuceCap;
                    if (sameRules) {
                      return _buildRuleSectionCard(
                        '予選（ラウンド1・2共通）',
                        Icons.sports_volleyball,
                        AppTheme.primaryColor,
                        [
                          _buildRuleTableRow('セット形式', _setFormatDisplayLabel(r1Sets)),
                          _buildRuleTableRow('デュース', r1Deuce ? 'あり（${r1DeuceCap}点キャップ）' : 'なし'),
                        ],
                      );
                    }
                    return Column(children: [
                      _buildRuleSectionCard(
                        '予選 ラウンド1',
                        Icons.sports_volleyball,
                        AppTheme.primaryColor,
                        [
                          _buildRuleTableRow('セット形式', _setFormatDisplayLabel(r1Sets)),
                          _buildRuleTableRow('デュース', r1Deuce ? 'あり（${r1DeuceCap}点キャップ）' : 'なし'),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _buildRuleSectionCard(
                        '予選 ラウンド2',
                        Icons.replay,
                        AppTheme.info,
                        [
                          _buildRuleTableRow('セット形式', _setFormatDisplayLabel(r2Sets)),
                          _buildRuleTableRow('デュース', r2Deuce ? 'あり（${r2DeuceCap}点キャップ）' : 'なし'),
                        ],
                      ),
                    ]);
                  }
                }(),
                // 勝ち点制
                if (liveScoring.isNotEmpty && (liveScoring['enabled'] ?? true)) ...[
                  const SizedBox(height: 10),
                  _buildScoringTable(livePrelim, liveScoring),
                ],
                // 順位決定戦
                if ((liveFinal['enabled'] ?? false) == true) ...[
                  const SizedBox(height: 10),
                  _buildRuleSectionCard(
                    '順位決定戦',
                    Icons.military_tech,
                    Colors.amber[700]!,
                    [
                      _buildRuleTableRow('方式', liveFinal['type'] == 'round_robin' ? '総当たり' : 'トーナメント'),
                      _buildRuleTableRow('セット形式', _setFormatDisplayLabel(liveFinal['sets'] ?? 3)),
                      _buildRuleTableRow('デュース', (liveFinal['deuce'] ?? false) ? 'あり' : 'なし'),
                      if (liveFinal['format'] == '順位別複数') ...[
                        _buildRuleTableRow('区分数', (liveFinal['tierCount'] ?? 3) == 1 ? '区分なし' : '${liveFinal['tierCount'] ?? 3}区分'),
                        if ((liveFinal['tierCount'] ?? 3) != 1)
                          _buildTierInfoRow((liveFinal['tierCount'] as num?)?.toInt() ?? 3, liveMaxTeams),
                      ],
                    ],
                  ),
                ],
                // その他
                if (liveOther.isNotEmpty && (liveOther['uniformNumber'] != null || liveOther['snsVideo'] != null)) ...[
                  const SizedBox(height: 10),
                  _buildRuleSectionCard(
                    'その他',
                    Icons.more_horiz,
                    AppTheme.textSecondary,
                    [
                      if (liveOther['uniformNumber'] != null)
                        _buildRuleTableRow('ゼッケン', liveOther['uniformNumber'] == true ? '必須' : '不要'),
                      if (liveOther['snsVideo'] != null)
                        _buildRuleTableRow('SNS動画投稿', liveOther['snsVideo'] == true ? '許可' : '不可'),
                    ],
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 16),

            // ━━━ ルールPDF ━━━
            if ((live['rulesPdfUrl'] ?? t['rulesPdfUrl']) != null) ...[
              _buildCard(
                title: 'ルールPDF',
                titleIcon: Icons.picture_as_pdf,
                child: GestureDetector(
                  onTap: () {
                    final url = (live['rulesPdfUrl'] ?? t['rulesPdfUrl']) as String;
                    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10)),
                    child: Row(children: [
                      Icon(Icons.picture_as_pdf, color: AppTheme.error, size: 28),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text((live['rulesPdfName'] ?? t['rulesPdfName'] ?? 'ルール.pdf') as String,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text('タップしてPDFを開く', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      ])),
                      Icon(Icons.open_in_new, size: 18, color: AppTheme.primaryColor),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ━━━ 大会の流れ（終了後は非表示）━━━
            if (liveStatus != '終了') _buildCard(
              title: '大会の流れ',
              titleIcon: Icons.timeline,
              child: Builder(builder: (_) {
                final hasTwoRounds = (livePrelim['rounds'] ?? 1) > 1;
                final isMatchPrep = liveStatus == '大会準備中';
                final isRunning = liveStatus == '開催中';
                final isR1Done = liveStatus == '予選1完了';
                final isR2Done = liveStatus == '予選2完了';
                final isFinals = liveStatus == '順位決定中' || liveStatus == '決勝中';
                final isEnded = liveStatus == '終了';
                // 予選以降のステータスか
                final pastEntry = isMatchPrep || isRunning || isR1Done || isR2Done || isFinals || isEnded;
                // 大会準備中を終えたあと（本番の予選〜）
                final pastMatchPrep = isRunning || isR1Done || isR2Done || isFinals || isEnded;
                // 予選1が完了しているか
                final r1Completed = isR1Done || isR2Done || isFinals || isEnded;
                // 予選2が完了しているか
                final r2Completed = isR2Done || isFinals || isEnded;

                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildFlowStep(1, 'エントリー受付', liveStatus == '募集中', liveCurrentTeams > 0),
                  _buildFlowStep(2, 'エントリー締切', liveStatus == 'エントリー締切', pastEntry),
                  _buildFlowStep(3, '大会準備中', isMatchPrep, pastMatchPrep),
                  _buildFlowStep(4, hasTwoRounds ? '予選1' : '予選リーグ', isRunning && !r1Completed, r1Completed),
                  if (hasTwoRounds)
                    _buildFlowStep(5, '予選2', isR1Done || (isRunning && r1Completed && !r2Completed), r2Completed),
                  _buildFlowStep(hasTwoRounds ? 6 : 5, '順位決定戦', isFinals, isEnded),
                  _buildFlowStep(hasTwoRounds ? 7 : 6, '結果発表・表彰', isEnded, false, isLast: true),
                ]);
              }),
            ),

            const SizedBox(height: 100),
          ],
        );
      },
    );
  }

  Widget _buildPointRow(String label, dynamic points) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        const SizedBox(width: 8),
        Container(width: 6, height: 6, decoration: BoxDecoration(color: AppTheme.primaryColor, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Text('${points ?? 0}点', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
      ]),
    );
  }

  static String _setFormatDisplayLabel(int sets) {
    switch (sets) {
      case 1: return '1セットマッチ';
      case 3: return '2セット先取';
      default: return '2セットマッチ';
    }
  }

  List<Widget> _buildScoringRowsForFormat(int sets, Map<String, dynamic> scoring) {
    switch (sets) {
      case 1:
        return [
          _buildPointRow('勝利', scoring['win'] ?? 3),
          _buildPointRow('敗北', scoring['lose'] ?? 0),
        ];
      case 3:
        return [
          _buildPointRow('2-0 勝ち', scoring['win20'] ?? 10),
          _buildPointRow('2-1 勝ち', scoring['win21'] ?? 7),
          _buildPointRow('1-2 負け', scoring['lose12'] ?? 2),
          _buildPointRow('0-2 負け', scoring['lose02'] ?? 0),
        ];
      default:
        return [
          _buildPointRow('2-0 勝ち', scoring['win20'] ?? 10),
          _buildPointRow('1-1 得失差勝ち', scoring['win11'] ?? 7),
          _buildPointRow('1-1 引き分け', scoring['draw'] ?? 4),
          _buildPointRow('1-1 得失差負け', scoring['lose11'] ?? 2),
          _buildPointRow('0-2 負け', scoring['lose02'] ?? 0),
        ];
    }
  }

  Widget _buildFlowStep(int step, String label, bool isCurrent, bool isCompleted, {bool isLast = false}) {
    return IntrinsicHeight(
      child: Row(children: [
        Column(children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
              color: isCompleted ? AppTheme.success : isCurrent ? AppTheme.primaryColor : Colors.grey[200],
              shape: BoxShape.circle,
              boxShadow: isCurrent ? [BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.3), blurRadius: 6)] : [],
            ),
            child: Center(child: isCompleted
                ? const Icon(Icons.check, size: 16, color: Colors.white)
                : Text('$step', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                    color: isCurrent ? Colors.white : AppTheme.textSecondary))),
          ),
          if (!isLast)
            Expanded(child: Container(width: 2, color: isCompleted ? AppTheme.success.withValues(alpha: 0.3) : Colors.grey[200])),
        ]),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(label, style: TextStyle(fontSize: 14,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                color: isCurrent ? AppTheme.primaryColor : isCompleted ? AppTheme.success : AppTheme.textPrimary)),
          ),
        ),
        if (isCurrent)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
            child: const Text('進行中', style: TextStyle(fontSize: 11, color: AppTheme.primaryColor, fontWeight: FontWeight.bold)),
          ),
      ]),
    );
  }

  Widget _buildMatchTableTab() {
    if (_tournamentId.isEmpty) return const Center(child: Text('大会IDが見つかりません'));
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId).snapshots(),
      builder: (context, tournSnap) {
        if (!tournSnap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        final tournData = tournSnap.data!.data() as Map<String, dynamic>? ?? {};
        final tournEditors = List<String>.from(tournData['editors'] ?? []);
        final isOrganizer = _canManageTournament(tournData);
        final status = normalizeTournamentStatus(tournData['status'] ?? '準備中');

        return StreamBuilder<QuerySnapshot>(
          stream: _firestore.collection('tournaments').doc(_tournamentId).collection('rounds').snapshots(),
          builder: (context, roundsSnap) {
            final hasRounds = roundsSnap.hasData && roundsSnap.data!.docs.isNotEmpty;

            if (!hasRounds) {
              return Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.grid_on, size: 64, color: AppTheme.textHint),
                  const SizedBox(height: 16),
                  Text(status == '募集中' || status == '満員' ? '対戦表はエントリー締切後に生成されます' : '対戦表を生成してください',
                      style: const TextStyle(fontSize: 15, color: AppTheme.textSecondary), textAlign: TextAlign.center),
                  if (isOrganizer) ...[
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => _generateMatches(1),
                      icon: const Icon(Icons.auto_fix_high),
                      label: const Text('対戦表を自動生成', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ]),
              ));
            }

            // Show rounds and matches
            final collapseRounds = status == '順位決定中' || status == '決勝中' || status == '終了' || (status.contains('完了'));
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Show each round (collapsed by default when in ranking/finals phase)
                ...roundsSnap.data!.docs.map((roundDoc) {
                  final roundData = roundDoc.data() as Map<String, dynamic>;
                  final roundNum = roundData['roundNumber'] ?? 1;
                  return _buildRoundSection(roundDoc.id, roundNum, isOrganizer, defaultCollapsed: collapseRounds, tournamentStatus: status);
                }),

                // Show brackets if exist (自分のリーグ優先表示)
                StreamBuilder<QuerySnapshot>(
                  stream: _firestore.collection('tournaments').doc(_tournamentId).collection('brackets').snapshots(),
                  builder: (context, bracketSnap) {
                    if (!bracketSnap.hasData || bracketSnap.data!.docs.isEmpty) return const SizedBox();
                    // 自分のリーグを先頭に並び替え
                    final allBrackets = bracketSnap.data!.docs.toList();
                    allBrackets.sort((a, b) {
                      final aIsMyLeague = _isMyBracket(a.data() as Map<String, dynamic>);
                      final bIsMyLeague = _isMyBracket(b.data() as Map<String, dynamic>);
                      if (aIsMyLeague && !bIsMyLeague) return -1;
                      if (!aIsMyLeague && bIsMyLeague) return 1;
                      final aNum = ((a.data() as Map<String, dynamic>)['bracketNumber'] as num?) ?? 0;
                      final bNum = ((b.data() as Map<String, dynamic>)['bracketNumber'] as num?) ?? 0;
                      return aNum.compareTo(bNum);
                    });

                    // 全ブラケットの全試合完了状況をリアルタイム監視
                    return _BracketsWithCompletion(
                      tournamentId: _tournamentId,
                      allBrackets: allBrackets,
                      isOrganizer: isOrganizer,
                      status: status,
                      buildBracketSection: (id, data) => _buildBracketSection(id, data, isOrganizer, status),
                      onEndTournament: _showEndTournamentDialog,
                    );
                  },
                ),
              ]),
            );
          },
        );
      },
    );
  }



  // ━━━ 順位表タブ（全予選合計） ━━━
  Widget _buildStandingsTab() {
    if (_tournamentId.isEmpty) return const Center(child: Text('大会IDが見つかりません'));

    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId).collection('rounds').snapshots(),
      builder: (context, roundsSnap) {
        if (!roundsSnap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        final rounds = roundsSnap.data!.docs;
        if (rounds.isEmpty) {
          return const Center(child: Text('予選がまだ生成されていません', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)));
        }

        final roundIds = rounds.map((d) => d.id).toList();
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _FinalRankingsWidget(
                tournamentId: _tournamentId,
                tournamentName: widget.tournament['title'] as String? ?? '',
                myTeamIds: _myTeamIds,
              ),
              _OverallStandingsAggregator(
                tournamentId: _tournamentId,
                tournamentName: widget.tournament['title'] as String? ?? '',
                roundIds: roundIds,
                myTeamIds: _myTeamIds,
              ),
            ],
          ),
        );
      },
    );
  }

  // ━━━ ステータス変更 ━━━
  void _showStatusDialog(String currentStatus) {
    final statuses = ['準備中', '募集中', 'エントリー締切', '大会準備中', '開催中', '終了'];
    showDialog(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('ステータス変更', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, children: statuses.map((s) {
        return RadioListTile<String>(title: Text(s), value: s, groupValue: currentStatus, activeColor: AppTheme.primaryColor,
          onChanged: (v) async {
            if (v != null) {
              await _firestore.collection('tournaments').doc(_tournamentId).update({'status': v});
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                setState(() { widget.tournament['status'] = v; });
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ステータスを「$v」に変更しました'), backgroundColor: AppTheme.success));
              }
            }
          });
      }).toList()),
    ));
  }

  // ━━━ 削除 ━━━
  void _showDeleteDialog(String title) async {
    final confirmed = await _showTypedConfirmDialog(
      title: '大会を削除',
      description: '「$title」を削除します。\n全てのデータが完全に削除されます。\nこの操作は取り消せません。',
      confirmWord: '削除',
    );
    if (!confirmed) return;
    try {
      await _firestore.collection('tournaments').doc(_tournamentId).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('「$title」を削除しました'), backgroundColor: AppTheme.error));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  // ━━━ テンプレートに保存 ━━━
  Future<void> _saveAsTemplate(Map<String, dynamic> data) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final title = data['title'] ?? '大会';
    final rules = data['rules'] as Map<String, dynamic>? ?? {};
    final preliminary = rules['preliminary'] as Map<String, dynamic>? ?? {};

    await _firestore.collection('users').doc(uid).collection('templates').add({
      'name': '$titleのテンプレート',
      'type': data['type'] ?? '混合',
      'maxTeams': data['maxTeams'] ?? 8,
      'setCount': (preliminary['sets'] ?? '3').toString(),
      'pointsPerSet': (preliminary['pointsPerSet'] ?? '25').toString(),
      'location': data['location'] ?? '',
      'memo': '',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('テンプレートに保存しました'), backgroundColor: AppTheme.success),
      );
    }
  }

  // ━━━ 大会編集シート ━━━
  InputDecoration _sheetInputDecoration(String hint) {
    return InputDecoration(hintText: hint, hintStyle: const TextStyle(color: AppTheme.textHint),
      filled: true, fillColor: AppTheme.backgroundColor,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none));
  }

  void _showEditTournamentSheet(Map<String, dynamic> data, [BuildContext? navContext]) {
    final titleCtrl = TextEditingController(text: data['title'] ?? '');
    final locationCtrl = TextEditingController(text: data['location'] ?? '');
    final rawFee = data['entryFee'];
    final feeCtrl = TextEditingController(text: (rawFee is int ? rawFee : int.tryParse(rawFee.toString().replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toString());
    final maxTeamsCtrl = TextEditingController(text: (data['maxTeams'] ?? 8).toString());
    final courtsCtrl = TextEditingController(text: (data['courts'] ?? 2).toString());
    String selectedType = data['type'] ?? '混合';
    String selectedDate = data['date'] ?? '';
    Map<String, dynamic>? tournamentRules = (data['rules'] is Map) ? Map<String, dynamic>.from(data['rules']) : null;
    Map<String, dynamic>? selectedVenue;
    if (data['venueId'] != null && (data['venueId'] as String).isNotEmpty) {
      selectedVenue = {'id': data['venueId'], 'name': data['location'], 'address': data['venueAddress'] ?? ''};
    }

    // タイムスケジュール（概要に表示される5項目）を編集できるようにする
    String _fmtTime(String t) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t.trim());
      if (m != null) return '${m.group(1)!.padLeft(2, '0')}:${m.group(2)!}';
      return t;
    }
    String openTime = _fmtTime((data['openTime'] ?? '') as String);
    String captainMeetingTime = _fmtTime((data['captainMeetingTime'] ?? '') as String);
    String matchStartTime = _fmtTime((data['matchStartTime'] ?? '') as String);
    String finalTime = _fmtTime((data['finalTime'] ?? '') as String);
    String closingTime = _fmtTime((data['closingTime'] ?? '') as String);

    // 初期値を保存して変更検出に使う
    final origTitle = titleCtrl.text;
    final origLocation = locationCtrl.text;
    final origFee = feeCtrl.text;
    final origMaxTeams = maxTeamsCtrl.text;
    final origCourts = courtsCtrl.text;
    final origType = selectedType;
    final origDate = selectedDate;
    final origRules = tournamentRules;
    final origVenue = selectedVenue;
    final origOpenTime = openTime;
    final origCaptainMeetingTime = captainMeetingTime;
    final origMatchStartTime = matchStartTime;
    final origFinalTime = finalTime;
    final origClosingTime = closingTime;

    Navigator.of(navContext ?? context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) => StatefulBuilder(builder: (ctx, setPageState) {
        bool hasChanges() {
          return titleCtrl.text != origTitle || locationCtrl.text != origLocation ||
              feeCtrl.text != origFee || maxTeamsCtrl.text != origMaxTeams ||
              courtsCtrl.text != origCourts || selectedType != origType ||
              selectedDate != origDate || tournamentRules != origRules || selectedVenue != origVenue ||
              openTime != origOpenTime || captainMeetingTime != origCaptainMeetingTime ||
              matchStartTime != origMatchStartTime || finalTime != origFinalTime || closingTime != origClosingTime;
        }

        Future<bool> onWillPop() async {
          if (!hasChanges()) return true;
          final result = await showDialog<String>(
            context: ctx,
            builder: (dlgCtx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('編集内容の保存'),
              content: const Text('変更が保存されていません。保存してから閉じますか？'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dlgCtx, 'discard'), child: const Text('保存しない', style: TextStyle(color: AppTheme.textSecondary))),
                TextButton(onPressed: () => Navigator.pop(dlgCtx, 'cancel'), child: const Text('編集に戻る')),
                ElevatedButton(
                  onPressed: titleCtrl.text.trim().isNotEmpty && selectedDate.isNotEmpty && locationCtrl.text.trim().isNotEmpty
                      ? () => Navigator.pop(dlgCtx, 'save') : null,
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
                  child: const Text('保存する'),
                ),
              ],
            ),
          );
          if (result == 'save') {
            await _firestore.collection('tournaments').doc(_tournamentId).update({
              'title': titleCtrl.text.trim(), 'date': selectedDate, 'location': locationCtrl.text.trim(),
              'courts': int.tryParse(courtsCtrl.text) ?? 2, 'maxTeams': int.tryParse(maxTeamsCtrl.text) ?? 8,
              'entryFee': int.tryParse(feeCtrl.text.trim()) ?? 0, 'type': selectedType,
              'venueId': selectedVenue?['id'] ?? '', 'venueAddress': selectedVenue?['address'] ?? '',
              'rules': tournamentRules ?? {},
              'openTime': openTime, 'captainMeetingTime': captainMeetingTime,
              'matchStartTime': matchStartTime, 'finalTime': finalTime, 'closingTime': closingTime,
            });
            if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content: Text('大会情報を更新しました！'), backgroundColor: AppTheme.success));
            return true;
          }
          return result == 'discard';
        }

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final shouldPop = await onWillPop();
            if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
          },
          child: Scaffold(
            backgroundColor: AppTheme.backgroundColor,
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () async {
                  final shouldPop = await onWillPop();
                  if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
                },
              ),
              title: const Text('大会を編集', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              centerTitle: true,
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('大会名 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(controller: titleCtrl, maxLength: 30, onChanged: (_) => setPageState(() {}), decoration: _sheetInputDecoration('大会名を入力')),
              const SizedBox(height: 8),
              const Text('開催日 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: ctx, initialDate: DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (picked != null) setPageState(() => selectedDate = '${picked.year}/${picked.month.toString().padLeft(2, '0')}/${picked.day.toString().padLeft(2, '0')}');
                },
                child: Container(
                  width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(Icons.calendar_today, size: 18, color: AppTheme.textSecondary), const SizedBox(width: 10),
                    Text(selectedDate.isEmpty ? '日付を選択' : selectedDate, style: TextStyle(fontSize: 15, color: selectedDate.isEmpty ? AppTheme.textHint : AppTheme.textPrimary)),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              const Text('会場 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.push<Map<String, dynamic>>(ctx, MaterialPageRoute(builder: (_) => const VenueSearchScreen(pickerMode: true)));
                  if (result != null) setPageState(() { selectedVenue = result; locationCtrl.text = result['name'] ?? ''; courtsCtrl.text = (result['courts'] ?? courtsCtrl.text).toString(); });
                },
                child: Container(
                  width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(selectedVenue != null ? Icons.check_circle : Icons.search, size: 18, color: selectedVenue != null ? AppTheme.success : AppTheme.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(locationCtrl.text.isNotEmpty ? locationCtrl.text : '会場を探す',
                        style: TextStyle(fontSize: 15, color: locationCtrl.text.isNotEmpty ? AppTheme.textPrimary : AppTheme.textHint))),
                  ]),
                ),
              ),
              if (selectedVenue != null && (selectedVenue!['address'] ?? '').toString().isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(selectedVenue!['address'], style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('使用コート数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                  TextField(controller: courtsCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('2'),
                    onChanged: (_) => setPageState(() {})),
                ])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('募集チーム数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                  TextField(controller: maxTeamsCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('8'),
                    onChanged: (_) => setPageState(() {})),
                ])),
              ]),
              const SizedBox(height: 8),
              Builder(builder: (_) {
                final courts = int.tryParse(courtsCtrl.text) ?? 2;
                final teams = int.tryParse(maxTeamsCtrl.text) ?? 8;
                final tpc = courts > 0 ? (teams / courts).ceil() : teams;
                return Container(
                  width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(10)),
                  child: Text('1コート $tpc チーム（自動計算）', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                );
              }),
              const SizedBox(height: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('参加費（円）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                TextField(controller: feeCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('3000')),
              ]),
              const SizedBox(height: 16),
              const Text('カテゴリ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: ['混合', 'メンズ', 'レディース'].map((t) {
                return ChoiceChip(label: Text(t), selected: selectedType == t,
                    onSelected: (s) { if (s) setPageState(() => selectedType = t); },
                    selectedColor: AppTheme.primaryColor.withValues(alpha: 0.15));
              }).toList()),
              const SizedBox(height: 24),
              const Text('タイムスケジュール', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  _buildEditTimeRow('開場', openTime, (v) => setPageState(() => openTime = v), ctx),
                  _buildEditTimeRow('キャプテン会議', captainMeetingTime, (v) => setPageState(() => captainMeetingTime = v), ctx),
                  _buildEditTimeRow('試合開始', matchStartTime, (v) => setPageState(() => matchStartTime = v), ctx),
                  _buildEditTimeRow('終了', finalTime, (v) => setPageState(() => finalTime = v), ctx),
                  _buildEditTimeRow('完全撤退', closingTime, (v) => setPageState(() => closingTime = v), ctx),
                ]),
              ),
              const SizedBox(height: 24),
              Builder(builder: (_) {
                final status = normalizeTournamentStatus(data['status'] ?? '準備中');
                final isLocked = status == '開催中' || status == '決勝中' || status == '順位決定中' || status.contains('完了');
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: double.infinity, child: OutlinedButton.icon(
                    onPressed: isLocked ? null : () async {
                      final result = await Navigator.push<Map<String, dynamic>>(context,
                        MaterialPageRoute(builder: (_) => TournamentRulesScreen(initialRules: tournamentRules, courtCount: int.tryParse(courtsCtrl.text), maxTeams: int.tryParse(maxTeamsCtrl.text), entryFee: int.tryParse(feeCtrl.text))));
                      if (result != null) setPageState(() { tournamentRules = result; });
                    },
                    icon: Icon(
                      isLocked ? Icons.lock : (tournamentRules != null ? Icons.check_circle : Icons.tune),
                      color: isLocked ? AppTheme.textSecondary : (tournamentRules != null ? AppTheme.success : AppTheme.primaryColor),
                    ),
                    label: Text(
                      isLocked ? 'ルール変更不可（大会進行中）' : (tournamentRules != null ? 'ルール設定済み' : 'ルールを設定する'),
                      style: TextStyle(fontWeight: FontWeight.w600, color: isLocked ? AppTheme.textSecondary : (tournamentRules != null ? AppTheme.success : AppTheme.primaryColor)),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: isLocked ? Colors.grey[300]! : (tournamentRules != null ? AppTheme.success : AppTheme.primaryColor)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  )),
                  if (isLocked)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text('大会進行中はルールを変更できません', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ),
                ]);
              }),
              const SizedBox(height: 24),
              SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: titleCtrl.text.trim().isNotEmpty && selectedDate.isNotEmpty && locationCtrl.text.trim().isNotEmpty
                    ? () async {
                        await _firestore.collection('tournaments').doc(_tournamentId).update({
                          'title': titleCtrl.text.trim(), 'date': selectedDate, 'location': locationCtrl.text.trim(),
                          'courts': int.tryParse(courtsCtrl.text) ?? 2, 'maxTeams': int.tryParse(maxTeamsCtrl.text) ?? 8,
                          'entryFee': int.tryParse(feeCtrl.text.trim()) ?? 0, 'type': selectedType,
                          'venueId': selectedVenue?['id'] ?? '', 'venueAddress': selectedVenue?['address'] ?? '',
                          'rules': tournamentRules ?? {},
                          'openTime': openTime, 'captainMeetingTime': captainMeetingTime,
                          'matchStartTime': matchStartTime, 'finalTime': finalTime, 'closingTime': closingTime,
                        });
                        if (ctx.mounted) { Navigator.pop(ctx); ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content: Text('大会情報を更新しました！'), backgroundColor: AppTheme.success)); }
                      } : null,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[300], padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('保存する', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              )),
            ])),
          ),
        );
      }),
    ));
  }

  /// 大会編集シートのタイムスケジュール用・時刻選択行（CupertinoPicker で 5分刻み選択）。
  /// 空欄は '--:--' 表示。空にすると '--:--' を保存し、概要のタイムスケジュールでは
  /// 非表示になる（_hasTime でフィルタ済み）。
  Widget _buildEditTimeRow(String label, String value, Function(String) onChanged, BuildContext ctx) {
    final isEmpty = value.isEmpty || value == '--:--';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 96, child: Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(
          child: GestureDetector(
            onTap: () {
              final parts = (isEmpty ? '08:00' : value).split(':');
              var h = int.tryParse(parts[0]) ?? 8;
              var m = ((int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0) ~/ 5) * 5;
              final hourCtrl = FixedExtentScrollController(initialItem: h);
              final minCtrl = FixedExtentScrollController(initialItem: m ~/ 5);
              showModalBottomSheet(
                context: ctx,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                builder: (_) => SizedBox(
                  height: 280,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
                          const Text('時刻を選択', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          TextButton(
                            onPressed: () {
                              onChanged('${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}');
                              Navigator.pop(ctx);
                            },
                            child: const Text('完了', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Row(children: [
                        Expanded(
                          child: CupertinoPicker(
                            scrollController: hourCtrl,
                            itemExtent: 40,
                            onSelectedItemChanged: (i) => h = i,
                            children: List.generate(24, (i) => Center(child: Text('${i.toString().padLeft(2, '0')}時', style: const TextStyle(fontSize: 20)))),
                          ),
                        ),
                        Expanded(
                          child: CupertinoPicker(
                            scrollController: minCtrl,
                            itemExtent: 40,
                            onSelectedItemChanged: (i) => m = i * 5,
                            children: List.generate(12, (i) => Center(child: Text('${(i * 5).toString().padLeft(2, '0')}分', style: const TextStyle(fontSize: 20)))),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey[200]!)),
              child: Text(isEmpty ? '--:--' : value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isEmpty ? Colors.grey[400] : null)),
            ),
          ),
        ),
        if (!isEmpty)
          GestureDetector(
            onTap: () => onChanged('--:--'),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.close, size: 18, color: Colors.grey[400]),
            ),
          ),
      ]),
    );
  }

  // ━━━ CSVテンプレートダウンロード ━━━
  Future<void> _downloadCsvTemplate() async {
    const header = 'チーム名,キャプテン,メンバー1,メンバー2,メンバー3,メンバー4,メンバー5,メンバー6';
    const example1 = 'サンプルチームA,佐藤花子,田中太郎,佐藤花子,鈴木一郎,高橋美咲,,';
    const example2 = 'サンプルチームB,伊藤さくら,山田次郎,伊藤さくら,渡辺健太,中村あい,小林大輔,';
    final csvContent = '$header\n$example1\n$example2\n';

    try {
      await downloadCsvFile(csvContent, 'entry_template.csv');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('テンプレートの作成に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ━━━ CSV一括登録 ━━━
  Future<void> _importTeamsFromCsv() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final bytes = result.files.first.bytes;
    if (bytes == null) return;

    String csvString;
    try {
      csvString = utf8.decode(bytes);
    } catch (_) {
      // Shift_JIS等のエンコーディングの場合はlatin1でデコード
      csvString = latin1.decode(bytes);
    }

    final rows = const CsvToListConverter().convert(csvString);
    if (rows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSVファイルが空です'), backgroundColor: AppTheme.error),
        );
      }
      return;
    }

    // ヘッダー行をスキップするか判定
    final firstRow = rows.first;
    final hasHeader = firstRow.isNotEmpty &&
        (firstRow[0].toString().contains('チーム') || firstRow[0].toString().toLowerCase().contains('team'));

    // 「キャプテン」列があるか判定（2列目がキャプテン列）
    final hasCaptainCol = hasHeader && firstRow.length >= 2 &&
        (firstRow[1].toString().contains('キャプテン') || firstRow[1].toString().toLowerCase().contains('captain'));

    final dataRows = hasHeader ? rows.skip(1).toList() : rows;

    if (dataRows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登録するチームがありません'), backgroundColor: AppTheme.error),
        );
      }
      return;
    }

    // パース結果をプレビュー
    final teams = <Map<String, dynamic>>[];
    for (final row in dataRows) {
      if (row.isEmpty || row[0].toString().trim().isEmpty) continue;
      final teamName = row[0].toString().trim();
      final captainName = hasCaptainCol && row.length >= 2 ? row[1].toString().trim() : '';
      final memberStartIdx = hasCaptainCol ? 2 : 1;
      final members = <String, String>{};
      int memberNum = 1;
      for (int i = memberStartIdx; i < row.length; i++) {
        final name = row[i].toString().trim();
        if (name.isNotEmpty) {
          members['p$memberNum'] = name;
          memberNum++;
        }
      }
      teams.add({
        'teamName': teamName,
        'captainName': captainName,
        'members': members,
        'memberCount': members.length,
      });
    }

    if (teams.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('有効なチームデータがありません'), backgroundColor: AppTheme.error),
        );
      }
      return;
    }

    // プレビューダイアログ（自分のチームを選択可能）
    if (!mounted) return;
    int? myTeamIndex;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            const Icon(Icons.upload_file, color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            Text('${teams.length}チームを登録', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ]),
          content: SizedBox(
            width: double.maxFinite,
            height: 350,
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.touch_app, size: 16, color: Colors.red[400]),
                  const SizedBox(width: 6),
                  Expanded(child: Text('自分のチームをタップして選択', style: TextStyle(fontSize: 12, color: Colors.red[400]))),
                ]),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: teams.length,
                  itemBuilder: (ctx, i) {
                    final t = teams[i];
                    final members = t['members'] as Map<String, String>;
                    final isMyTeam = myTeamIndex == i;
                    return ListTile(
                      dense: true,
                      selected: isMyTeam,
                      selectedTileColor: Colors.red.withValues(alpha: 0.08),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: isMyTeam ? Colors.red.withValues(alpha: 0.15) : AppTheme.primaryColor.withValues(alpha: 0.1),
                        child: Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isMyTeam ? Colors.red : AppTheme.primaryColor)),
                      ),
                      title: Row(children: [
                        Expanded(child: Text(t['teamName'], style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isMyTeam ? Colors.red : null))),
                        if (isMyTeam)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                            child: const Text('自分', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red)),
                          ),
                      ]),
                      subtitle: Text(members.values.join(', '), style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      onTap: () => setDialogState(() => myTeamIndex = isMyTeam ? null : i),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
              child: const Text('登録する'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    // Firestoreに一括登録
    int count = 0;
    final batch = _firestore.batch();
    for (int i = 0; i < teams.length; i++) {
      final t = teams[i];
      final entryRef = _firestore.collection('tournaments').doc(_tournamentId).collection('entries').doc();
      final captain = (t['captainName'] as String? ?? '').isNotEmpty
          ? t['captainName'] as String
          : (t['members'] as Map<String, String>).values.firstOrNull ?? '';
      final isMyTeam = i == myTeamIndex;
      batch.set(entryRef, {
        'teamId': entryRef.id,
        'teamName': t['teamName'],
        'leaderName': captain,
        'memberCount': t['memberCount'],
        'memberNames': t['members'],
        'enteredBy': isMyTeam ? uid : '',
        if (isMyTeam && uid.isNotEmpty) 'leaderUid': uid,
        if (isMyTeam && uid.isNotEmpty) 'memberUids': [uid],
        'createdAt': FieldValue.serverTimestamp(),
      });
      count++;
    }
    // currentTeamsはCloud Function (onEntryCreated) で自動更新

    await batch.commit();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$countチームをCSVから登録しました'), backgroundColor: AppTheme.success),
      );
    }
  }

  /// 対戦表CSVインポート（予選用）
  Future<void> _importMatchTableFromCsv({int roundNumber = 1}) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final bytes = result.files.first.bytes;
    if (bytes == null) return;

    String csvString;
    try {
      csvString = utf8.decode(bytes);
    } catch (_) {
      csvString = latin1.decode(bytes);
    }

    final rows = const CsvToListConverter().convert(csvString);
    if (rows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSVファイルが空です'), backgroundColor: AppTheme.error),
        );
      }
      return;
    }

    // Parse match rows - detect format
    final matchRows = <Map<String, String>>[];
    final firstRow = rows.first;
    final firstCell = firstRow.isNotEmpty ? firstRow[0].toString().trim() : '';

    if (firstCell.contains('コート') || firstCell.toLowerCase().contains('court')) {
      // フラット形式: コート,試合順,チームA,チームB,審判,サブ,セット1A,セット1B,セット2A,セット2B,セット3A,セット3B
      final dataRows = rows.skip(1).toList();
      for (final row in dataRows) {
        if (row.length < 4) continue;
        final court = row[0].toString().trim();
        final order = row[1].toString().trim();
        final teamA = row[2].toString().trim();
        final teamB = row[3].toString().trim();
        final referee = row.length > 4 ? row[4].toString().trim() : '';
        final sub = row.length > 5 ? row[5].toString().trim() : '';
        if (teamA.isEmpty || teamB.isEmpty) continue;
        final m = {'court': court, 'matchOrder': order, 'teamA': teamA, 'teamB': teamB, 'referee': referee, 'subReferee': sub};
        // Parse score columns (index 6-11): セット1A,セット1B,セット2A,セット2B,セット3A,セット3B
        for (int s = 0; s < 3; s++) {
          final colA = 6 + s * 2;
          final colB = 7 + s * 2;
          final scoreA = row.length > colA ? row[colA].toString().trim() : '';
          final scoreB = row.length > colB ? row[colB].toString().trim() : '';
          if (scoreA.isNotEmpty && scoreB.isNotEmpty) {
            m['set${s + 1}A'] = scoreA;
            m['set${s + 1}B'] = scoreB;
          }
        }
        matchRows.add(m);
      }
    } else {
      // スプレッドシート横並び形式を自動検出
      matchRows.addAll(_parseSpreadsheetFormat(rows));
    }

    if (matchRows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('対戦データを読み取れませんでした'), backgroundColor: AppTheme.error),
        );
      }
      return;
    }

    // エントリー済みチーム名を取得して照合チェック
    final entriesSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('entries').get();
    final entryNames = entriesSnap.docs.map((d) => (d.data()['teamName'] as String? ?? '').trim()).toSet();

    final allTeamNames = <String>{};
    for (var m in matchRows) {
      allTeamNames.add(m['teamA']!);
      allTeamNames.add(m['teamB']!);
    }
    final unmatched = allTeamNames.where((n) => !entryNames.contains(n)).toList();

    // プレビューダイアログ
    if (!mounted) return;
    final courtCount = matchRows.map((m) => m['court']).toSet().length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.table_chart, color: AppTheme.primaryColor),
          const SizedBox(width: 8),
          Expanded(child: Text('予選$roundNumber 対戦表インポート', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        ]),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Builder(builder: (_) {
                final scoredCount = matchRows.where((m) => m.containsKey('set1A')).length;
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('$courtCountコート / ${matchRows.length}試合', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    Text('${allTeamNames.length}チーム', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    const SizedBox(height: 4),
                    if (scoredCount > 0)
                      Row(children: [
                        Icon(Icons.scoreboard, size: 14, color: AppTheme.success),
                        const SizedBox(width: 4),
                        Text('得点あり $scoredCount / ${matchRows.length}試合', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.success)),
                      ])
                    else
                      Row(children: [
                        Icon(Icons.info_outline, size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 4),
                        Text('得点なし（対戦表のみ）', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      ]),
                  ]),
                );
              }),
              if (unmatched.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppTheme.warning.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('未登録チーム (${unmatched.length})', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.warning)),
                    Text(unmatched.join(', '), style: TextStyle(fontSize: 12, color: AppTheme.warning)),
                  ]),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: matchRows.length,
                  itemBuilder: (_, i) {
                    final m = matchRows[i];
                    final hasScore = m.containsKey('set1A');
                    // Build score summary text
                    String scoreText = '';
                    if (hasScore) {
                      final parts = <String>[];
                      for (int s = 1; s <= 3; s++) {
                        if (m.containsKey('set${s}A')) {
                          parts.add('${m['set${s}A']}-${m['set${s}B']}');
                        }
                      }
                      scoreText = parts.join(' / ');
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                          alignment: Alignment.center,
                          child: Text(m['court']!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                        ),
                        const SizedBox(width: 6),
                        Text('${m['matchOrder']}', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        const SizedBox(width: 6),
                        Expanded(child: Text('${m['teamA']} vs ${m['teamB']}', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                        if (hasScore)
                          Text(scoreText, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.success)),
                      ]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
            child: const Text('インポート'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // インポート実行
    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      await MatchGenerator().importMatchTable(
        tournamentId: _tournamentId,
        roundNumber: roundNumber,
        matchRows: matchRows,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('対戦表をインポートしました（${matchRows.length}試合）'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  /// スプレッドシート横並びフォーマットのパース
  /// 例: Aコート,,,,,,Bコート,,,,,,
  ///     第1試合,,,審判,サブ,,第1試合,,,審判,サブ
  ///     テリー,-,GENYA-2,掛川クラブ,こやまーず,,ビンチトーレ,-,ブルースカイ,3MA,わっち
  List<Map<String, String>> _parseSpreadsheetFormat(List<List<dynamic>> rows) {
    final matchRows = <Map<String, String>>[];

    // 1. コートヘッダー行を検出（「コート」を含む行）
    // 各ブロックは: コートヘッダー行 → (試合行ペア: 試合番号行 + データ行) × N
    int i = 0;
    while (i < rows.length) {
      final row = rows[i];
      // コートヘッダー行を探す（「コート」を含むセルがある行）
      final courtNames = <int, String>{}; // columnIndex → courtLetter
      for (int col = 0; col < row.length; col++) {
        final cell = row[col].toString().trim();
        if (cell.contains('コート') && cell.isNotEmpty) {
          // "Aコート" → "A"
          final letter = cell.replaceAll('コート', '').trim();
          courtNames[col] = letter.isNotEmpty ? letter : String.fromCharCode(65 + courtNames.length);
        }
      }

      if (courtNames.isEmpty) {
        i++;
        continue;
      }

      // コートのスタート列を特定
      final courtStarts = courtNames.keys.toList()..sort();
      i++; // コートヘッダー行をスキップ

      // 試合データを読む（試合番号行 + データ行のペア）
      int matchOrder = 0;
      while (i < rows.length) {
        final testRow = rows[i];
        final testCell = testRow.isNotEmpty ? testRow[0].toString().trim() : '';

        // 次のコートヘッダーが来たら終了
        if (testCell.contains('コート') && !testCell.contains('試合')) break;

        // 「第N試合」行の場合、次の行がデータ行
        if (testCell.contains('試合')) {
          matchOrder++;
          i++;
          if (i >= rows.length) break;

          final dataRow = rows[i];
          // 各コートのデータを読み取る
          for (int ci = 0; ci < courtStarts.length; ci++) {
            final startCol = courtStarts[ci];
            final courtLetter = courtNames[startCol]!;

            // dataRow[startCol+0]=チームA, [+1]="-", [+2]=チームB, [+3]=審判, [+4]=サブ
            final teamA = (startCol < dataRow.length) ? dataRow[startCol].toString().trim() : '';
            final teamB = (startCol + 2 < dataRow.length) ? dataRow[startCol + 2].toString().trim() : '';
            final referee = (startCol + 3 < dataRow.length) ? dataRow[startCol + 3].toString().trim() : '';
            final subRef = (startCol + 4 < dataRow.length) ? dataRow[startCol + 4].toString().trim() : '';

            if (teamA.isNotEmpty && teamB.isNotEmpty && teamA != '-' && teamB != '-') {
              matchRows.add({
                'court': courtLetter,
                'matchOrder': matchOrder.toString(),
                'teamA': teamA,
                'teamB': teamB,
                'referee': referee,
                'subReferee': subRef,
              });
            }
          }
          i++;
        } else {
          i++;
        }
      }
    }

    return matchRows;
  }

  /// 決勝対戦表CSVインポート
  Future<void> _importFinalsFromCsv() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final bytes = result.files.first.bytes;
    if (bytes == null) return;

    String csvString;
    try {
      csvString = utf8.decode(bytes);
    } catch (_) {
      csvString = latin1.decode(bytes);
    }

    final rows = const CsvToListConverter().convert(csvString);
    if (rows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSVファイルが空です'), backgroundColor: AppTheme.error),
        );
      }
      return;
    }

    // フォーマット: ブラケット名,試合番号,ラウンド,チームA,チームB
    // 例: 上位,1,semi,チームA,チームD
    final hasHeader = rows.first.isNotEmpty &&
        (rows.first[0].toString().contains('ブラケット') || rows.first[0].toString().toLowerCase().contains('bracket'));
    final dataRows = hasHeader ? rows.skip(1).toList() : rows;

    // パース
    final bracketData = <String, List<Map<String, String>>>{};
    for (final row in dataRows) {
      if (row.length < 5) continue;
      final bracketName = row[0].toString().trim();
      final matchNumber = row[1].toString().trim();
      final round = row[2].toString().trim();
      final teamA = row[3].toString().trim();
      final teamB = row[4].toString().trim();
      if (bracketName.isEmpty || teamA.isEmpty || teamB.isEmpty) continue;
      bracketData.putIfAbsent(bracketName, () => []);
      final m = {
        'matchNumber': matchNumber,
        'round': round,
        'teamA': teamA,
        'teamB': teamB,
      };
      // Parse score columns (index 5-10): セット1A,セット1B,セット2A,セット2B,セット3A,セット3B
      for (int s = 0; s < 3; s++) {
        final colA = 5 + s * 2;
        final colB = 6 + s * 2;
        final scoreA = row.length > colA ? row[colA].toString().trim() : '';
        final scoreB = row.length > colB ? row[colB].toString().trim() : '';
        if (scoreA.isNotEmpty && scoreB.isNotEmpty) {
          m['set${s + 1}A'] = scoreA;
          m['set${s + 1}B'] = scoreB;
        }
      }
      bracketData[bracketName]!.add(m);
    }

    if (bracketData.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('決勝データを読み取れませんでした'), backgroundColor: AppTheme.error),
        );
      }
      return;
    }

    // エントリー済みチーム名を取得
    final entriesSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('entries').get();
    final nameToId = <String, String>{};
    for (var d in entriesSnap.docs) {
      final data = d.data();
      final name = (data['teamName'] as String? ?? '').trim();
      nameToId[name] = data['teamId'] ?? d.id;
    }

    final totalMatches = bracketData.values.fold<int>(0, (sum, list) => sum + list.length);

    // プレビュー
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.emoji_events, color: AppTheme.primaryColor),
          const SizedBox(width: 8),
          const Expanded(child: Text('決勝対戦表インポート', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        ]),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Builder(builder: (_) {
                final scoredCount = bracketData.values.expand((l) => l).where((m) => m.containsKey('set1A')).length;
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${bracketData.length}ブラケット / $totalMatches試合', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    if (scoredCount > 0)
                      Row(children: [
                        Icon(Icons.scoreboard, size: 14, color: AppTheme.success),
                        const SizedBox(width: 4),
                        Text('得点あり $scoredCount / $totalMatches試合', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.success)),
                      ])
                    else
                      Row(children: [
                        Icon(Icons.info_outline, size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 4),
                        Text('得点なし（対戦表のみ）', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      ]),
                  ]),
                );
              }),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: bracketData.entries.map((e) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(e.key, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        ),
                        ...e.value.map((m) {
                          final hasScore = m.containsKey('set1A');
                          String scoreText = '';
                          if (hasScore) {
                            final parts = <String>[];
                            for (int s = 1; s <= 3; s++) {
                              if (m.containsKey('set${s}A')) {
                                parts.add('${m['set${s}A']}-${m['set${s}B']}');
                              }
                            }
                            scoreText = ' (${parts.join(' / ')})';
                          }
                          return Padding(
                            padding: const EdgeInsets.only(left: 12, bottom: 2),
                            child: Text('${m['round']}#${m['matchNumber']}: ${m['teamA']} vs ${m['teamB']}$scoreText',
                                style: TextStyle(fontSize: 12, color: hasScore ? AppTheme.success : null)),
                          );
                        }),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
            child: const Text('インポート'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Firestore に書き込み
    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));

      int bracketNum = 0;
      for (var entry in bracketData.entries) {
        bracketNum++;
        final bracketRef = _firestore.collection('tournaments').doc(_tournamentId)
            .collection('brackets').doc('bracket_$bracketNum');

        await bracketRef.set({
          'bracketNumber': bracketNum,
          'bracketName': entry.key,
          'teamCount': entry.value.expand((m) => [m['teamA']!, m['teamB']!]).toSet().length,
          'type': 'tournament',
          'status': 'pending',
        });

        for (var m in entry.value) {
          final teamAName = m['teamA']!;
          final teamBName = m['teamB']!;
          final teamAId = nameToId[teamAName] ?? teamAName;
          final teamBId = nameToId[teamBName] ?? teamBName;

          // Parse scores from CSV
          final sets = <Map<String, int>>[];
          for (int s = 1; s <= 3; s++) {
            final a = int.tryParse(m['set${s}A'] ?? '');
            final b = int.tryParse(m['set${s}B'] ?? '');
            if (a != null && b != null) {
              sets.add({'a': a, 'b': b});
            }
          }
          final hasScore = sets.isNotEmpty;

          Map<String, dynamic> result = {};
          String status = 'pending';
          if (hasScore) {
            int setsA = 0, setsB = 0, totalA = 0, totalB = 0;
            for (var set in sets) {
              totalA += set['a']!;
              totalB += set['b']!;
              if (set['a']! > set['b']!) setsA++;
              else if (set['b']! > set['a']!) setsB++;
            }
            final winner = setsA > setsB ? teamAId : (setsB > setsA ? teamBId : (totalA > totalB ? teamAId : (totalB > totalA ? teamBId : '引き分け')));
            result = {
              'setsA': setsA, 'setsB': setsB,
              'totalPointsA': totalA, 'totalPointsB': totalB,
              'winner': winner,
            };
            status = 'completed';
          }

          await bracketRef.collection('matches').add({
            'round': m['round'] ?? 'semi',
            'matchNumber': int.tryParse(m['matchNumber'] ?? '1') ?? 1,
            'teamAId': teamAId,
            'teamAName': teamAName,
            'teamBId': teamBId,
            'teamBName': teamBName,
            'status': status,
            'sets': sets,
            'result': result,
          });
        }

        // 得点付き試合がある場合、ブラケット進行を更新（semi勝者→finalへ反映など）
        final hasAnyScore = entry.value.any((m) => m.containsKey('set1A'));
        if (hasAnyScore) {
          await MatchGenerator().updateBracketProgression(
            tournamentId: _tournamentId, bracketId: 'bracket_$bracketNum');

          // 全試合完了ならブラケットstatusも更新
          final allDone = entry.value.every((m) => m.containsKey('set1A'));
          if (allDone) {
            await bracketRef.update({'status': 'completed'});
          } else {
            await bracketRef.update({'status': 'in_progress'});
          }
        }
      }

      await _firestore.collection('tournaments').doc(_tournamentId).update({'status': '順位決定中'});

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('決勝対戦表をインポートしました（$totalMatches試合）'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  /// 予選対戦表CSVテンプレートダウンロード（大会専用）
  Future<void> _downloadMatchTableTemplate() async {
    try {
    final rules = widget.tournament['rules'] as Map<String, dynamic>? ?? {};
    final preliminary = rules['preliminary'] as Map<String, dynamic>? ?? {};
    final courtCount = (widget.tournament['courts'] as num?)?.toInt() ?? 2;
    final prelimRounds = (preliminary['rounds'] as num?)?.toInt() ?? 1;

    // セット数を取得
    int setCount;
    if (prelimRounds == 2) {
      final r1 = preliminary['round1'] as Map<String, dynamic>? ?? {};
      setCount = (r1['sets'] as num?)?.toInt() ?? (preliminary['sets'] as num?)?.toInt() ?? 2;
    } else {
      setCount = (preliminary['sets'] as num?)?.toInt() ?? 2;
    }

    // ヘッダー生成（セット数に応じた列）
    final scoreCols = List.generate(setCount, (i) => 'セット${i + 1}A(任意),セット${i + 1}B(任意)').join(',');
    final header = 'コート,試合順,チームA,チームB,審判,サブ,$scoreCols';
    final emptyScores = List.generate(setCount * 2, (_) => '').join(',');

    final rows = <String>[];

    // 既存の対戦表があるか確認（予選1）
    final roundRef = _firestore.collection('tournaments').doc(_tournamentId)
        .collection('rounds').doc('round_1');
    final matchesSnap = await roundRef.collection('matches').orderBy('matchOrder').get();

    if (matchesSnap.docs.isNotEmpty) {
      // ━━━ 対戦表生成済み → 既存マッチからテンプレ生成 ━━━
      for (var doc in matchesSnap.docs) {
        final m = doc.data();
        final courtNum = (m['courtNumber'] as num?)?.toInt() ?? 1;
        final courtLetter = String.fromCharCode(64 + courtNum); // 1→A, 2→B
        final existingSets = m['sets'] as List<dynamic>? ?? [];
        final scoreValues = <String>[];
        for (int i = 0; i < setCount; i++) {
          if (i < existingSets.length && existingSets[i] is Map) {
            final a = existingSets[i]['a'] ?? '';
            final b = existingSets[i]['b'] ?? '';
            // 0,0 は未入力とみなして空にする
            if (a == 0 && b == 0) {
              scoreValues.addAll(['', '']);
            } else {
              scoreValues.addAll(['$a', '$b']);
            }
          } else {
            scoreValues.addAll(['', '']);
          }
        }
        rows.add('$courtLetter,${m['matchOrder']},${m['teamAName']},${m['teamBName']},${m['refereeTeamName'] ?? ''},${m['subRefereeTeamName'] ?? ''},${scoreValues.join(',')}');
      }
    } else {
      // ━━━ 対戦表未生成 → エントリーからスケルトン生成 ━━━
      final entriesSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('entries').get();
      final teamNames = entriesSnap.docs.map((d) => (d.data()['teamName'] as String? ?? '').trim()).where((n) => n.isNotEmpty).toList();

      if (teamNames.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('エントリーがありません。先にチームを登録してください'), backgroundColor: AppTheme.error),
          );
        }
        return;
      }

      // コートにチームを均等分配
      final courts = <List<String>>[];
      final actualCourts = courtCount > 0 ? courtCount : 2;
      for (int i = 0; i < actualCourts; i++) {
        courts.add([]);
      }
      for (int i = 0; i < teamNames.length; i++) {
        courts[i % actualCourts].add(teamNames[i]);
      }

      // 各コートのチーム用に行を生成（対戦組み合わせは空欄でチーム名だけ列挙）
      for (int c = 0; c < courts.length; c++) {
        final courtLetter = String.fromCharCode(65 + c); // A, B, C...
        final teams = courts[c];
        int matchOrder = 1;
        // ラウンドロビン的にペアを作る
        for (int i = 0; i < teams.length; i++) {
          for (int j = i + 1; j < teams.length; j++) {
            rows.add('$courtLetter,$matchOrder,${teams[i]},${teams[j]},,$emptyScores');
            matchOrder++;
          }
        }
      }
    }

    final csvContent = '$header\n${rows.join('\n')}\n';
    final title = widget.tournament['title'] ?? '大会';
    await downloadCsvFile(csvContent, '${title}_予選対戦表テンプレート.csv');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('テンプレートの作成に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  /// 決勝対戦表CSVテンプレートダウンロード（大会専用）
  Future<void> _downloadFinalsTemplate() async {
    try {
    final rules = widget.tournament['rules'] as Map<String, dynamic>? ?? {};
    final finalRules = rules['final'] as Map<String, dynamic>? ?? {};
    final setCount = (finalRules['sets'] as num?)?.toInt() ?? 3;

    // ヘッダー生成
    final scoreCols = List.generate(setCount, (i) => 'セット${i + 1}A(任意),セット${i + 1}B(任意)').join(',');
    final header = 'ブラケット名,試合番号,ラウンド,チームA,チームB,$scoreCols';
    final emptyScores = List.generate(setCount * 2, (_) => '').join(',');

    final rows = <String>[];

    // 既存のブラケットがあるか確認
    final bracketsSnap = await _firestore.collection('tournaments').doc(_tournamentId)
        .collection('brackets').get();

    if (bracketsSnap.docs.isNotEmpty) {
      // ━━━ ブラケット生成済み → 既存マッチからテンプレ生成 ━━━
      for (var bracketDoc in bracketsSnap.docs) {
        final bracketData = bracketDoc.data();
        final bracketName = bracketData['bracketName'] ?? bracketDoc.id;
        final matchesSnap = await bracketDoc.reference.collection('matches').orderBy('matchNumber').get();

        for (var matchDoc in matchesSnap.docs) {
          final m = matchDoc.data();
          final existingSets = m['sets'] as List<dynamic>? ?? [];
          final scoreValues = <String>[];
          for (int i = 0; i < setCount; i++) {
            if (i < existingSets.length && existingSets[i] is Map) {
              final a = existingSets[i]['a'] ?? '';
              final b = existingSets[i]['b'] ?? '';
              if (a == 0 && b == 0) {
                scoreValues.addAll(['', '']);
              } else {
                scoreValues.addAll(['$a', '$b']);
              }
            } else {
              scoreValues.addAll(['', '']);
            }
          }
          rows.add('$bracketName,${m['matchNumber']},${m['round'] ?? ''},${m['teamAName'] ?? ''},${m['teamBName'] ?? ''},${scoreValues.join(',')}');
        }
      }
    } else {
      // ━━━ ブラケット未生成 → エントリーからスケルトン生成 ━━━
      final entriesSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('entries').get();
      final teamNames = entriesSnap.docs.map((d) => (d.data()['teamName'] as String? ?? '').trim()).where((n) => n.isNotEmpty).toList();

      if (teamNames.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('エントリーがありません。先にチームを登録してください'), backgroundColor: AppTheme.error),
          );
        }
        return;
      }

      // 簡易的にチーム名を列挙したテンプレを出力
      final tierCount = (finalRules['tierCount'] as num?)?.toInt() ?? 2;
      final tierNames = ['上位', '中位', '下位'];
      final teamsPerTier = (teamNames.length / tierCount).ceil().clamp(2, teamNames.length);

      int teamIdx = 0;
      for (int t = 0; t < tierCount; t++) {
        final tierName = t < tierNames.length ? tierNames[t] : 'リーグ${t + 1}';
        final tierTeams = <String>[];
        for (int i = 0; i < teamsPerTier && teamIdx < teamNames.length; i++) {
          tierTeams.add(teamNames[teamIdx++]);
        }
        // semi-final pairs
        int matchNum = 1;
        for (int i = 0; i < tierTeams.length; i += 2) {
          final teamA = tierTeams[i];
          final teamB = (i + 1 < tierTeams.length) ? tierTeams[i + 1] : '';
          rows.add('$tierName,$matchNum,semi,$teamA,$teamB,$emptyScores');
          matchNum++;
        }
        // final placeholder
        rows.add('$tierName,$matchNum,final_1st,準決勝①勝者,準決勝②勝者,$emptyScores');
        matchNum++;
        rows.add('$tierName,$matchNum,final_3rd,準決勝①敗者,準決勝②敗者,$emptyScores');
      }
    }

    final csvContent = '$header\n${rows.join('\n')}\n';
    final title = widget.tournament['title'] ?? '大会';
    await downloadCsvFile(csvContent, '${title}_決勝対戦表テンプレート.csv');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('テンプレートの作成に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  /// CSVインポートメニュー画面を表示
  void _showCsvImportMenu() {
    final rules = widget.tournament['rules'] as Map<String, dynamic>? ?? {};
    final preliminary = rules['preliminary'] as Map<String, dynamic>? ?? {};
    final prelimRounds = preliminary['rounds'] ?? 1;
    final finalEnabled = (rules['final'] as Map<String, dynamic>?)?['enabled'] ?? true;

    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _CsvImportMenuScreen(
        prelimRounds: prelimRounds is int ? prelimRounds : 1,
        finalEnabled: finalEnabled is bool ? finalEnabled : true,
        onEntryUpload: _importTeamsFromCsv,
        onEntryTemplate: _downloadCsvTemplate,
        onMatchTableUpload1: () => _importMatchTableFromCsv(roundNumber: 1),
        onMatchTableUpload2: () => _importMatchTableFromCsv(roundNumber: 2),
        onMatchTableTemplate: _downloadMatchTableTemplate,
        onFinalsUpload: _importFinalsFromCsv,
        onFinalsTemplate: _downloadFinalsTemplate,
      ),
    ));
  }

  void _showEditorsSheet() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 12),
              Row(children: [
                const Expanded(child: Text('編集者を管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
              ]),
              const SizedBox(height: 4),
              Text('編集権限を持つユーザーは大会情報を編集できます', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 16),

              // 現在の編集者リスト
              StreamBuilder<DocumentSnapshot>(
                stream: _firestore.collection('tournaments').doc(_tournamentId).snapshots(),
                builder: (context, snap) {
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
                  final tournData = snap.data!.data() as Map<String, dynamic>? ?? {};
                  final editors = List<String>.from(tournData['editors'] ?? []);

                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('編集者 ${editors.length}人', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (editors.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                        child: const Center(child: Text('まだ編集者がいません', style: TextStyle(color: AppTheme.textHint))),
                      )
                    else
                      ...editors.map((editorUid) => FutureBuilder<DocumentSnapshot>(
                        future: _firestore.collection('users').doc(editorUid).get(),
                        builder: (context, userSnap) {
                          final name = userSnap.data?.data() != null
                              ? ((userSnap.data!.data() as Map<String, dynamic>)['nickname'] ?? '名前なし')
                              : '読み込み中...';
                          final avatar = userSnap.data?.data() != null
                              ? ((userSnap.data!.data() as Map<String, dynamic>)['avatarUrl'] ?? '').toString()
                              : '';
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: avatar.isNotEmpty
                                ? CircleAvatar(radius: 18, backgroundImage: NetworkImage(avatar))
                                : CircleAvatar(radius: 18, backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                                    child: Text(name.toString().isNotEmpty ? name.toString()[0] : '?',
                                        style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold))),
                            title: Text(name.toString(), style: const TextStyle(fontSize: 14)),
                            trailing: IconButton(
                              icon: const Icon(Icons.remove_circle_outline, color: AppTheme.error),
                              onPressed: () async {
                                await _firestore.collection('tournaments').doc(_tournamentId).update({
                                  'editors': FieldValue.arrayRemove([editorUid]),
                                });
                                setSheetState(() {});
                              },
                            ),
                          );
                        },
                      )),
                  ]);
                },
              ),
              const SizedBox(height: 16),

              // フォロー中から追加
              const Text('フォロー中から追加', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              StreamBuilder<QuerySnapshot>(
                stream: _firestore.collection('users').doc(uid).collection('following').snapshots(),
                builder: (context, followSnap) {
                  if (!followSnap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
                  final followings = followSnap.data!.docs;
                  if (followings.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                      child: const Center(child: Text('フォロー中のユーザーがいません', style: TextStyle(color: AppTheme.textHint))),
                    );
                  }
                  return StreamBuilder<DocumentSnapshot>(
                    stream: _firestore.collection('tournaments').doc(_tournamentId).snapshots(),
                    builder: (context, tournSnap) {
                      final currentEditors = List<String>.from(
                          (tournSnap.data?.data() as Map<String, dynamic>?)?['editors'] ?? []);
                      return Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey[200]!),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: followings.length,
                          itemBuilder: (context, index) {
                            final fDoc = followings[index];
                            final fUid = fDoc.id;
                            final isAlreadyEditor = currentEditors.contains(fUid);

                            // ユーザードキュメントから最新の名前・アバターを取得
                            return FutureBuilder<DocumentSnapshot>(
                              future: _firestore.collection('users').doc(fUid).get(),
                              builder: (context, userSnap) {
                                final fData = fDoc.data() as Map<String, dynamic>;
                                final userData = userSnap.data?.data() as Map<String, dynamic>?;
                                final fName = userData?['nickname'] ?? fData['nickname'] ?? fData['userName'] ?? '名前なし';
                                final fAvatar = userData?['avatarUrl'] ?? fData['avatarUrl'] ?? '';

                                return ListTile(
                                  leading: fAvatar.toString().isNotEmpty
                                      ? CircleAvatar(backgroundImage: NetworkImage(fAvatar.toString()), radius: 18)
                                      : CircleAvatar(radius: 18, backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                                          child: Text(fName.toString().isNotEmpty ? fName.toString()[0] : '?',
                                              style: const TextStyle(color: AppTheme.primaryColor))),
                                  title: Text(fName.toString(), style: const TextStyle(fontSize: 14)),
                                  trailing: isAlreadyEditor
                                      ? const Icon(Icons.check_circle, color: AppTheme.success)
                                      : IconButton(
                                          icon: const Icon(Icons.add_circle_outline, color: AppTheme.primaryColor),
                                          onPressed: () async {
                                            await _firestore.collection('tournaments').doc(_tournamentId).update({
                                              'editors': FieldValue.arrayUnion([fUid]),
                                            });
                                            setSheetState(() {});
                                          },
                                        ),
                                );
                              },
                            );
                          },
                        ),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 16),
            ]),
          );
        });
      },
    );
  }

  void _showAnnouncementDialog() {
    final messageCtrl = TextEditingController();
    final t = widget.tournament;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.campaign, color: AppTheme.accentColor, size: 22),
          const SizedBox(width: 8),
          const Text('お知らせを送信', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('全参加者に通知が届きます', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: messageCtrl,
              maxLines: 4,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: '例: 持ち物の確認、集合場所の変更など',
                hintStyle: TextStyle(fontSize: 14, color: AppTheme.textHint),
                filled: true, fillColor: AppTheme.backgroundColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.check_circle_outline, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 4),
              Text('掲示板にも同時投稿されます', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final message = messageCtrl.text.trim();
              if (message.isEmpty) return;
              Navigator.pop(ctx);

              final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
              final userDoc = await _firestore.collection('users').doc(uid).get();
              final nickname = userDoc.data()?['nickname'] ?? '主催者';
              final avatar = (userDoc.data()?['avatarUrl'] ?? '') as String;

              // 掲示板に投稿（ピン留め＋お知らせラベル付き）
              await _firestore.collection('tournaments').doc(_tournamentId).collection('timeline').add({
                'authorId': uid,
                'authorName': nickname,
                'authorAvatar': avatar,
                'text': message,
                'isOrganizer': true,
                'pinned': true,
                'isAnnouncement': true,
                'likesCount': 0,
                'createdAt': FieldValue.serverTimestamp(),
              });

              // 全参加者に通知
              NotificationService.sendTournamentAnnouncement(
                tournamentId: _tournamentId,
                tournamentName: t['name'] as String? ?? t['title'] as String? ?? '',
                senderId: uid,
                senderName: nickname,
                message: message,
              );

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('お知らせを送信しました'), backgroundColor: AppTheme.success),
                );
              }
            },
            icon: const Icon(Icons.send, size: 16),
            label: const Text('送信'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  void _showEndTournamentDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('大会を終了する', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text('大会を終了しますか？\nステータスが「終了」に変わり、結果が表示されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              await _firestore.collection('tournaments').doc(_tournamentId).update({'status': '終了'});
              if (ctx.mounted) Navigator.pop(ctx);
              // ポイント付与（完了を待つ）
              await PointService.awardTournamentPoints(
                tournamentId: _tournamentId,
              );
              // 全参加者に結果通知 + タイムライン自動投稿
              final t = widget.tournament;
              final tournamentName = t['name'] as String? ?? t['title'] as String? ?? '';
              await NotificationService.sendTournamentEndNotification(
                tournamentId: _tournamentId,
                tournamentName: tournamentName,
                tournamentDate: t['date'] as String? ?? '',
                organizerId: t['organizerId'] as String? ?? '',
                organizerName: t['organizerName'] as String? ?? '',
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('大会を終了しました。参加者に通知を送信しました'), backgroundColor: AppTheme.success),
                );
                // ふりかえりアクション画面を表示
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PostEventActionScreen(
                      tournamentId: _tournamentId,
                      tournamentName: tournamentName,
                    ),
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('終了する'),
          ),
        ],
      ),
    );
  }

  Widget _buildCourtChipsForRound(int roundNum, List<MapEntry<String, int>> sortedCourts, Set<String> myCourts) {
    // 1コート以下ならチップバー不要
    if (sortedCourts.length <= 1) return const SizedBox();

    final filter = _selectedCourtFilter.containsKey(roundNum) ? _selectedCourtFilter[roundNum] : 'MY';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 38,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            // 「全て」チップ
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: const Text('全て'),
                selected: filter == null,
                selectedColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                labelStyle: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: filter == null ? AppTheme.primaryColor : AppTheme.textSecondary,
                ),
                side: BorderSide(color: filter == null ? AppTheme.primaryColor : Colors.grey[300]!),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                showCheckmark: false,
                onSelected: (_) => setState(() { _selectedCourtFilter[roundNum] = null; _showOnlyMyCourts = false; }),
              ),
            ),
            // 「MY」チップ（自チームがある場合のみ）
            if (myCourts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: const Text('MY'),
                  selected: filter == 'MY',
                  selectedColor: AppTheme.accentColor.withValues(alpha: 0.15),
                  labelStyle: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.bold,
                    color: filter == 'MY' ? AppTheme.accentColor : AppTheme.accentColor.withValues(alpha: 0.7),
                  ),
                  side: BorderSide(color: filter == 'MY' ? AppTheme.accentColor : AppTheme.accentColor.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  showCheckmark: false,
                  onSelected: (_) => setState(() {
                    _selectedCourtFilter[roundNum] = filter == 'MY' ? null : 'MY';
                    _showOnlyMyCourts = false;
                  }),
                ),
              ),
            // 各コートチップ
            ...sortedCourts.map((court) {
              final courtId = court.key;
              final courtNum = court.value;
              final label = '${String.fromCharCode(64 + courtNum)}';
              final isSelected = filter == courtId;
              final isMyCourt = myCourts.contains(courtId);
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(label),
                    if (isMyCourt) ...[
                      const SizedBox(width: 3),
                      Icon(Icons.star, size: 12, color: isSelected ? AppTheme.primaryColor : AppTheme.accentColor),
                    ],
                  ]),
                  selected: isSelected,
                  selectedColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                  labelStyle: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: isSelected ? AppTheme.primaryColor : AppTheme.textSecondary,
                  ),
                  side: BorderSide(color: isSelected ? AppTheme.primaryColor : Colors.grey[300]!),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  showCheckmark: false,
                  onSelected: (_) => setState(() {
                    _selectedCourtFilter[roundNum] = isSelected ? null : courtId;
                    _showOnlyMyCourts = false;
                  }),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildRoundSection(String roundId, int roundNum, bool isOrganizer, {bool defaultCollapsed = false, String tournamentStatus = ''}) {
    final isCollapsed = _collapsedRounds[roundNum] ?? defaultCollapsed;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => setState(() => _collapsedRounds[roundNum] = !isCollapsed),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Text('予選$roundNum', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
              const SizedBox(width: 4),
              Icon(
                isCollapsed ? Icons.arrow_right : Icons.arrow_drop_down,
                color: AppTheme.primaryColor,
                size: 28,
              ),
            ],
          ),
        ),
      ),
      if (!isCollapsed)
      StreamBuilder<QuerySnapshot>(
        stream: _firestore.collection('tournaments').doc(_tournamentId)
            .collection('rounds').doc(roundId)
            .collection('matches').orderBy('matchOrder').snapshots(),
        builder: (context, matchSnap) {
          if (!matchSnap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
          final matches = matchSnap.data!.docs;
          if (matches.isEmpty) return const Text('試合がありません');

          // Group by court
          final courtGroups = <String, List<QueryDocumentSnapshot>>{};
          for (var m in matches) {
            final courtId = (m.data() as Map<String, dynamic>)['courtId'] ?? '';
            courtGroups.putIfAbsent(courtId, () => []);
            courtGroups[courtId]!.add(m);
          }

          // 自分のチームが属するコートを特定
          final myCourts = <String>{};
          for (var entry in courtGroups.entries) {
            for (var m in entry.value) {
              final md = m.data() as Map<String, dynamic>;
              if (_myTeamIds.contains(md['teamAId'] ?? '') || _myTeamIds.contains(md['teamBId'] ?? '') ||
                  _myTeamIds.contains(md['refereeTeamId'] ?? '') || _myTeamIds.contains(md['subRefereeTeamId'] ?? '')) {
                myCourts.add(entry.key);
                break;
              }
            }
          }
          _myCourtIds = myCourts;

          final sortedCourts = courtGroups.entries.toList()..sort((a, b) {
            final aNum = ((a.value.first.data() as Map<String, dynamic>)['courtNumber'] as num?) ?? 0;
            final bNum = ((b.value.first.data() as Map<String, dynamic>)['courtNumber'] as num?) ?? 0;
            return aNum.compareTo(bNum);
          });

          // コートチップ用データ
          final courtChipData = sortedCourts.map((e) {
            final cn = ((e.value.first.data() as Map<String, dynamic>)['courtNumber'] as num?) ?? 0;
            return MapEntry(e.key, cn.toInt());
          }).toList();

          final filter = _selectedCourtFilter.containsKey(roundNum) ? _selectedCourtFilter[roundNum] : 'MY';
          List<MapEntry<String, List<QueryDocumentSnapshot>>> filteredCourts;
          if (filter == 'MY') {
            filteredCourts = sortedCourts.where((court) => myCourts.contains(court.key)).toList();
          } else if (filter != null) {
            filteredCourts = sortedCourts.where((court) => court.key == filter).toList();
          } else if (_showOnlyMyCourts) {
            filteredCourts = sortedCourts.where((court) => myCourts.contains(court.key)).toList();
          } else {
            filteredCourts = sortedCourts;
          }

          return Column(children: [
            _buildCourtChipsForRound(roundNum, courtChipData, myCourts),
            ...filteredCourts.map((court) {
              final courtNum = (court.value.first.data() as Map<String, dynamic>)['courtNumber'] ?? 0;
              return _buildCourtCard(court.key, courtNum, court.value, roundId, isOrganizer, tournamentStatus: tournamentStatus);
            }),
          ]);
        },
      ),
      // Standings removed — now in dedicated 順位表 tab
      const SizedBox(height: 8),
    ]);
  }

  // 未確定だが既にスコアが入力されている（入力中）かどうかと、暫定セット数を返す
  // sets はスコア入力画面でオートセーブされる。0-0 のみのセットは「未入力」とみなす。
  (bool, int, int) _matchProgress(Map<String, dynamic> m) {
    final sets = (m['sets'] as List<dynamic>?) ?? [];
    int sa = 0, sb = 0;
    bool hasInput = false;
    for (final s in sets) {
      if (s is! Map) continue;
      final a = ((s['a'] ?? 0) as num).toInt();
      final b = ((s['b'] ?? 0) as num).toInt();
      if (a > 0 || b > 0) hasInput = true;
      if (a > b) {
        sa++;
      } else if (b > a) {
        sb++;
      }
    }
    return (hasInput, sa, sb);
  }

  Widget _buildCourtCard(String courtId, int courtNum, List<QueryDocumentSnapshot> matches, String roundId, bool isOrganizer, {String tournamentStatus = ''}) {
    // 自分のチームがこのコートに属しているか
    final isMyCourt = matches.any((m) {
      final md = m.data() as Map<String, dynamic>;
      return _myTeamIds.contains(md['teamAId'] ?? '') || _myTeamIds.contains(md['teamBId'] ?? '') ||
             _myTeamIds.contains(md['refereeTeamId'] ?? '') || _myTeamIds.contains(md['subRefereeTeamId'] ?? '');
    });
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isMyCourt ? AppTheme.primaryColor.withValues(alpha: 0.5) : Colors.grey[200]!, width: isMyCourt ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isMyCourt ? AppTheme.primaryColor.withValues(alpha: 0.06) : Colors.grey[50],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(children: [
            Icon(Icons.sports_volleyball, size: 18, color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            Text('${String.fromCharCode(64 + courtNum)}コート', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            if (isMyCourt) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: AppTheme.primaryColor, borderRadius: BorderRadius.circular(4)),
                child: const Text('MY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ],
            const Spacer(),
            Text('${matches.length}試合', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
        ...matches.map((mDoc) {
          final m = mDoc.data() as Map<String, dynamic>;
          final status = m['status'] ?? 'pending';
          final sets = (m['sets'] as List<dynamic>?) ?? [];
          final result = m['result'] as Map<String, dynamic>? ?? {};
          final matchOrder = m['matchOrder'] ?? 0;

          final matchOrd = m['matchOrder'] ?? 1;
          final prevMatch = matchOrd > 1 ? matches.where((prev) {
            final pd = prev.data() as Map<String, dynamic>;
            return (pd['matchOrder'] ?? 0) == matchOrd - 1;
          }).firstOrNull : null;
          final prevDone = matchOrd <= 1 || (prevMatch != null && (prevMatch.data() as Map<String, dynamic>)['status'] == 'completed');
          final isReferee = _myTeamIds.contains(m['refereeTeamId'] ?? '') || _myTeamIds.contains(m['subRefereeTeamId'] ?? '');
          final isMyMatch = _myTeamIds.contains(m['teamAId'] ?? '') || _myTeamIds.contains(m['teamBId'] ?? '') || isReferee;
          final canInput = isOrganizer || isMyMatch;
          final isCompleted = status == 'completed';
          final (hasInput, provSetsA, provSetsB) = _matchProgress(m);
          final isInProgress = !isCompleted && hasInput;
          final isNextToInput = !isCompleted && !isInProgress && prevDone && isMyMatch;
          return InkWell(
            onTap: () {
              // 終了した大会はスコアを閲覧のみ可能
              if (tournamentStatus == '終了') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => ScoreInputScreen(
                  tournamentId: _tournamentId, matchId: mDoc.id, roundId: roundId, isOrganizer: isOrganizer, tournamentStatus: tournamentStatus)));
                return;
              }
              if (tournamentStatus != '開催中') {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("得点入力は大会が「開催中」の場合のみ可能です"), backgroundColor: AppTheme.warning));
                return;
              }
              if (isCompleted && !isOrganizer) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("この試合は確定済みです。編集は大会主催者のみ可能です"), backgroundColor: AppTheme.warning));
                return;
              }
              if (!canInput) return;
              if (!prevDone) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("前の試合が完了してから入力してください"), backgroundColor: AppTheme.warning));
                return;
              }
              Navigator.push(context, MaterialPageRoute(builder: (_) => ScoreInputScreen(
                tournamentId: _tournamentId, matchId: mDoc.id, roundId: roundId, isOrganizer: isOrganizer, tournamentStatus: tournamentStatus)));
            },
            child: Container(
            color: isInProgress ? AppTheme.warning.withValues(alpha: 0.08) : (isNextToInput ? AppTheme.primaryColor.withValues(alpha: 0.06) : null),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.only(left: 14, top: 8, bottom: 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text("第$matchOrder試合", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isInProgress ? AppTheme.warning : (isNextToInput ? AppTheme.primaryColor : AppTheme.textSecondary))),
                    if (isInProgress) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppTheme.warning, borderRadius: BorderRadius.circular(4)),
                        child: const Text('入力中', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ] else if (isNextToInput) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppTheme.primaryColor, borderRadius: BorderRadius.circular(4)),
                        child: const Text('入力待ち', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ],
                  ]),
                  Row(children: [
                    Text("主: ", style: TextStyle(fontSize: 13, color: AppTheme.textHint)),
                    Text(m['refereeTeamName'] ?? '未定', style: TextStyle(fontSize: 13, color: _myTeamIds.contains(m['refereeTeamId'] ?? '') ? Colors.red : AppTheme.textHint, fontWeight: _myTeamIds.contains(m['refereeTeamId'] ?? '') ? FontWeight.bold : FontWeight.normal)),
                    Text(" / サブ: ", style: TextStyle(fontSize: 13, color: AppTheme.textHint)),
                    Text(m['subRefereeTeamName'] ?? 'ー', style: TextStyle(fontSize: 13, color: _myTeamIds.contains(m['subRefereeTeamId'] ?? '') ? Colors.red : AppTheme.textHint, fontWeight: _myTeamIds.contains(m['subRefereeTeamId'] ?? '') ? FontWeight.bold : FontWeight.normal)),
                  ]),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Expanded(flex: 3, child: Container(
                    child: Text(m['teamAName'] ?? '', style: TextStyle(fontSize: 16,
                      color: _myTeamIds.contains(m['teamAId'] ?? '') ? Colors.red : null,
                      fontWeight: _myTeamIds.contains(m['teamAId'] ?? '') || (status == 'completed' && result['winner'] == m['teamAId']) ? FontWeight.bold : FontWeight.normal),
                      textAlign: TextAlign.right))),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: isCompleted ? AppTheme.success.withValues(alpha:0.1) : (isInProgress ? AppTheme.warning.withValues(alpha:0.15) : Colors.grey[100]),
                      borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      isCompleted ? '${result['setsA'] ?? 0}-${result['setsB'] ?? 0}' : (isInProgress ? '$provSetsA-$provSetsB' : 'vs'),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                          color: isCompleted ? AppTheme.success : (isInProgress ? AppTheme.warning : AppTheme.textSecondary))),
                  ),
                  Expanded(flex: 3, child: Container(
                    child: Text(m['teamBName'] ?? '', style: TextStyle(fontSize: 16,
                      color: _myTeamIds.contains(m['teamBId'] ?? '') ? Colors.red : null,
                      fontWeight: _myTeamIds.contains(m['teamBId'] ?? '') || (status == 'completed' && result['winner'] == m['teamBId']) ? FontWeight.bold : FontWeight.normal)))),
                  if (isCompleted)
                    const Icon(Icons.check_circle, size: 16, color: AppTheme.success)
                  else if (isInProgress)
                    const Icon(Icons.edit_note, size: 18, color: AppTheme.warning)
                  else
                    Icon(Icons.play_circle_outline, size: 16, color: AppTheme.textHint),
                ]),
              ),
              Divider(height: 1, thickness: 1, color: Colors.grey[300]),
            ])),
          );
        }),
      ]),
    );
  }

  Widget _buildStandingsCard(String courtId, int courtNum, String roundId) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId)
          .collection('rounds').doc(roundId)
          .collection('standings').doc(courtId)
          .collection('teams').orderBy('matchPoints', descending: true).snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) return const SizedBox();
        final teams = snap.data!.docs;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey[200]!)),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.amber.withValues(alpha:0.1), borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
              child: Row(children: [
                const Icon(Icons.leaderboard, size: 16, color: Colors.amber),
                const SizedBox(width: 8),
                Text('${String.fromCharCode(64 + courtNum)}コート 順位表', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              ]),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(children: const [
                SizedBox(width: 24, child: Text('#', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
                Expanded(flex: 3, child: Text('チーム', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
                SizedBox(width: 40, child: Text('勝点', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
                SizedBox(width: 40, child: Text('得失', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
                SizedBox(width: 40, child: Text('総得', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
              ]),
            ),
            Divider(height: 1, color: Colors.grey[200]),
            ...teams.asMap().entries.map((e) {
              final i = e.key;
              final t = e.value.data() as Map<String, dynamic>;
              final isMyTeam = _myTeamIds.contains(t['teamId'] ?? '');
              return Container(
                color: isMyTeam ? Colors.red.withValues(alpha:0.08) : null,
                child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(children: [
                  SizedBox(width: 24, child: Text('${i + 1}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                      color: i == 0 ? Colors.amber : AppTheme.textPrimary))),
                  Expanded(flex: 3, child: Text(t['teamName'] ?? '', style: TextStyle(fontSize: 15, color: _myTeamIds.contains(t['teamId'] ?? '') ? Colors.red : null, fontWeight: _myTeamIds.contains(t['teamId'] ?? '') ? FontWeight.bold : FontWeight.normal), overflow: TextOverflow.ellipsis)),
                  SizedBox(width: 40, child: Text('${t['matchPoints'] ?? 0}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                  SizedBox(width: 40, child: Text('${t['pointDiff'] ?? 0}', style: TextStyle(fontSize: 13, color: (t['pointDiff'] ?? 0) >= 0 ? AppTheme.success : AppTheme.error), textAlign: TextAlign.center)),
                  SizedBox(width: 40, child: Text('${t['totalPoints'] ?? 0}', style: const TextStyle(fontSize: 13), textAlign: TextAlign.center)),
                ]),
              ),
              );
            }),
          ]),
        );
      },
    );
  }

  Widget _buildBracketCourtChips(String bracketId, List<MapEntry<String, int>> courts, Set<String> myCourts) {
    final filter = _selectedBracketCourtFilter.containsKey(bracketId) ? _selectedBracketCourtFilter[bracketId] : 'MY';
    final sortedCourts = List<MapEntry<String, int>>.from(courts)..sort((a, b) => a.value.compareTo(b.value));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: const Text('全て'),
                selected: filter == null,
                selectedColor: Colors.amber.withValues(alpha: 0.15),
                labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  color: filter == null ? Colors.amber[800] : AppTheme.textSecondary),
                side: BorderSide(color: filter == null ? Colors.amber : Colors.grey[300]!),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                showCheckmark: false,
                onSelected: (_) => setState(() { _selectedBracketCourtFilter[bracketId] = null; }),
              ),
            ),
            if (myCourts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: const Text('MY'),
                  selected: filter == 'MY',
                  selectedColor: AppTheme.accentColor.withValues(alpha: 0.15),
                  labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                    color: filter == 'MY' ? AppTheme.accentColor : AppTheme.accentColor.withValues(alpha: 0.7)),
                  side: BorderSide(color: filter == 'MY' ? AppTheme.accentColor : AppTheme.accentColor.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  showCheckmark: false,
                  onSelected: (_) => setState(() {
                    _selectedBracketCourtFilter[bracketId] = filter == 'MY' ? null : 'MY';
                  }),
                ),
              ),
            ...sortedCourts.map((court) {
              final courtId = court.key;
              final courtNum = court.value;
              final label = '${String.fromCharCode(64 + courtNum)}';
              final isSelected = filter == courtId;
              final isMyCourt = myCourts.contains(courtId);
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(label),
                    if (isMyCourt) ...[
                      const SizedBox(width: 3),
                      Icon(Icons.star, size: 12, color: isSelected ? Colors.amber[800] : AppTheme.accentColor),
                    ],
                  ]),
                  selected: isSelected,
                  selectedColor: Colors.amber.withValues(alpha: 0.15),
                  labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: isSelected ? Colors.amber[800] : AppTheme.textSecondary),
                  side: BorderSide(color: isSelected ? Colors.amber : Colors.grey[300]!),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  showCheckmark: false,
                  onSelected: (_) => setState(() {
                    _selectedBracketCourtFilter[bracketId] = isSelected ? null : courtId;
                  }),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildBracketSection(String bracketId, Map<String, dynamic> bData, bool isOrganizer, String tournamentStatus) {
    final rankRange = bData['rankRange'] as String? ?? '';
    final isMyLeague = _isMyBracket(bData);
    // 自分のリーグ以外はデフォルト折りたたみ（予選と同じ）
    final isCollapsed = _collapsedBrackets[bracketId] ?? (!isMyLeague);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // リーグヘッダー（タップで折りたたみ — 予選と同じ▶/▼スタイル）
      GestureDetector(
        onTap: () => setState(() => _collapsedBrackets[bracketId] = !isCollapsed),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            const Icon(Icons.emoji_events, size: 20, color: Colors.amber),
            const SizedBox(width: 8),
            Text(_toFullLeagueName(bData['bracketName'] as String? ?? '順位決定'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amber[800])),
            const SizedBox(width: 4),
            Icon(
              isCollapsed ? Icons.arrow_right : Icons.arrow_drop_down,
              color: Colors.amber[800],
              size: 28,
            ),
            if (isMyLeague) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(4)),
                child: const Text('MY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ],
            if (rankRange.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Text(rankRange, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber[800])),
              ),
            ],
          ]),
        ),
      ),
      if (!isCollapsed)
      StreamBuilder<QuerySnapshot>(
        stream: _firestore.collection('tournaments').doc(_tournamentId)
            .collection('brackets').doc(bracketId)
            .collection('matches').orderBy('matchNumber').snapshots(),
        builder: (context, matchSnap) {
          if (!matchSnap.hasData) return const SizedBox();
          final allMatches = matchSnap.data!.docs.toList();
          if (allMatches.isEmpty) return const SizedBox();

          final roundLabels = <String, String>{
            'qf': '準々決勝', 'sf_winner': '準決勝（勝者）', 'sf_loser': '準決勝（敗者）',
            'semi': '準決勝', 'final_1st': '決勝（1-2位）', 'final_3rd': '3位決定戦',
            'final_5th': '5位決定戦', 'final_7th': '7位決定戦', 'final': '決勝', 'round-robin': '総当たり',
          };

          // コート毎の試合番号を計算（時間順にソートしてから）
          const _roundTemporal = {
            'qf': 0, 'semi': 1, 'sf_winner': 2, 'sf_loser': 2,
            'round-robin': 4,
            'final_3rd': 5, 'final_7th': 5, 'final_1st': 6, 'final_5th': 6, 'final': 7,
          };
          final sortedForCourt = List<QueryDocumentSnapshot>.from(allMatches)..sort((a, b) {
            final aM = a.data() as Map<String, dynamic>;
            final bM = b.data() as Map<String, dynamic>;
            final aPri = _roundTemporal[aM['round'] as String? ?? ''] ?? 99;
            final bPri = _roundTemporal[bM['round'] as String? ?? ''] ?? 99;
            if (aPri != bPri) return aPri.compareTo(bPri);
            return ((aM['matchNumber'] as num?) ?? 0).compareTo((bM['matchNumber'] as num?) ?? 0);
          });
          final courtMatchCount = <String, int>{};
          final courtMatchOrder = <int, int>{}; // matchNumber -> コート内順番
          for (var mDoc in sortedForCourt) {
            final m = mDoc.data() as Map<String, dynamic>;
            final courtId = m['courtId'] as String? ?? 'no_court';
            final matchNum = (m['matchNumber'] as num?)?.toInt() ?? 0;
            courtMatchCount[courtId] = (courtMatchCount[courtId] ?? 0) + 1;
            courtMatchOrder[matchNum] = courtMatchCount[courtId]!;
          }

          // コート別にグループ化（時間順にソート済み）
          final courtMatches = <String, List<QueryDocumentSnapshot>>{};
          for (var mDoc in sortedForCourt) {
            final m = mDoc.data() as Map<String, dynamic>;
            final courtId = m['courtId'] as String? ?? 'no_court';
            courtMatches.putIfAbsent(courtId, () => []);
            courtMatches[courtId]!.add(mDoc);
          }
          final courtOrder = courtMatches.keys.toList()..sort();

          // コート情報を事前に構築
          final courtInfoList = courtOrder.map((courtId) {
            final matches = courtMatches[courtId]!;
            final firstMatch = matches.first.data() as Map<String, dynamic>;
            final courtNum = (firstMatch['courtNumber'] as num?)?.toInt();
            final courtLetter = courtNum != null ? String.fromCharCode(64 + courtNum) : courtId;
            return (courtId: courtId, matches: matches, letter: courtLetter, courtNum: courtNum ?? 0);
          }).toList();

          // 自分のチームが属するコートを特定
          final myBracketCourts = <String>{};
          for (var court in courtInfoList) {
            for (var mDoc in court.matches) {
              final m = mDoc.data() as Map<String, dynamic>;
              if (_myTeamIds.contains(m['teamAId'] ?? '') || _myTeamIds.contains(m['teamBId'] ?? '') ||
                  _myTeamIds.contains(m['refereeTeamId'] ?? '') || _myTeamIds.contains(m['subRefereeTeamId'] ?? '')) {
                myBracketCourts.add(court.courtId);
                break;
              }
            }
          }

          // コートチップ用データ
          final bracketCourtChipData = courtInfoList.map((c) => MapEntry(c.courtId, c.courtNum)).toList();
          final bracketCourtFilter = _selectedBracketCourtFilter[bracketId];
          final filteredCourtInfoList = bracketCourtFilter == 'MY'
              ? courtInfoList.where((c) => myBracketCourts.contains(c.courtId)).toList()
              : bracketCourtFilter != null
                  ? courtInfoList.where((c) => c.courtId == bracketCourtFilter).toList()
                  : courtInfoList;

          // 予選と同じスタイルの試合カードを構築
          Widget buildBracketMatchCard(QueryDocumentSnapshot mDoc, int idx, List<QueryDocumentSnapshot> courtMatchList) {
            final m = mDoc.data() as Map<String, dynamic>;
            final status = m['status'] ?? 'pending';
            final result = m['result'] as Map<String, dynamic>? ?? {};
            final matchNum = (m['matchNumber'] as num?)?.toInt() ?? 0;
            final matchOrder = courtMatchOrder[matchNum] ?? (idx + 1);
            final round = m['round'] as String? ?? '';
            final roundLabel = roundLabels[round] ?? '';
            final label = m['label'] as String? ?? '';
            final displayLabel = label.isNotEmpty ? label : (round.startsWith('final') ? roundLabel : '');

            final isReferee = _myTeamIds.contains(m['refereeTeamId'] ?? '') || _myTeamIds.contains(m['subRefereeTeamId'] ?? '');
            final isMyMatch = _myTeamIds.contains(m['teamAId'] ?? '') || _myTeamIds.contains(m['teamBId'] ?? '') || isReferee;
            final canInput = isOrganizer || isMyMatch;
            final isCompleted = status == 'completed';
            final isWaiting = status == 'waiting';
            final (hasInput, provSetsA, provSetsB) = _matchProgress(m);
            final isInProgress = !isCompleted && !isWaiting && hasInput;
            final prevDone = idx <= 0 || ((courtMatchList[idx - 1].data() as Map<String, dynamic>)['status'] == 'completed');
            final isNextToInput = !isCompleted && !isWaiting && !isInProgress && prevDone && isMyMatch;

            String teamADisplay = (m['teamAId'] ?? '').isEmpty ? _friendlyPlaceholder(m['teamAName'] ?? '') : (m['teamAName'] ?? '');
            String teamBDisplay = (m['teamBId'] ?? '').isEmpty ? _friendlyPlaceholder(m['teamBName'] ?? '') : (m['teamBName'] ?? '');
            final isMyTeamA = _myTeamIds.contains(m['teamAId'] ?? '');
            final isMyTeamB = _myTeamIds.contains(m['teamBId'] ?? '');
            final aWon = isCompleted && result['winner'] == m['teamAId'];
            final bWon = isCompleted && result['winner'] == m['teamBId'];

            return InkWell(
              onTap: () {
                // 終了した大会はスコアを閲覧のみ可能
                if (tournamentStatus == '終了') {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => ScoreInputScreen(
                    tournamentId: _tournamentId, matchId: mDoc.id, roundId: '', isBracket: true, bracketId: bracketId, isOrganizer: isOrganizer, tournamentStatus: tournamentStatus)));
                  return;
                }
                if (tournamentStatus != '開催中') {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("得点入力は大会が「開催中」の場合のみ可能です"), backgroundColor: AppTheme.warning));
                  return;
                }
                if (isWaiting) return;
                if (isCompleted && !isOrganizer) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("この試合は確定済みです"), backgroundColor: AppTheme.warning));
                  return;
                }
                if (!canInput) return;
                if (!prevDone) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("前の試合が完了してから入力してください"), backgroundColor: AppTheme.warning));
                  return;
                }
                Navigator.push(context, MaterialPageRoute(builder: (_) => ScoreInputScreen(
                  tournamentId: _tournamentId, matchId: mDoc.id, roundId: '', isBracket: true, bracketId: bracketId, isOrganizer: isOrganizer, tournamentStatus: tournamentStatus)));
              },
              child: Container(
                color: isInProgress ? AppTheme.warning.withValues(alpha: 0.08) : (isNextToInput ? Colors.amber.withValues(alpha: 0.06) : null),
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 14, top: 8, bottom: 2),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text("第$matchOrder試合", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isInProgress ? AppTheme.warning : (isNextToInput ? Colors.amber[700]! : AppTheme.textSecondary))),
                        if (displayLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                            child: Text(displayLabel, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber[800])),
                          ),
                        ],
                        if (isInProgress) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: AppTheme.warning, borderRadius: BorderRadius.circular(4)),
                            child: const Text('入力中', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                          ),
                        ] else if (isNextToInput) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(4)),
                            child: const Text('入力待ち', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                          ),
                        ],
                      ]),
                      Row(children: [
                        Text("主: ", style: TextStyle(fontSize: 13, color: AppTheme.textHint)),
                        Text((m['refereeTeamName'] ?? '').toString().isNotEmpty ? m['refereeTeamName'] : '未定', style: TextStyle(fontSize: 13,
                          color: _myTeamIds.contains(m['refereeTeamId'] ?? '') ? Colors.red : AppTheme.textHint,
                          fontWeight: _myTeamIds.contains(m['refereeTeamId'] ?? '') ? FontWeight.bold : FontWeight.normal)),
                        Text(" / サブ: ", style: TextStyle(fontSize: 13, color: AppTheme.textHint)),
                        Text((m['subRefereeTeamName'] ?? '').toString().isNotEmpty ? m['subRefereeTeamName'] : 'ー', style: TextStyle(fontSize: 13,
                          color: _myTeamIds.contains(m['subRefereeTeamId'] ?? '') ? Colors.red : AppTheme.textHint,
                          fontWeight: _myTeamIds.contains(m['subRefereeTeamId'] ?? '') ? FontWeight.bold : FontWeight.normal)),
                      ]),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text(teamADisplay,
                        style: TextStyle(fontSize: 16,
                          color: isMyTeamA ? Colors.red : null,
                          fontWeight: (isMyTeamA || aWon) ? FontWeight.bold : FontWeight.normal),
                        textAlign: TextAlign.right)),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: isCompleted ? AppTheme.success.withValues(alpha: 0.1) : (isInProgress ? AppTheme.warning.withValues(alpha: 0.15) : Colors.grey[100]),
                          borderRadius: BorderRadius.circular(6)),
                        child: Text(
                          isCompleted ? '${result['setsA'] ?? 0}-${result['setsB'] ?? 0}' : (isInProgress ? '$provSetsA-$provSetsB' : (isWaiting ? '–' : 'vs')),
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                            color: isCompleted ? AppTheme.success : (isInProgress ? AppTheme.warning : AppTheme.textSecondary))),
                      ),
                      Expanded(flex: 3, child: Text(teamBDisplay,
                        style: TextStyle(fontSize: 16,
                          color: isMyTeamB ? Colors.red : null,
                          fontWeight: (isMyTeamB || bWon) ? FontWeight.bold : FontWeight.normal))),
                      if (isCompleted)
                        const Icon(Icons.check_circle, size: 16, color: AppTheme.success)
                      else if (isInProgress)
                        const Icon(Icons.edit_note, size: 18, color: AppTheme.warning)
                      else
                        Icon(Icons.play_circle_outline, size: 16, color: AppTheme.textHint),
                    ]),
                  ),
                  Divider(height: 1, thickness: 1, color: Colors.grey[300]),
                ]),
              ),
            );
          }

          return Column(children: [
            _buildBracketCourtChips(bracketId, bracketCourtChipData, myBracketCourts),
            ...filteredCourtInfoList.map((court) {
            final isMyCourt = myBracketCourts.contains(court.courtId);

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isMyCourt ? Colors.amber.withValues(alpha: 0.5) : Colors.grey[200]!, width: isMyCourt ? 1.5 : 1),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // コートヘッダー（予選と同じスタイル）
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMyCourt ? Colors.amber.withValues(alpha: 0.06) : Colors.grey[50],
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: Row(children: [
                    Icon(Icons.emoji_events, size: 18, color: Colors.amber[700]),
                    const SizedBox(width: 8),
                    Text('${court.letter}コート', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    if (isMyCourt) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(4)),
                        child: const Text('MY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ],
                    const Spacer(),
                    Text('${court.matches.length}試合', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ]),
                ),
                // 各試合（予選と同じレイアウト）
                ...court.matches.asMap().entries.map((entry) =>
                  buildBracketMatchCard(entry.value, entry.key, court.matches)),
              ]),
            );
          }).toList(),
          ]);
        },
      ),
      const SizedBox(height: 8),
    ]);
  }

  Future<void> _generateMatches(int roundNumber) async {
    // 予選1: ランダム、予選2: なるべく対戦していないチームと当たるように
    final assignmentMode = roundNumber >= 2 ? 'random' : 'random';

    try {
      // ローディング表示
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));

      final preview = await MatchGenerator().previewPreliminary(
        tournamentId: _tournamentId, roundNumber: roundNumber, assignmentMode: assignmentMode);

      if (!mounted) return;
      Navigator.pop(context); // close loading

      // プレビューモーダル表示
      final confirmed = await _showPreliminaryPreviewModal(roundNumber, preview);
      if (confirmed != true || !mounted) return;

      // 反映
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      await MatchGenerator().savePreliminaryPreview(
        tournamentId: _tournamentId, roundNumber: roundNumber, preview: preview);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('予選$roundNumber の対戦表を反映しました'), backgroundColor: AppTheme.success));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  /// 予選対戦表のプレビューモーダル
  Future<bool?> _showPreliminaryPreviewModal(int roundNumber, Map<String, dynamic> preview) {
    final courts = (preview['courts'] as List).cast<List<Map<String, dynamic>>>();
    final matches = (preview['matches'] as List).cast<Map<String, dynamic>>();

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(ctx).size.height * 0.85,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(children: [
            // ヘッダー
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))],
              ),
              child: Column(children: [
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 12),
                Row(children: [
                  Icon(Icons.preview, color: AppTheme.primaryColor, size: 24),
                  const SizedBox(width: 8),
                  Expanded(child: Text('予選$roundNumber 対戦表プレビュー',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
                ]),
                const SizedBox(height: 4),
                Text(roundNumber == 1
                    ? 'ランダムに割り振られた対戦表です。内容を確認してください。'
                    : '予選1で対戦していないチームとなるべく当たるように割り振られています。',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ]),
            ),
            // コート別プレビュー
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
                itemCount: courts.length,
                itemBuilder: (ctx, courtIdx) {
                  final courtTeams = courts[courtIdx];
                  final courtId = 'court_${courtIdx + 1}';
                  final courtLabel = String.fromCharCode(65 + courtIdx); // A, B, C...
                  final courtMatches = matches.where((m) => m['courtId'] == courtId).toList();

                  return Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[200]!),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // コートヘッダー
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.08),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                        ),
                        child: Row(children: [
                          Icon(Icons.sports_volleyball, size: 18, color: AppTheme.primaryColor),
                          const SizedBox(width: 8),
                          Text('$courtLabelコート', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                          const Spacer(),
                          Text('${courtTeams.length}チーム', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                        ]),
                      ),
                      // チーム一覧
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: courtTeams.map((t) => Chip(
                            label: Text(t['teamName'] ?? '', style: const TextStyle(fontSize: 13)),
                            backgroundColor: Colors.grey[100],
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          )).toList(),
                        ),
                      ),
                      const Divider(height: 1),
                      // 試合一覧
                      ...courtMatches.map((m) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: Row(children: [
                          SizedBox(width: 24, child: Text('${m['matchOrder']}', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.w500))),
                          Expanded(flex: 3, child: Text(m['teamAName'] ?? '', style: const TextStyle(fontSize: 14), textAlign: TextAlign.right)),
                          const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('vs', style: TextStyle(fontSize: 12, color: Colors.grey))),
                          Expanded(flex: 3, child: Text(m['teamBName'] ?? '', style: const TextStyle(fontSize: 14))),
                          const SizedBox(width: 8),
                          if ((m['refereeTeamName'] ?? '').isNotEmpty)
                            Expanded(flex: 3, child: Text(
                              '主: ${m['refereeTeamName']}${(m['subRefereeTeamName'] ?? '').isNotEmpty ? ' / サブ: ${m['subRefereeTeamName']}' : ''}',
                              style: TextStyle(fontSize: 11, color: AppTheme.textHint),
                              overflow: TextOverflow.ellipsis,
                            )),
                        ]),
                      )),
                      const SizedBox(height: 8),
                    ]),
                  );
                },
              ),
            ),
            // フッターボタン
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, -2))],
              ),
              child: Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('キャンセル'),
                )),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('この内容で反映', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
              ]),
            ),
          ]),
        );
      },
    );
  }

  /// 確認テキスト入力付きダイアログ（誤操作防止）
  Future<bool> _showTypedConfirmDialog({
    required String title,
    required String description,
    required String confirmWord,
  }) async {
    final result = await showDialog<bool>(context: context, builder: (ctx) {
      final controller = TextEditingController();
      return StatefulBuilder(builder: (ctx, setState) {
        final match = controller.text == confirmWord;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: AppTheme.error, size: 24),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 17))),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(description, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 16),
            Text('確認のため「$confirmWord」と入力してください', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: confirmWord,
                hintStyle: TextStyle(color: Colors.grey[300]),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: match ? () => Navigator.pop(ctx, true) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                disabledBackgroundColor: Colors.grey[300],
              ),
              child: const Text('リセット'),
            ),
          ],
        );
      });
    });
    return result == true;
  }

  /// リセットメニューを表示
  void _showResetMenu() async {
    // 現在のデータ状態を取得
    final roundsSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('rounds').get();
    final bracketsSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('brackets').get();
    final roundNumbers = roundsSnap.docs.map((d) => (d.data())['roundNumber'] ?? 1).toSet();
    final hasRound1 = roundNumbers.contains(1);
    final hasRound2 = roundNumbers.contains(2);
    final hasBrackets = bracketsSnap.docs.isNotEmpty;

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.refresh, color: AppTheme.error, size: 22),
              SizedBox(width: 8),
              Text('リセット', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            Text('リセットする範囲を選択してください', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const Divider(height: 24),
            if (hasRound1)
              _resetOptionTile(ctx, Icons.looks_one_outlined, '予選1をリセット', '予選1の対戦表・スコア・順位表を削除', () {
                Navigator.pop(ctx);
                _resetRound(1, rollbackStatus: '大会準備中');
              }),
            if (hasRound2)
              _resetOptionTile(ctx, Icons.looks_two_outlined, '予選2をリセット', '予選2の対戦表・スコア・順位表を削除', () {
                Navigator.pop(ctx);
                _resetRound(2, rollbackStatus: '予選1完了');
              }),
            if (hasBrackets)
              _resetOptionTile(ctx, Icons.emoji_events_outlined, '順位決定戦をリセット', '順位決定戦の対戦表・スコアを削除', () {
                Navigator.pop(ctx);
                _resetBrackets();
              }),
            const Divider(height: 16),
            _resetOptionTile(ctx, Icons.delete_forever, '全てリセット', '全ての対戦表・スコア・順位表を削除', () {
              Navigator.pop(ctx);
              _resetAll();
            }, isDestructive: true),
          ]),
        ),
      ),
    );
  }

  Widget _resetOptionTile(BuildContext ctx, IconData icon, String title, String subtitle, VoidCallback onTap, {bool isDestructive = false}) {
    final c = isDestructive ? AppTheme.error : AppTheme.textPrimary;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: (isDestructive ? AppTheme.error : AppTheme.info).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: isDestructive ? AppTheme.error : AppTheme.info),
      ),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      trailing: Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
      onTap: onTap,
    );
  }

  /// 予選ラウンド単体リセット
  Future<void> _resetRound(int roundNumber, {required String rollbackStatus}) async {
    final confirmed = await _showTypedConfirmDialog(
      title: '予選${roundNumber}をリセット',
      description: '予選${roundNumber}の対戦表・スコア・順位表を削除します。\nこの操作は取り消せません。',
      confirmWord: 'リセット',
    );
    if (!confirmed) return;
    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      final roundRef = _firestore.collection('tournaments').doc(_tournamentId).collection('rounds').doc('round_$roundNumber');
      final roundDoc = await roundRef.get();
      if (roundDoc.exists) {
        final matches = await roundRef.collection('matches').get();
        for (var m in matches.docs) { await m.reference.delete(); }
        final standings = await roundRef.collection('standings').get();
        for (var s in standings.docs) {
          final teams = await s.reference.collection('teams').get();
          for (var t in teams.docs) { await t.reference.delete(); }
          await s.reference.delete();
        }
        await roundRef.delete();
      }
      // round2リセット時はbracketsも削除
      if (roundNumber == 2) {
        final brackets = await _firestore.collection('tournaments').doc(_tournamentId).collection('brackets').get();
        for (var b in brackets.docs) {
          final matches = await b.reference.collection('matches').get();
          for (var m in matches.docs) { await m.reference.delete(); }
          await b.reference.delete();
        }
      }
      await _firestore.collection('tournaments').doc(_tournamentId).update({'status': rollbackStatus});
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('予選${roundNumber}をリセットしました'), backgroundColor: AppTheme.success)); }
    } catch (e) {
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error)); }
    }
  }

  /// 順位決定戦リセット
  Future<void> _resetBrackets() async {
    final confirmed = await _showTypedConfirmDialog(
      title: '順位決定戦をリセット',
      description: '順位決定戦の対戦表・スコアを削除します。\nこの操作は取り消せません。',
      confirmWord: 'リセット',
    );
    if (!confirmed) return;
    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      final brackets = await _firestore.collection('tournaments').doc(_tournamentId).collection('brackets').get();
      for (var b in brackets.docs) {
        final matches = await b.reference.collection('matches').get();
        for (var m in matches.docs) { await m.reference.delete(); }
        await b.reference.delete();
      }
      // 予選2がある場合は「予選2完了」、そうでなければ「予選1完了」に戻す
      final roundsSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('rounds').get();
      final roundNumbers = roundsSnap.docs.map((d) => (d.data())['roundNumber'] ?? 1).toSet();
      final newStatus = roundNumbers.contains(2) ? '予選2完了' : '予選1完了';
      await _firestore.collection('tournaments').doc(_tournamentId).update({'status': newStatus});
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('順位決定戦をリセットしました'), backgroundColor: AppTheme.success)); }
    } catch (e) {
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error)); }
    }
  }

  /// 全リセット
  Future<void> _resetAll() async {
    final confirmed = await _showTypedConfirmDialog(
      title: '全てリセット',
      description: '全ての対戦表・スコア・順位表を削除します。\nこの操作は取り消せません。',
      confirmWord: '全てリセット',
    );
    if (!confirmed) return;
    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      final rounds = await _firestore.collection('tournaments').doc(_tournamentId).collection('rounds').get();
      for (var round in rounds.docs) {
        final matches = await round.reference.collection('matches').get();
        for (var m in matches.docs) { await m.reference.delete(); }
        final standings = await round.reference.collection('standings').get();
        for (var s in standings.docs) {
          final teams = await s.reference.collection('teams').get();
          for (var t in teams.docs) { await t.reference.delete(); }
          await s.reference.delete();
        }
        await round.reference.delete();
      }
      final brackets = await _firestore.collection('tournaments').doc(_tournamentId).collection('brackets').get();
      for (var b in brackets.docs) {
        final matches = await b.reference.collection('matches').get();
        for (var m in matches.docs) { await m.reference.delete(); }
        await b.reference.delete();
      }
      await _firestore.collection('tournaments').doc(_tournamentId).update({'status': '募集中'});
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('全てリセットしました'), backgroundColor: AppTheme.success)); }
    } catch (e) {
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error)); }
    }
  }
  Future<void> _deleteEntryTeams() async {
    // エントリー済みチームを取得
    final entriesSnap = await _firestore.collection('tournaments').doc(_tournamentId).collection('entries').get();
    if (entriesSnap.docs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エントリーチームがありません'), backgroundColor: AppTheme.warning),
        );
      }
      return;
    }

    final entries = entriesSnap.docs.map((d) {
      final data = d.data();
      return {'docId': d.id, 'teamName': data['teamName'] ?? '', 'leaderName': data['leaderName'] ?? '', 'memberCount': data['memberCount'] ?? 0};
    }).toList();

    if (!mounted) return;
    final selectedIds = <String>{};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            const Icon(Icons.delete_sweep, color: AppTheme.error),
            const SizedBox(width: 8),
            const Text('チームを削除', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ]),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(children: [
              Row(children: [
                Text('${selectedIds.length}件選択中', style: TextStyle(fontSize: 13, color: selectedIds.isNotEmpty ? AppTheme.error : AppTheme.textSecondary, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () => setDialogState(() {
                    if (selectedIds.length == entries.length) {
                      selectedIds.clear();
                    } else {
                      selectedIds.addAll(entries.map((e) => e['docId'] as String));
                    }
                  }),
                  child: Text(selectedIds.length == entries.length ? '全解除' : '全選択', style: const TextStyle(fontSize: 13)),
                ),
              ]),
              const SizedBox(height: 4),
              Expanded(
                child: ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (ctx, i) {
                    final e = entries[i];
                    final docId = e['docId'] as String;
                    final isSelected = selectedIds.contains(docId);
                    return CheckboxListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      value: isSelected,
                      activeColor: AppTheme.error,
                      onChanged: (v) => setDialogState(() {
                        if (v == true) { selectedIds.add(docId); } else { selectedIds.remove(docId); }
                      }),
                      secondary: CircleAvatar(
                        radius: 16,
                        backgroundColor: isSelected ? AppTheme.error.withValues(alpha: 0.15) : AppTheme.primaryColor.withValues(alpha: 0.1),
                        child: Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isSelected ? AppTheme.error : AppTheme.primaryColor)),
                      ),
                      title: Text(e['teamName'] as String, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isSelected ? AppTheme.error : null)),
                      subtitle: Text('キャプテン: ${e['leaderName']} / ${e['memberCount']}人', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: selectedIds.isEmpty ? null : () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
              child: Text('${selectedIds.length}件削除する'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || selectedIds.isEmpty) return;

    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      final batch = _firestore.batch();
      for (final docId in selectedIds) {
        batch.delete(_firestore.collection('tournaments').doc(_tournamentId).collection('entries').doc(docId));
      }
      // currentTeamsはCloud Function (onEntryDeleted) で自動更新
      await batch.commit();
      await _loadMyTeams();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${selectedIds.length}チームを削除しました'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _generateFinals() async {
    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));

      final preview = await MatchGenerator().previewFinals(tournamentId: _tournamentId);

      if (!mounted) return;
      Navigator.pop(context); // close loading

      // プレビューモーダル表示
      final confirmed = await _showFinalsPreviewModal(preview);
      if (confirmed != true || !mounted) return;

      // 反映
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      await MatchGenerator().saveFinalsPreview(tournamentId: _tournamentId, preview: preview);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('順位決定戦を反映しました'), backgroundColor: AppTheme.success));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  Future<void> _updateBracketCourtsAndReferees() async {
    try {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));
      await MatchGenerator().updateBracketCourtsAndReferees(_tournamentId);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('コート・審判を更新しました'), backgroundColor: AppTheme.success));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('エラー: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  /// 順位決定戦のプレビューモーダル
  Future<bool?> _showFinalsPreviewModal(Map<String, dynamic> preview) {
    final brackets = (preview['brackets'] as List).cast<Map<String, dynamic>>();

    // 同順位チームが存在するか検出
    bool hasTiedTeams = false;
    for (final bracket in brackets) {
      final teams = (bracket['teams'] as List).cast<Map<String, dynamic>>();
      if (teams.any((t) => t['isTied'] == true)) {
        hasTiedTeams = true;
        break;
      }
    }

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        // null = 未選択, 'shuffle' = 抽選, 'manual' = 手動
        String? tieResolutionMode;
        return StatefulBuilder(builder: (ctx, setModalState) {

          // 同順位チームの移動処理（手動モード用）
          void moveTeam(int fromBracketIdx, int teamIdx, int toBracketIdx) {
            final fromTeams = (brackets[fromBracketIdx]['teams'] as List).cast<Map<String, dynamic>>();
            final toTeams = (brackets[toBracketIdx]['teams'] as List).cast<Map<String, dynamic>>();
            final team = fromTeams.removeAt(teamIdx);
            if (toBracketIdx < fromBracketIdx) {
              toTeams.add(team);
            } else {
              toTeams.insert(0, team);
            }
            brackets[fromBracketIdx]['teamCount'] = fromTeams.length;
            brackets[toBracketIdx]['teamCount'] = toTeams.length;
            setModalState(() {});
          }

          // 抽選：同順位チームをシャッフルして均等に再配置
          void shuffleTiedTeams() {
            final tiedTeams = <Map<String, dynamic>>[];
            final tiedBracketIndices = <int>{};
            for (int b = 0; b < brackets.length; b++) {
              final teams = (brackets[b]['teams'] as List).cast<Map<String, dynamic>>();
              final tied = teams.where((t) => t['isTied'] == true).toList();
              if (tied.isNotEmpty) {
                tiedTeams.addAll(tied);
                tiedBracketIndices.add(b);
                teams.removeWhere((t) => t['isTied'] == true);
              }
            }
            if (tiedTeams.isEmpty) return;
            tiedTeams.shuffle();
            final targetBrackets = tiedBracketIndices.toList()..sort();
            int ti = 0;
            for (final team in tiedTeams) {
              final bIdx = targetBrackets[ti % targetBrackets.length];
              (brackets[bIdx]['teams'] as List).add(team);
              ti++;
            }
            for (final bIdx in targetBrackets) {
              brackets[bIdx]['teamCount'] = (brackets[bIdx]['teams'] as List).length;
            }
            setModalState(() {});
          }

          return Container(
            height: MediaQuery.of(ctx).size.height * 0.85,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(children: [
              // ヘッダー
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))],
                ),
                child: Column(children: [
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 12),
                  Row(children: [
                    Icon(Icons.emoji_events, color: Colors.amber[700], size: 24),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('順位決定戦プレビュー',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
                  ]),
                  const SizedBox(height: 4),
                  Text('予選の総合順位をもとにリーグ分けされています。内容を確認してください。',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                ]),
              ),
              // 同順位チーム振り分け選択
              if (hasTiedTeams)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange[800]),
                      const SizedBox(width: 6),
                      Expanded(child: Text('同順位のチームがリーグ境界にいます',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.orange[900]))),
                    ]),
                    const SizedBox(height: 6),
                    Text('オレンジ色のチームは同スコアです。振り分け方法を選んでください。',
                        style: TextStyle(fontSize: 12, color: Colors.orange[800])),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: _TieOptionButton(
                        icon: Icons.shuffle,
                        label: '抽選',
                        description: 'ランダムに振り分け',
                        selected: tieResolutionMode == 'shuffle',
                        onTap: () {
                          tieResolutionMode = 'shuffle';
                          shuffleTiedTeams();
                        },
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: _TieOptionButton(
                        icon: Icons.touch_app,
                        label: '手動',
                        description: 'チームをタップして移動',
                        selected: tieResolutionMode == 'manual',
                        onTap: () {
                          tieResolutionMode = 'manual';
                          setModalState(() {});
                        },
                      )),
                    ]),
                    if (tieResolutionMode == 'shuffle')
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: shuffleTiedTeams,
                            icon: const Icon(Icons.refresh, size: 14),
                            label: const Text('もう一度抽選する', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.orange[800],
                              side: BorderSide(color: Colors.orange.withValues(alpha: 0.4)),
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              // リーグ別プレビュー
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
                  itemCount: brackets.length,
                  itemBuilder: (ctx, idx) {
                    final bracket = brackets[idx];
                    final teams = (bracket['teams'] as List).cast<Map<String, dynamic>>();
                    final bracketName = bracket['bracketName'] ?? '';
                    final rankRange = bracket['rankRange'] ?? '';
                    final teamCount = (bracket['teamCount'] as num?)?.toInt() ?? teams.length;

                    String formatLabel;
                    if (teamCount >= 8) {
                      formatLabel = 'トーナメント（全順位決定）';
                    } else if (teamCount >= 4) {
                      formatLabel = 'トーナメント（準決勝→決勝）';
                    } else if (teamCount == 3) {
                      formatLabel = 'トーナメント（1位シード）';
                    } else if (teamCount == 2) {
                      formatLabel = '決勝戦';
                    } else {
                      formatLabel = '';
                    }

                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // リーグヘッダー
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.08),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                          ),
                          child: Row(children: [
                            Icon(Icons.emoji_events, size: 18, color: Colors.amber[700]),
                            const SizedBox(width: 8),
                            Text(bracketName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.amber[800])),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                              child: Text('${teams.length}チーム', style: TextStyle(fontSize: 12, color: Colors.amber[800])),
                            ),
                            const Spacer(),
                            Text(formatLabel, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                          ]),
                        ),
                        // チーム一覧
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: teams.asMap().entries.map((e) {
                              final teamIdx = e.key;
                              final team = e.value;
                              final isTied = team['isTied'] == true;
                              final canMove = isTied && tieResolutionMode == 'manual';
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: InkWell(
                                  onTap: canMove ? () {
                                    // 移動先リーグの選択ダイアログ
                                    final otherBrackets = <int>[];
                                    for (int b = 0; b < brackets.length; b++) {
                                      if (b != idx) otherBrackets.add(b);
                                    }
                                    if (otherBrackets.isEmpty) return;
                                    showDialog(
                                      context: ctx,
                                      builder: (dCtx) => SimpleDialog(
                                        title: Text('${team['teamName']} の移動先', style: const TextStyle(fontSize: 16)),
                                        children: otherBrackets.map((bIdx) {
                                          return SimpleDialogOption(
                                            onPressed: () {
                                              Navigator.pop(dCtx);
                                              moveTeam(idx, teamIdx, bIdx);
                                            },
                                            child: Row(children: [
                                              Icon(bIdx < idx ? Icons.arrow_upward : Icons.arrow_downward,
                                                  size: 16, color: bIdx < idx ? AppTheme.success : AppTheme.info),
                                              const SizedBox(width: 8),
                                              Text(brackets[bIdx]['bracketName'] ?? ''),
                                            ]),
                                          );
                                        }).toList(),
                                      ),
                                    );
                                  } : null,
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                    decoration: isTied ? BoxDecoration(
                                      color: Colors.orange.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: canMove ? Colors.orange.withValues(alpha: 0.5) : Colors.orange.withValues(alpha: 0.3)),
                                    ) : null,
                                    child: Row(children: [
                                      SizedBox(width: 28, child: Text('${teamIdx + 1}.', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
                                      Expanded(child: Text(team['teamName'] ?? '', style: TextStyle(fontSize: 14,
                                          color: isTied ? Colors.orange[900] : null,
                                          fontWeight: isTied ? FontWeight.w600 : FontWeight.normal))),
                                      if (canMove)
                                        Icon(Icons.swap_vert, size: 16, color: Colors.orange[400]),
                                    ]),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ]),
                    );
                  },
                ),
              ),
              // フッターボタン
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, -2))],
                ),
                child: Row(children: [
                  Expanded(child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('キャンセル'),
                  )),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(ctx, true),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('この内容で反映', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber[700], foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  )),
                ]),
              ),
            ]),
          );
        });
      },
    );
  }
  // キャプテンを先頭にしたメンバー名の一覧（主催者向けのチームカード表示用）
  List<String> _orderedMemberNames(Map<String, dynamic> memberNames, String leaderName) {
    final names = memberNames.values.map((v) => v?.toString() ?? '').where((n) => n.isNotEmpty).toList();
    final i = names.indexOf(leaderName);
    if (i > 0) names.insert(0, names.removeAt(i));
    return names;
  }

  void _showMemberList(String teamName, Map<String, dynamic> memberNames, String leaderName) {
    final members = memberNames.entries.toList();
    // leaderNameと一致するメンバーを先頭に並べ替え
    members.sort((a, b) {
      final aIsLeader = a.value?.toString() == leaderName;
      final bIsLeader = b.value?.toString() == leaderName;
      if (aIsLeader && !bIsLeader) return -1;
      if (!aIsLeader && bIsLeader) return 1;
      return 0;
    });

    // メンバーのアバターURLを取得
    final memberAvatars = <String, String>{};
    Future<void> loadAvatars() async {
      for (final entry in members) {
        final uid = entry.key;
        final userDoc = await _firestore.collection('users').doc(uid).get();
        if (userDoc.exists) {
          memberAvatars[uid] = (userDoc.data()?['avatarUrl'] ?? '').toString();
        }
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => FutureBuilder(
        future: loadAvatars(),
        builder: (ctx, snapshot) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Text(teamName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${members.length}人のメンバー', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 16),
              ...members.asMap().entries.map((entry) {
                final uid = entry.value.key;
                final name = entry.value.value?.toString() ?? '名前なし';
                final isFirst = entry.key == 0;
                final avatarUrl = memberAvatars[uid] ?? '';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: avatarUrl.isNotEmpty
                      ? CircleAvatar(
                          radius: 20,
                          backgroundImage: NetworkImage(avatarUrl),
                          backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                        )
                      : CircleAvatar(
                          radius: 20,
                          backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                          child: Text(name.isNotEmpty ? name[0] : '?',
                              style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold)),
                        ),
                  title: Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: isFirst ? Text('キャプテン', style: TextStyle(fontSize: 12, color: AppTheme.accentColor)) : null,
                  trailing: GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => UserProfileScreen(userId: uid),
                      ));
                    },
                    child: Icon(Icons.chevron_right, color: AppTheme.textHint),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => UserProfileScreen(userId: uid),
                    ));
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  // 主催者・編集者向け：承認待ちドラフト（仮エントリー）の一覧。
  // entryDrafts は招待対象者以外には表示されないため、主催者からは
  // どのチームが承認待ちで止まっているかが全く見えなかった。
  Widget _buildOrganizerPendingDraftsSection() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId).collection('entryDrafts').snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.hourglass_top, size: 16, color: AppTheme.accentColor),
                const SizedBox(width: 6),
                Text('承認待ち ${docs.length}チーム（主催者のみ表示）',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
              ]),
              const SizedBox(height: 8),
              ...docs.map((d) {
                final data = d.data() as Map<String, dynamic>;
                final teamName = (data['teamName'] ?? '').toString();
                final leaderName = (data['leaderName'] ?? '').toString();
                final isMemberAdd = data['type'] == 'memberAdd';
                final invited = List<String>.from((data['invitedUids'] as List<dynamic>?) ?? []);
                final approvals = Map<String, dynamic>.from(data['approvals'] as Map? ?? {});
                // 辞退した人は分母から除外する（辞退しても残りの有効メンバーだけで自動成立するため）
                final activeCount = invited.where((u) => approvals[u] != 'declined').length;
                final approvedCount = invited.where((u) => approvals[u] == 'approved').length;
                return GestureDetector(
                  onTap: () => _showPendingDraftDetail(d.id, data),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.2)),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(isMemberAdd ? '$teamName（追加メンバー）' : teamName,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text('キャプテン: $leaderName', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        ]),
                      ),
                      Text('承認 $approvedCount/$activeCount',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 18, color: AppTheme.textHint),
                    ]),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _showPendingDraftDetail(String draftId, Map<String, dynamic> data) {
    final teamName = (data['teamName'] ?? '').toString();
    final leaderName = (data['leaderName'] ?? '').toString();
    final isMemberAdd = data['type'] == 'memberAdd';
    final invited = List<String>.from((data['invitedUids'] as List<dynamic>?) ?? []);
    final approvals = Map<String, dynamic>.from(data['approvals'] as Map? ?? {});
    final memberNames = Map<String, dynamic>.from(data['memberNames'] as Map? ?? {});

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ConstrainedBox(
        // 画面の6割以上の高さで表示（人数が多ければ最大9割までスクロール）
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(ctx).size.height * 0.6,
          maxHeight: MediaQuery.of(ctx).size.height * 0.9,
        ),
        child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 32 + MediaQuery.of(ctx).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Text(isMemberAdd ? '$teamName（追加メンバー承認待ち）' : teamName,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('キャプテン: $leaderName', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            ...invited.map((u) {
              final nm = (memberNames[u] ?? '?').toString();
              final st = (approvals[u] ?? 'pending').toString();
              final label = st == 'approved' ? '承認済み' : st == 'declined' ? '辞退' : '承認待ち';
              final c = st == 'approved'
                  ? AppTheme.success
                  : st == 'declined'
                      ? AppTheme.error
                      : AppTheme.textHint;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => UserProfileScreen(userId: u))),
                      child: Text(nm,
                          style: const TextStyle(fontSize: 14, decoration: TextDecoration.underline, decorationColor: AppTheme.textHint)),
                    ),
                  ),
                  Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c)),
                  if (st == 'pending') ...[
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _resendEntryInvite(draftId, u, nm);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.notifications_active_outlined, size: 16, color: AppTheme.accentColor),
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _adminApproveEntryDraftMember(draftId, u, nm);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.verified_outlined, size: 16, color: AppTheme.primaryColor),
                      ),
                    ),
                  ],
                ]),
              );
            }),
            const SizedBox(height: 16),
            // 誤タップ防止: 目立たない小さな文字リンク＋確認ダイアログ
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _cancelEntryDraft(draftId, teamName: teamName);
                },
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
                child: const Text('招待を取り消す', style: TextStyle(fontSize: 12, color: AppTheme.textHint)),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildTeamsTab() {
    if (_tournamentId.isEmpty) return const Center(child: Text('大会IDが見つかりません'));
    final canManage = _canManageTournament(widget.tournament);

    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId).collection('entries').snapshots(),
      builder: (context, entriesSnap) {
        if (!entriesSnap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        final entries = entriesSnap.data?.docs ?? [];

        if (entries.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (canManage) _buildOrganizerPendingDraftsSection(),
              Padding(
                padding: const EdgeInsets.only(top: 60),
                child: Column(children: [
                  Icon(Icons.groups_outlined, size: 64, color: AppTheme.textHint),
                  const SizedBox(height: 16),
                  const Text('まだエントリーはありません', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                ]),
              ),
            ],
          );
        }

        // チェックイン状況をリアルタイム取得
        return StreamBuilder<QuerySnapshot>(
          stream: _firestore.collection('tournaments').doc(_tournamentId).collection('checkIns').snapshots(),
          builder: (context, checkInSnap) {
            final checkedInTeamIds = <String>{};
            if (checkInSnap.hasData) {
              for (final doc in checkInSnap.data!.docs) {
                checkedInTeamIds.add((doc.data() as Map<String, dynamic>)['teamId'] ?? '');
              }
            }
            final checkedCount = entries.where((e) => checkedInTeamIds.contains((e.data() as Map<String, dynamic>)['teamId'])).length;

            // 自分のチームを先頭にソート
            final sortedEntries = List<QueryDocumentSnapshot>.from(entries);
            sortedEntries.sort((a, b) {
              final aData = a.data() as Map<String, dynamic>;
              final bData = b.data() as Map<String, dynamic>;
              final aIsMyTeam = _myTeamIds.contains(aData['teamId'] ?? '');
              final bIsMyTeam = _myTeamIds.contains(bData['teamId'] ?? '');
              if (aIsMyTeam && !bIsMyTeam) return -1;
              if (!aIsMyTeam && bIsMyTeam) return 1;
              return 0;
            });

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (canManage) _buildOrganizerPendingDraftsSection(),
                // ヘッダー: エントリー数 + 受付状況
                Row(children: [
                  Text('エントリー済み ${entries.length}チーム',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                  const Spacer(),
                  if (checkedInTeamIds.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: checkedCount == entries.length ? AppTheme.success.withValues(alpha: 0.1) : AppTheme.primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.how_to_reg, size: 14,
                          color: checkedCount == entries.length ? AppTheme.success : AppTheme.primaryColor),
                        const SizedBox(width: 4),
                        Text('$checkedCount/${entries.length}',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                            color: checkedCount == entries.length ? AppTheme.success : AppTheme.primaryColor)),
                      ]),
                    ),
                ]),
                const SizedBox(height: 12),
                ...sortedEntries.map((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final teamId = data['teamId'] ?? '';
                  final teamName = data['teamName'] ?? 'チーム';
                  final leader = data['leaderName'] ?? '';
                  final memberUids = (data['memberUids'] as List<dynamic>?) ?? [];
                  final memberNames = (data['memberNames'] as Map<String, dynamic>?) ?? {};
                  final isMyTeam = _myTeamIds.contains(teamId);
                  final isCheckedIn = checkedInTeamIds.contains(teamId);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GestureDetector(
                      // 主催者・編集者は他チームもタップでメンバー一覧（誰がエントリーしたか）を確認できる
                      onTap: isMyTeam
                          ? () => _showEditEntrySheet(doc)
                          : canManage
                              ? () => _showMemberList(teamName.toString(), Map<String, dynamic>.from(memberNames), leader.toString())
                              : null,
                      child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: isMyTeam ? Colors.red.withValues(alpha:0.06) : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isMyTeam ? Colors.red.withValues(alpha:0.3) : Colors.grey[200]!),
                      ),
                      child: Row(children: [
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(teamName.toString(), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: isMyTeam ? Colors.red : AppTheme.textPrimary)),
                            const SizedBox(height: 4),
                            Row(children: [
                              Text('キャプテン: $leader / ${memberUids.length}人', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                              if (isCheckedIn) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                                  child: Text('受付済', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.success)),
                                ),
                              ],
                            ]),
                            if (canManage && memberNames.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                _orderedMemberNames(memberNames, leader.toString()).join('・'),
                                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ]),
                        ),
                        if (isMyTeam) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: Colors.red.withValues(alpha:0.1), borderRadius: BorderRadius.circular(8)),
                            child: const Text('自分', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red)),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.chevron_right, size: 20, color: AppTheme.textHint),
                        ] else ...[
                          if (!isCheckedIn && checkedInTeamIds.isNotEmpty)
                            Text('未到着', style: TextStyle(fontSize: 11, color: AppTheme.textHint)),
                          if (canManage) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.chevron_right, size: 20, color: AppTheme.textHint),
                          ],
                        ],
                      ]),
                    ),
                    ),
                  );
                }),
                const SizedBox(height: 80),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTimelineTab() {
    if (_tournamentId.isEmpty) return const Center(child: Text('大会IDが見つかりません'));
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Column(
      children: [
        // 大会掲示板 / チーム掲示板 切り替え
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(child: GestureDetector(
              onTap: () => setState(() => _isBoardTeam = false),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: !_isBoardTeam ? AppTheme.primaryColor : Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(child: Text('大会掲示板', style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: !_isBoardTeam ? Colors.white : AppTheme.textSecondary))),
              ),
            )),
            const SizedBox(width: 8),
            Expanded(child: GestureDetector(
              onTap: () {
                if (_myEntryTeamId.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('エントリーすると使えます'), backgroundColor: AppTheme.warning));
                  return;
                }
                setState(() => _isBoardTeam = true);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _isBoardTeam ? AppTheme.primaryColor : Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(child: Text('チーム掲示板', style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: _isBoardTeam ? Colors.white : AppTheme.textSecondary))),
              ),
            )),
          ]),
        ),

        // 投稿入力
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(radius: 18, backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                  child: const Icon(Icons.person, size: 20, color: AppTheme.primaryColor)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _postController,
                  decoration: InputDecoration(
                    hintText: _isBoardTeam ? 'チームへメッセージ...' : 'コメントを投稿...',
                    hintStyle: TextStyle(fontSize: 14, color: AppTheme.textHint),
                    filled: true, fillColor: AppTheme.backgroundColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.image, color: AppTheme.primaryColor, size: 24),
                onPressed: () async {
                  final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
                  if (picked != null && mounted) setState(() => _selectedBoardImage = picked);
                },
              ),
              const SizedBox(width: 4),
              Container(
                decoration: BoxDecoration(color: AppTheme.primaryColor, borderRadius: BorderRadius.circular(20)),
                child: IconButton(icon: const Icon(Icons.send, color: Colors.white, size: 20),
                    onPressed: () => _submitTimelinePost(uid)),
              ),
            ],
          ),
        ),
        // 画像プレビュー
        if (_selectedBoardImage != null)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Stack(
              alignment: Alignment.topRight,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: FutureBuilder<Uint8List>(
                    future: _selectedBoardImage!.readAsBytes(),
                    builder: (ctx, snap) {
                      if (!snap.hasData) return const SizedBox(height: 100);
                      return Image.memory(snap.data!, height: 100, width: double.infinity, fit: BoxFit.cover);
                    },
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _selectedBoardImage = null),
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    width: 24, height: 24,
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.close, color: Colors.white, size: 16),
                  ),
                ),
              ],
            ),
          ),
        // 主催者向け: お知らせ送信ボタン
        if (!_isBoardTeam && _canManageTournament(widget.tournament))
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: GestureDetector(
              onTap: () => _showAnnouncementDialog(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.campaign, size: 18, color: AppTheme.accentColor),
                    const SizedBox(width: 8),
                    Text('全参加者にお知らせを送信', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
                  ],
                ),
              ),
            ),
          ),
        Divider(height: 1, color: Colors.grey[200]),

        // 投稿一覧
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _isBoardTeam && _myEntryTeamId.isNotEmpty
                ? _firestore.collection('tournaments').doc(_tournamentId)
                    .collection('team_board').doc(_myEntryTeamId).collection('posts')
                    .orderBy('createdAt', descending: true).snapshots()
                : _firestore.collection('tournaments').doc(_tournamentId)
                    .collection('timeline').orderBy('createdAt', descending: true).snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) return Center(child: Text('読み込みに失敗しました', style: TextStyle(color: AppTheme.textSecondary)));
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
              final rawPosts = snapshot.data?.docs ?? [];
              final posts = List<QueryDocumentSnapshot>.from(rawPosts);
              if (!_isBoardTeam) {
                posts.sort((a, b) {
                  final aPin = (a.data() as Map<String, dynamic>)['pinned'] == true ? 0 : 1;
                  final bPin = (b.data() as Map<String, dynamic>)['pinned'] == true ? 0 : 1;
                  return aPin.compareTo(bPin);
                });
              }
              final isCurrentUserOrganizer = _canManageTournament(widget.tournament);

              if (posts.isEmpty) {
                return Center(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_isBoardTeam ? Icons.group : Icons.chat_bubble_outline, size: 48, color: AppTheme.textHint),
                    const SizedBox(height: 12),
                    Text(_isBoardTeam ? 'チーム掲示板にメッセージを投稿しよう！' : '最初のコメントを投稿しよう！',
                        style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                  ],
                ));
              }

              return ListView.builder(
                itemCount: posts.length,
                itemBuilder: (context, index) {
                  final post = posts[index];
                  final postId = post.id;
                  final data = post.data() as Map<String, dynamic>;
                  final authorName = data['authorName'];
                  final authorAvatar = data['authorAvatar'];
                  final text = data['text'];
                  final imageUrl = data['imageUrl'] as String? ?? '';
                  final isOrganizer = data['isOrganizer'] == true;
                  final isPinned = data['pinned'] == true;
                  final isAnnouncement = data['isAnnouncement'] == true;
                  final createdAt = data['createdAt'] as Timestamp?;
                  final likes = data['likesCount'] ?? 0;

                  String timeAgo = '';
                  if (createdAt != null) {
                    final diff = DateTime.now().difference(createdAt.toDate());
                    if (diff.inMinutes < 1) timeAgo = 'たった今';
                    else if (diff.inHours < 1) timeAgo = '${diff.inMinutes}分前';
                    else if (diff.inDays < 1) timeAgo = '${diff.inHours}時間前';
                    else timeAgo = '${diff.inDays}日前';
                  }

                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isAnnouncement ? AppTheme.accentColor.withValues(alpha: 0.04) : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: isAnnouncement ? Border.all(color: AppTheme.accentColor.withValues(alpha: 0.3)) : null,
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isAnnouncement)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppTheme.accentColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.campaign, size: 14, color: AppTheme.accentColor),
                                const SizedBox(width: 4),
                                Text('お知らせ', style: TextStyle(fontSize: 11, color: AppTheme.accentColor, fontWeight: FontWeight.bold)),
                              ]),
                            ),
                          )
                        else if (isPinned)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.push_pin, size: 14, color: AppTheme.accentColor),
                              const SizedBox(width: 4),
                              Text('ピン留め', style: TextStyle(fontSize: 11, color: AppTheme.accentColor, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        Row(children: [
                          authorAvatar.toString().isNotEmpty
                              ? CircleAvatar(radius: 16, backgroundImage: NetworkImage(authorAvatar.toString()),
                                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12))
                              : CircleAvatar(radius: 16,
                                  backgroundColor: isOrganizer ? AppTheme.accentColor.withValues(alpha: 0.15) : AppTheme.primaryColor.withValues(alpha: 0.12),
                                  child: Text(authorName.toString().isNotEmpty ? authorName.toString()[0] : '?',
                                      style: TextStyle(color: isOrganizer ? AppTheme.accentColor : AppTheme.primaryColor, fontWeight: FontWeight.bold, fontSize: 13))),
                          const SizedBox(width: 8),
                          Text(authorName.toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                          if (isOrganizer) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(color: AppTheme.accentColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                              child: Text('大会主催者', style: TextStyle(fontSize: 10, color: AppTheme.accentColor, fontWeight: FontWeight.bold)),
                            ),
                          ],
                          const Spacer(),
                          Text(timeAgo, style: TextStyle(fontSize: 12, color: AppTheme.textHint)),
                        ]),
                        const SizedBox(height: 8),
                        if (text.toString().isNotEmpty)
                          Text(text.toString(), style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary, height: 1.5)),
                        if (imageUrl.isNotEmpty) ...[
                          if (text.toString().isNotEmpty) const SizedBox(height: 8),
                          GestureDetector(
                            onTap: () => _showFullBoardImage(imageUrl),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.network(imageUrl, width: double.infinity, fit: BoxFit.cover,
                                  loadingBuilder: (_, child, progress) {
                                    if (progress == null) return child;
                                    return Container(height: 180, color: Colors.grey[100],
                                        child: const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor, strokeWidth: 2)));
                                  },
                                  errorBuilder: (_, __, ___) => const SizedBox()),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(children: [
                          if (!_isBoardTeam) ...[
                            GestureDetector(
                              onTap: () => _toggleTimelineLike(postId, uid),
                              child: Row(children: [
                                StreamBuilder<DocumentSnapshot>(
                                  stream: _firestore.collection('tournaments').doc(_tournamentId)
                                      .collection('timeline').doc(postId).collection('likes').doc(uid).snapshots(),
                                  builder: (context, likeSnap) {
                                    final liked = likeSnap.data?.exists == true;
                                    return Icon(liked ? Icons.favorite : Icons.favorite_border, size: 18,
                                        color: liked ? Colors.red : AppTheme.textHint);
                                  },
                                ),
                                const SizedBox(width: 4),
                                Text('$likes', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                              ]),
                            ),
                            if (isCurrentUserOrganizer) ...[const SizedBox(width: 16),
                              GestureDetector(
                                onTap: () => _firestore.collection('tournaments').doc(_tournamentId)
                                    .collection('timeline').doc(postId).update({'pinned': !(isPinned)}),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.push_pin, size: 16, color: isPinned ? AppTheme.accentColor : AppTheme.textHint),
                                  const SizedBox(width: 4),
                                  Text(isPinned ? 'ピン解除' : 'ピン留め', style: TextStyle(fontSize: 12, color: isPinned ? AppTheme.accentColor : AppTheme.textSecondary)),
                                ]),
                              ),
                            ],
                          ],
                        ]),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _submitTimelinePost(String uid) async {
    final text = _postController.text.trim();
    final hasImage = _selectedBoardImage != null;
    if (text.isEmpty && !hasImage) return;
    if (_tournamentId.isEmpty) return;

    // ローディング表示
    if (hasImage && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
      );
    }

    try {
      String imageUrl = '';
      if (hasImage) {
        final bytes = await _selectedBoardImage!.readAsBytes();
        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${_selectedBoardImage!.name}';
        final ref = FirebaseStorage.instance
            .ref().child('tournament_board').child(_tournamentId).child(fileName);
        await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        imageUrl = await ref.getDownloadURL();
      }

      final userDoc = await _firestore.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? {};
      final nickname = userData['nickname'] ?? '匿名';
      final avatar = userData['avatarUrl'] ?? '';

      final postData = <String, dynamic>{
        'authorId': uid, 'authorName': nickname, 'authorAvatar': avatar,
        'text': text, 'createdAt': FieldValue.serverTimestamp(),
      };
      if (imageUrl.isNotEmpty) postData['imageUrl'] = imageUrl;

      if (_isBoardTeam && _myEntryTeamId.isNotEmpty) {
        await _firestore.collection('tournaments').doc(_tournamentId)
            .collection('team_board').doc(_myEntryTeamId).collection('posts').add(postData);
      } else {
        final tournamentDoc = await _firestore.collection('tournaments').doc(_tournamentId).get();
        final tournamentData = tournamentDoc.data() ?? {};
        final isOrganizer = _canManageTournament(tournamentData);

        postData.addAll({'isOrganizer': isOrganizer, 'pinned': false, 'likesCount': 0});
        await _firestore.collection('tournaments').doc(_tournamentId).collection('timeline').add(postData);
      }

      _postController.clear();
      setState(() => _selectedBoardImage = null);
      FocusScope.of(context).unfocus();
      if (hasImage && mounted) Navigator.pop(context); // ローディング閉じる
    } catch (e) {
      if (hasImage && mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('投稿に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ── 掲示板に画像を投稿 ──
  Future<void> _pickAndSendBoardImage(String uid) async {
    if (_tournamentId.isEmpty) return;

    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (picked == null || !mounted) return;

      // ローディング表示
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
      );

      final bytes = await picked.readAsBytes();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      final ref = FirebaseStorage.instance
          .ref()
          .child('tournament_board')
          .child(_tournamentId)
          .child(fileName);

      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final downloadUrl = await ref.getDownloadURL();

      final userDoc = await _firestore.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? {};
      final nickname = userData['nickname'] ?? '匿名';
      final avatar = userData['avatarUrl'] ?? '';

      if (_isBoardTeam && _myEntryTeamId.isNotEmpty) {
        await _firestore.collection('tournaments').doc(_tournamentId)
            .collection('team_board').doc(_myEntryTeamId).collection('posts').add({
          'authorId': uid, 'authorName': nickname, 'authorAvatar': avatar,
          'text': '', 'imageUrl': downloadUrl,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        final tournamentDoc = await _firestore.collection('tournaments').doc(_tournamentId).get();
        final tournamentData = tournamentDoc.data() ?? {};
        final isOrganizer = _canManageTournament(tournamentData);

        await _firestore.collection('tournaments').doc(_tournamentId).collection('timeline').add({
          'authorId': uid, 'authorName': nickname, 'authorAvatar': avatar,
          'text': '', 'imageUrl': downloadUrl,
          'isOrganizer': isOrganizer, 'pinned': false,
          'likesCount': 0, 'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) Navigator.pop(context); // ローディング閉じる
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // ローディング閉じる
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('画像の送信に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ── 掲示板画像フルスクリーン ──
  void _showFullBoardImage(String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(url, fit: BoxFit.contain),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Icons.close, color: Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ━━━ フォトギャラリータブ ━━━
  Widget _buildPhotoGalleryTab() {
    if (_tournamentId.isEmpty) return const Center(child: Text('大会IDが見つかりません'));
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Column(
      children: [
        // 写真アップロードボタン
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: InkWell(
            onTap: () => _uploadGalleryPhoto(uid),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate, color: AppTheme.primaryColor, size: 22),
                  SizedBox(width: 8),
                  Text('大会の写真をアップロード（複数選択可）', style: TextStyle(
                    fontSize: 14, color: AppTheme.primaryColor, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
        Divider(height: 1, color: Colors.grey[200]),
        // 写真グリッド
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('tournaments').doc(_tournamentId)
                .collection('photos').orderBy('createdAt', descending: true).snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
              }
              final photos = snapshot.data?.docs ?? [];

              if (photos.isEmpty) {
                return Center(child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.photo_library_outlined, size: 56, color: AppTheme.textHint),
                    const SizedBox(height: 12),
                    const Text('まだ写真はありません', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                    const SizedBox(height: 4),
                    const Text('大会の思い出を共有しましょう！', style: TextStyle(fontSize: 13, color: AppTheme.textHint)),
                  ],
                ));
              }

              return GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemCount: photos.length,
                itemBuilder: (context, index) {
                  final photoDoc = photos[index];
                  final data = photoDoc.data() as Map<String, dynamic>;
                  final imageUrl = (data['imageUrl'] as String?) ?? '';
                  final uploaderName = (data['uploaderName'] as String?) ?? '';
                  final uploadedBy = (data['uploadedBy'] as String?) ?? '';
                  return GestureDetector(
                    onTap: () => _showGalleryPhotoViewer(photos, index),
                    onLongPress: uploadedBy == uid
                        ? () => _confirmDeleteGalleryPhoto(photoDoc.id)
                        : null,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(imageUrl, fit: BoxFit.cover,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return Container(color: Colors.grey[100],
                              child: const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor, strokeWidth: 2)));
                        },
                        errorBuilder: (_, __, ___) => Container(color: Colors.grey[100],
                            child: const Icon(Icons.broken_image, color: AppTheme.textHint)),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ── 写真ギャラリーにアップロード（複数選択対応） ──
  Future<void> _uploadGalleryPhoto(String uid) async {
    if (_tournamentId.isEmpty) return;

    try {
      final pickedList = await ImagePicker().pickMultiImage(
        imageQuality: 75,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (pickedList.isEmpty || !mounted) return;

      // 画像ファイルのみフィルタ（「ファイルを選択」から非画像が選ばれた場合を除外）
      const allowedExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.heif', '.bmp'};
      final imageFiles = pickedList.where((f) {
        final ext = f.name.contains('.') ? '.${f.name.split('.').last.toLowerCase()}' : '';
        return allowedExtensions.contains(ext);
      }).toList();
      if (imageFiles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('写真ファイルのみアップロードできます'), backgroundColor: AppTheme.error),
          );
        }
        return;
      }

      // アップロード確認画面
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('${imageFiles.length}枚の写真をアップロード', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite,
            height: imageFiles.length == 1 ? 200 : 160,
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: imageFiles.length == 1 ? 1 : 3,
                crossAxisSpacing: 4, mainAxisSpacing: 4,
              ),
              itemCount: imageFiles.length,
              itemBuilder: (_, i) => FutureBuilder<Uint8List>(
                future: imageFiles[i].readAsBytes(),
                builder: (_, snap) {
                  if (!snap.hasData) return Container(color: Colors.grey[200]);
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(snap.data!, fit: BoxFit.cover),
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
              child: const Text('アップロード'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
      );

      final userDoc = await _firestore.collection('users').doc(uid).get();
      final uploaderName = (userDoc.data()?['nickname'] as String?) ?? 'ユーザー';

      for (final picked in imageFiles) {
        final bytes = await picked.readAsBytes();
        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
        final ref = FirebaseStorage.instance
            .ref()
            .child('tournament_photos')
            .child(_tournamentId)
            .child(fileName);

        await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        final downloadUrl = await ref.getDownloadURL();

        await _firestore.collection('tournaments').doc(_tournamentId).collection('photos').add({
          'imageUrl': downloadUrl,
          'uploadedBy': uid,
          'uploaderName': uploaderName,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        Navigator.pop(context); // ローディング閉じる
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${imageFiles.length}枚の写真をアップロードしました'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('アップロードに失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ── ギャラリー写真を削除 ──
  void _confirmDeleteGalleryPhoto(String photoId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('写真を削除', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text('この写真を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              await _firestore.collection('tournaments').doc(_tournamentId)
                  .collection('photos').doc(photoId).delete();
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('写真を削除しました'), backgroundColor: AppTheme.success),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  // ── ギャラリー写真フルスクリーン（横スワイプ対応） ──
  void _showGalleryPhotoViewer(List<QueryDocumentSnapshot> photos, int initialIndex) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _GalleryPhotoViewer(photos: photos, initialIndex: initialIndex),
    );
  }

  Future<void> _toggleTimelineLike(String postId, String uid) async {
    if (uid.isEmpty || _tournamentId.isEmpty) return;
    final likeRef = _firestore.collection('tournaments').doc(_tournamentId)
        .collection('timeline').doc(postId).collection('likes').doc(uid);
    final postRef = _firestore.collection('tournaments').doc(_tournamentId)
        .collection('timeline').doc(postId);

    final likeDoc = await likeRef.get();
    if (likeDoc.exists) {
      await likeRef.delete();
    } else {
      await likeRef.set({'userId': uid, 'createdAt': FieldValue.serverTimestamp()});
    }
  }

  String _formatTimeAgo(Timestamp? ts) {
    if (ts == null) return '';
    final diff = DateTime.now().difference(ts.toDate());
    if (diff.inMinutes < 1) return 'たった今';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 7) return '${diff.inDays}日前';
    return '${ts.toDate().month}/${ts.toDate().day}';
  }

  // ━━━ エントリー編集シート ━━━
  void _showEditEntrySheet(DocumentSnapshot entryDoc) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    final data = entryDoc.data() as Map<String, dynamic>;
    final entryDocId = entryDoc.id;
    final currentTeamName = (data['teamName'] ?? '') as String;
    final leaderUid = (data['leaderUid'] ?? '') as String;
    final leaderName = (data['leaderName'] ?? '') as String;
    final currentMemberUids = List<String>.from((data['memberUids'] as List<dynamic>?) ?? []);
    final currentMemberNames = Map<String, String>.from(
      ((data['memberNames'] as Map<String, dynamic>?) ?? {}).map((k, v) => MapEntry(k, v.toString())),
    );

    // 自分がエントリーした人（leaderUid）でなければ編集不可
    if (leaderUid != uid) {
      _showMemberList(currentTeamName, Map<String, dynamic>.from(currentMemberNames), leaderName);
      return;
    }

    final teamNameCtrl = TextEditingController(text: currentTeamName);
    // 自分以外のメンバーを選択済みとして初期化
    final selectedMembers = <String, String>{};
    for (final entry in currentMemberNames.entries) {
      if (entry.key != uid) {
        selectedMembers[entry.key] = entry.value;
      }
    }

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Scaffold(
              backgroundColor: AppTheme.backgroundColor,
              appBar: AppBar(
                leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () {
                  if (teamNameCtrl.text.trim() != currentTeamName || selectedMembers.length != currentMemberNames.entries.where((e) => e.key != uid).length) {
                    showDialog(context: ctx, builder: (c) => AlertDialog(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Text('入力内容を破棄しますか？'),
                      content: const Text('入力した内容は保存されません。'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c), child: const Text('キャンセル')),
                        TextButton(onPressed: () { Navigator.pop(c); Navigator.pop(ctx); }, child: const Text('破棄する', style: TextStyle(color: Colors.red))),
                      ],
                    ));
                  } else {
                    Navigator.pop(ctx);
                  }
                }),
                title: const Text('エントリー編集', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                centerTitle: true,
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // チーム名入力
                    const Text('チーム名', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: teamNameCtrl,
                      decoration: InputDecoration(
                        hintText: 'チーム名を入力',
                        filled: true,
                        fillColor: AppTheme.backgroundColor,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // メンバー選択（フォロー中から）
                    const Text('メンバーを選択（フォロー中から）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    FollowerMemberPicker(
                      uid: uid,
                      selectedMembers: selectedMembers,
                      tournamentId: _tournamentId,
                      excludeEntryId: entryDocId,
                      onToggle: (fUid, fName) {
                        setSheetState(() {
                          if (selectedMembers.containsKey(fUid)) {
                            selectedMembers.remove(fUid);
                          } else {
                            selectedMembers[fUid] = fName;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      selectedMembers.isEmpty
                          ? '自分＋メンバー3人以上を選択してください（4人以上必要）'
                          : '${selectedMembers.length + 1}人（自分＋${selectedMembers.length}人選択中）${selectedMembers.length < 3 ? " ※あと${3 - selectedMembers.length}人必要" : ""}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selectedMembers.length < 3 ? AppTheme.textHint : AppTheme.primaryColor,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // 保存ボタン
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          final teamName = teamNameCtrl.text.trim();
                          if (teamName.isEmpty) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('チーム名を入力してください'), backgroundColor: AppTheme.warning));
                            return;
                          }
                          if (selectedMembers.length < 3) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('メンバーは自分を含めて4人以上必要です'), backgroundColor: AppTheme.warning));
                            return;
                          }

                          // 承認制：重複チェック・削除・追加メンバーへの招待は
                          // サーバー側（updateEntryMembers）で行う。追加メンバーは
                          // 本人が承認するまで本物のエントリーには入らない。
                          try {
                            final callable = FirebaseFunctions.instance.httpsCallable('updateEntryMembers');
                            final res = await callable.call({
                              'tournamentId': _tournamentId,
                              'entryId': entryDocId,
                              'teamName': teamName,
                              'memberUids': selectedMembers.keys.toList(),
                            });
                            final added = ((res.data as Map)['added'] ?? 0) as int;
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(added > 0
                                      ? 'エントリーを更新しました。追加した$added人には招待を送信し、承認するとメンバーに加わります'
                                      : 'エントリーを更新しました'),
                                  backgroundColor: AppTheme.success,
                                ),
                              );
                            }
                          } on FirebaseFunctionsException catch (e) {
                            if (!ctx.mounted) return;
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text(e.message ?? '更新に失敗しました'), backgroundColor: AppTheme.error),
                            );
                          } catch (_) {
                            if (!ctx.mounted) return;
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('更新に失敗しました'), backgroundColor: AppTheme.error),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('変更を保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ));
  }

  // ━━━ エントリーシート ━━━
  void _showEntrySheet(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    final teamNameCtrl = TextEditingController();
    final selectedMembers = <String, String>{};  // uid -> nickname

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Scaffold(
              backgroundColor: AppTheme.backgroundColor,
              appBar: AppBar(
                leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () {
                  if (teamNameCtrl.text.trim().isNotEmpty || selectedMembers.isNotEmpty) {
                    showDialog(context: ctx, builder: (c) => AlertDialog(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Text('入力内容を破棄しますか？'),
                      content: const Text('入力した内容は保存されません。'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c), child: const Text('戻る')),
                        TextButton(onPressed: () { Navigator.pop(c); Navigator.pop(ctx); },
                          child: const Text('破棄する', style: TextStyle(color: Colors.red))),
                      ],
                    ));
                  } else { Navigator.pop(ctx); }
                }),
                title: const Text('大会にエントリー', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                centerTitle: true,
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha:0.05),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.primaryColor.withValues(alpha:0.15)),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text((widget.tournament['name'] ?? widget.tournament['title'] ?? '') as String,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                        const SizedBox(height: 4),
                        Text((widget.tournament['date'] ?? '') as String,
                            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      ]),
                    ),
                    const SizedBox(height: 20),

                    // チーム名入力
                    const Text('エントリーチーム名', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: teamNameCtrl,
                      decoration: InputDecoration(
                        hintText: 'チーム名を入力',
                        filled: true,
                        fillColor: AppTheme.backgroundColor,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // メンバー選択（フォロー中から）
                    const Text('メンバーを選択（フォロー中から）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    FollowerMemberPicker(
                      uid: uid,
                      selectedMembers: selectedMembers,
                      tournamentId: _tournamentId,
                      onToggle: (fUid, fName) {
                        setSheetState(() {
                          if (selectedMembers.containsKey(fUid)) {
                            selectedMembers.remove(fUid);
                          } else {
                            selectedMembers[fUid] = fName;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      selectedMembers.isEmpty
                          ? '自分＋メンバー3人以上を選択してください（4人以上必要）'
                          : '${selectedMembers.length + 1}人（自分＋${selectedMembers.length}人選択中）${selectedMembers.length < 3 ? " ※あと${3 - selectedMembers.length}人必要" : ""}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selectedMembers.length < 3 ? AppTheme.textHint : AppTheme.primaryColor,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 未登録メンバーの招待（登録するとフォロー中に並び、選択できるようになる）
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          showInviteShareSheet(
                            context,
                            tournamentId: _tournamentId,
                            tournamentName: (widget.tournament['name'] ?? widget.tournament['title'] ?? '') as String,
                            title: '未登録のメンバーを招待',
                            description: '一緒に出るメンバーがまだ登録していない場合、招待リンクとコードを送ってください。登録するとフォロー中に並び、メンバーとして選べるようになります。',
                          );
                        },
                        icon: const Icon(Icons.person_add_alt, size: 20),
                        label: const Text('未登録のメンバーを招待', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryColor,
                          side: const BorderSide(color: AppTheme.primaryColor),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // エントリーボタン
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          final teamName = teamNameCtrl.text.trim();
                          if (teamName.isEmpty) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('チーム名を入力してください'), backgroundColor: AppTheme.warning));
                            return;
                          }
                          // 自分 + 選択メンバーで4人以上必要
                          if (selectedMembers.length < 3) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('メンバーは自分を含めて4人以上必要です'), backgroundColor: AppTheme.warning));
                            return;
                          }
                          _confirmNewEntry(ctx, teamName, selectedMembers);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('エントリーする', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ));
  }

  // ━━━ 承認待ちエントリー（ドラフト）バナー ━━━
  // 自分がキャプテン → 承認状況＋取り消し。自分が招待メンバー → 承認/辞退。
  Widget _buildEntryDraftBanner() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('tournaments').doc(_tournamentId)
          .collection('entryDrafts')
          .where('invitedUids', arrayContains: uid)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        return Column(
          children: docs.map((d) {
            final data = d.data() as Map<String, dynamic>;
            final teamName = (data['teamName'] ?? '').toString();
            final leaderUid = (data['leaderUid'] ?? '').toString();
            final isMemberAdd = data['type'] == 'memberAdd';
            final invited = List<String>.from((data['invitedUids'] as List<dynamic>?) ?? []);
            final approvals = Map<String, dynamic>.from(data['approvals'] as Map? ?? {});
            final seenAt = Map<String, dynamic>.from(data['seenAt'] as Map? ?? {});
            final memberNames = Map<String, dynamic>.from(data['memberNames'] as Map? ?? {});
            // 辞退した人は分母から除外する（辞退しても残りの有効メンバーだけで自動成立するため）
            final activeCount = invited.where((u) => approvals[u] != 'declined').length;
            final approvedCount = invited.where((u) => approvals[u] == 'approved').length;
            final isLeader = leaderUid == uid;
            final myState = (approvals[uid] ?? 'pending').toString();

            if (!isLeader && myState == 'pending') {
              WidgetsBinding.instance.addPostFrameCallback((_) => _markEntryDraftSeenIfNeeded(d.id));
            }

            return Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.how_to_reg, size: 18, color: AppTheme.primaryColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(isMemberAdd ? '追加メンバーの承認待ち「$teamName」' : '承認待ちエントリー「$teamName」',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                    ),
                    Text('承認 $approvedCount/$activeCount',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary)),
                  ]),
                  const SizedBox(height: 8),
                  if (isLeader) ...[
                    // キャプテン視点：未承認メンバーの一覧＋取り消し
                    ...invited.where((u) => u != uid).map((u) {
                      final st = (approvals[u] ?? 'pending').toString();
                      final nm = (memberNames[u] ?? '?').toString();
                      final seen = seenAt[u] != null;
                      final label = st == 'approved'
                          ? '承認済み'
                          : st == 'declined'
                              ? '辞退'
                              : (seen ? '既読・未回答' : '未読');
                      final c = st == 'approved'
                          ? AppTheme.success
                          : st == 'declined'
                              ? AppTheme.error
                              : (seen ? AppTheme.accentColor : AppTheme.textHint);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => UserProfileScreen(userId: u))),
                              child: Text(nm,
                                  style: const TextStyle(fontSize: 13, decoration: TextDecoration.underline, decorationColor: AppTheme.textHint)),
                            ),
                          ),
                          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c)),
                          if (st == 'pending') ...[
                            InkWell(
                              onTap: () => _resendEntryInvite(d.id, u, nm),
                              borderRadius: BorderRadius.circular(12),
                              child: const Padding(
                                padding: EdgeInsets.only(left: 4, top: 2, bottom: 2, right: 2),
                                child: Icon(Icons.notifications_active_outlined, size: 15, color: AppTheme.accentColor),
                              ),
                            ),
                          ],
                          InkWell(
                            onTap: () => _removeEntryDraftMember(d.id, u, nm),
                            borderRadius: BorderRadius.circular(12),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4, top: 2, bottom: 2, right: 2),
                              child: Icon(Icons.close, size: 16, color: AppTheme.textHint),
                            ),
                          ),
                        ]),
                      );
                    }),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: () => _showAddEntryDraftMemberSheet(d.id, teamName),
                          icon: const Icon(Icons.person_add_alt, size: 16, color: AppTheme.primaryColor),
                          label: const Text('追加招待', style: TextStyle(fontSize: 13, color: AppTheme.primaryColor, fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
                        ),
                        TextButton.icon(
                          onPressed: () => _cancelEntryDraft(d.id, teamName: teamName),
                          icon: const Icon(Icons.close, size: 16, color: AppTheme.error),
                          label: const Text('招待を取り消す', style: TextStyle(fontSize: 13, color: AppTheme.error, fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
                        ),
                      ],
                    ),
                  ] else if (myState == 'pending') ...[
                    // 招待メンバー視点：承認 / 辞退
                    Text('${(data['leaderName'] ?? '').toString()} さんから招待されています', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _respondEntryInvite(d.id, true),
                          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                              minimumSize: const Size(0, 38), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                          child: const Text('承認する', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: () => _respondEntryInvite(d.id, false),
                        style: OutlinedButton.styleFrom(foregroundColor: AppTheme.error, side: const BorderSide(color: AppTheme.error),
                            minimumSize: const Size(0, 38), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                        child: const Text('辞退', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ),
                    ]),
                  ] else ...[
                    Text(myState == 'approved' ? '承認済み・他のメンバーの承認を待っています' : '辞退済み',
                        style: TextStyle(fontSize: 13, color: myState == 'approved' ? AppTheme.success : AppTheme.error, fontWeight: FontWeight.w600)),
                    if (myState == 'declined') ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => _respondEntryInvite(d.id, true),
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                          child: const Text('間違えて辞退した場合はこちら（参加する）',
                              style: TextStyle(fontSize: 12, color: AppTheme.primaryColor, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Future<void> _respondEntryInvite(String draftId, bool approve) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('respondEntryInvite');
      final res = await callable.call({'tournamentId': _tournamentId, 'draftId': draftId, 'approve': approve});
      final finalized = (res.data as Map)['finalized'] == true;
      final memberAdd = (res.data as Map)['memberAdd'] == true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(!approve
            ? '招待を辞退しました'
            : memberAdd
                ? 'チームに参加しました！'
                : finalized
                    ? 'エントリーが成立しました！'
                    : '承認しました。他のメンバーの承認を待っています'),
        backgroundColor: approve ? AppTheme.success : AppTheme.textSecondary,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? '処理に失敗しました'), backgroundColor: AppTheme.error));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('処理に失敗しました'), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _cancelEntryDraft(String draftId, {String teamName = ''}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('招待を取り消しますか？', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: Text(
          '${teamName.isNotEmpty ? '「$teamName」の' : ''}エントリー招待を取り消します。\n承認済みのメンバーの分も含めて取り消され、元に戻せません。',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('やめる')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取り消す', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('cancelEntryDraft');
      await callable.call({'tournamentId': _tournamentId, 'draftId': draftId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('招待を取り消しました'), backgroundColor: AppTheme.textSecondary),
        );
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('取り消しに失敗しました'), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _resendEntryInvite(String draftId, String targetUid, String targetName) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('resendEntryInviteNotification');
      await callable.call({'tournamentId': _tournamentId, 'draftId': draftId, 'targetUid': targetUid});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$targetName さんに招待を再通知しました'),
        backgroundColor: AppTheme.success,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? '再通知に失敗しました'), backgroundColor: AppTheme.error));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('再通知に失敗しました'), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _adminApproveEntryDraftMember(String draftId, String targetUid, String targetName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('代わりに承認しますか？'),
        content: Text(
            '$targetName さん本人がアプリの不具合等でどうしても自分で承認できない場合の最終手段です。\n\n必ず本人に「参加してよいか」を別途確認した上で実行してください。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('代わりに承認する', style: TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('adminApproveEntryDraftMember');
      final res = await callable.call({'tournamentId': _tournamentId, 'draftId': draftId, 'targetUid': targetUid});
      final finalized = (res.data as Map)['finalized'] == true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(finalized
            ? '$targetName さんを代わりに承認し、エントリーが成立しました！'
            : '$targetName さんを代わりに承認しました'),
        backgroundColor: AppTheme.success,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? '代理承認に失敗しました'), backgroundColor: AppTheme.error));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('代理承認に失敗しました'), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _removeEntryDraftMember(String draftId, String targetUid, String targetName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('招待を取り消しますか？'),
        content: Text('$targetName さんへの招待だけを取り消します。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('取り消す', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('removeEntryDraftMember');
      final res = await callable.call({'tournamentId': _tournamentId, 'draftId': draftId, 'targetUid': targetUid});
      final finalized = (res.data as Map)['finalized'] == true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(finalized
            ? '$targetName さんを外し、残りメンバーでエントリーが成立しました！'
            : '$targetName さんへの招待を取り消しました'),
        backgroundColor: AppTheme.success,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? '取り消しに失敗しました'), backgroundColor: AppTheme.error));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('取り消しに失敗しました'), backgroundColor: AppTheme.error));
    }
  }

  void _showAddEntryDraftMemberSheet(String draftId, String teamName) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    final selectedMembers = <String, String>{};
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Scaffold(
            backgroundColor: AppTheme.backgroundColor,
            appBar: AppBar(
              title: const Text('メンバーを追加招待', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              centerTitle: true,
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('「$teamName」に追加で招待するメンバーを選択', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  FollowerMemberPicker(
                    uid: uid,
                    selectedMembers: selectedMembers,
                    tournamentId: _tournamentId,
                    onToggle: (fUid, fName) {
                      setSheetState(() {
                        if (selectedMembers.containsKey(fUid)) {
                          selectedMembers.remove(fUid);
                        } else {
                          selectedMembers[fUid] = fName;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: selectedMembers.isEmpty
                          ? null
                          : () async {
                              final targets = Map<String, String>.from(selectedMembers);
                              final callable = FirebaseFunctions.instance.httpsCallable('addEntryDraftMember');
                              var okCount = 0;
                              String? lastError;
                              for (final entry in targets.entries) {
                                try {
                                  await callable.call({'tournamentId': _tournamentId, 'draftId': draftId, 'targetUid': entry.key});
                                  okCount++;
                                } on FirebaseFunctionsException catch (e) {
                                  lastError = e.message;
                                } catch (_) {
                                  lastError = '追加に失敗しました';
                                }
                              }
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(okCount > 0
                                      ? '$okCount 人に追加招待を送信しました${lastError != null ? '（一部失敗: $lastError）' : ''}'
                                      : (lastError ?? '追加に失敗しました')),
                                  backgroundColor: okCount > 0 ? AppTheme.success : AppTheme.error,
                                ));
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('招待を送る', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ));
  }

  Future<void> _confirmNewEntry(BuildContext sheetContext, String teamName, Map<String, String> members) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('エントリー確認', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「$teamName」で以下の大会にエントリーしますか？'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((widget.tournament['name'] ?? widget.tournament['title'] ?? '') as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text((widget.tournament['date'] ?? '') as String, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ]),
            ),
            if (members.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('メンバー: ${members.values.join(", ")}', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8)),
              child: const Text(
                '選んだメンバーに招待を送ります。全員が承認するとエントリーが成立します。',
                style: TextStyle(fontSize: 12.5, color: AppTheme.primaryColor, height: 1.5),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('招待を送る', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // 承認制：本物のエントリーは作らず、招待（entryDraft）を作成する。
    // 重複チェック・名前収集・通知はサーバー側（createEntryDraft）で行う。
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('createEntryDraft');
      await callable.call({
        'tournamentId': _tournamentId,
        'teamName': teamName,
        'memberUids': members.keys.toList(),
      });
      if (mounted) Navigator.pop(sheetContext);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('招待を送信しました。メンバー全員が承認するとエントリーが成立します。'),
            backgroundColor: AppTheme.success,
          ),
        );
        setState(() {});
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'エントリーに失敗しました'), backgroundColor: AppTheme.error),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エントリーに失敗しました'), backgroundColor: AppTheme.error),
        );
      }
    }
  }
  // ━━━ 下部ボタン ━━━

  Widget _buildOrganizerOnlyBottom(Map<String, dynamic> t) {
    final status = normalizeTournamentStatus(t['status'] ?? '', emptyAsPreparing: false);
    final isRecruiting = status == '募集中' || status == '満員';
    final notEntered = _myEntryTeamId.isEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -2))],
      ),
      child: isRecruiting && notEntered
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: AppTheme.warning.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 16, color: AppTheme.warning),
                  const SizedBox(width: 8),
                  Expanded(child: Text('まだエントリーしていません', style: TextStyle(fontSize: 13, color: AppTheme.warning, fontWeight: FontWeight.w600))),
                ]),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _showEntrySheet(context),
                    icon: const Icon(Icons.how_to_reg, size: 18),
                    label: const Text('エントリー', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.success, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showOrganizerMenuSheet(t),
                    icon: const Icon(Icons.admin_panel_settings, size: 18),
                    label: const Text('大会主催者メニュー', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryColor,
                      side: const BorderSide(color: AppTheme.primaryColor, width: 2),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ]),
            ])
          : Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _showOrganizerMenuSheet(t),
                  icon: const Icon(Icons.admin_panel_settings, size: 18),
                  label: const Text('大会主催者メニュー', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              _buildNextStepButton(t),
            ]),
    );
  }

  Widget _buildNextStepButton(Map<String, dynamic> t) {
    final rules = t['rules'] as Map<String, dynamic>? ?? {};
    final preliminary = rules['preliminary'] as Map<String, dynamic>? ?? {};
    final prelimRounds = (preliminary['rounds'] as num?)?.toInt() ?? 1;
    final finalEnabled = (rules['final'] as Map<String, dynamic>?)?['enabled'] ?? true;

    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId)
          .collection('rounds').snapshots(),
      builder: (context, roundsSnap) {
        final roundDocs = roundsSnap.data?.docs ?? [];
        final existingRoundNumbers = roundDocs.map((d) => (d.data() as Map<String, dynamic>)['roundNumber'] ?? 1).toSet();
        final hasRound1 = existingRoundNumbers.contains(1);
        final hasRound2 = existingRoundNumbers.contains(2);
        final lastRoundNum = hasRound2 ? 2 : (hasRound1 ? 1 : 0);

        if (lastRoundNum == 0) return const SizedBox();

        return StreamBuilder<QuerySnapshot>(
          stream: _firestore.collection('tournaments').doc(_tournamentId)
              .collection('rounds').doc('round_$lastRoundNum').collection('matches').snapshots(),
          builder: (context, matchesSnap) {
            final matchDocs = matchesSnap.data?.docs ?? [];
            final allCompleted = matchDocs.isNotEmpty &&
                matchDocs.every((d) => (d.data() as Map<String, dynamic>)['status'] == 'completed');

            if (!allCompleted) return const SizedBox();

            return StreamBuilder<QuerySnapshot>(
              stream: _firestore.collection('tournaments').doc(_tournamentId)
                  .collection('brackets').snapshots(),
              builder: (context, bracketsSnap) {
                final hasBrackets = bracketsSnap.hasData && bracketsSnap.data!.docs.isNotEmpty;

                final showRound2 = prelimRounds >= 2 && hasRound1 && !hasRound2 && lastRoundNum == 1;
                final showFinals = finalEnabled && !hasBrackets &&
                    (prelimRounds == 1 ? hasRound1 : (hasRound1 && hasRound2)) &&
                    lastRoundNum == (prelimRounds == 1 ? 1 : 2);

                if (!showRound2 && !showFinals) return const SizedBox();

                final label = showRound2 ? '予選2 対戦表作成' : '順位決定戦\n対戦表作成';
                final icon = showRound2 ? Icons.replay : Icons.emoji_events;

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: ElevatedButton.icon(
                      onPressed: () => showRound2 ? _generateMatches(2) : _generateFinals(),
                      icon: Icon(icon, size: 18),
                      label: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber, foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ━━━ 受付メニュー ━━━
  void _showReceptionMenuSheet(Map<String, dynamic> tournData) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.how_to_reg, size: 22, color: AppTheme.success),
              ),
              const SizedBox(width: 12),
              const Expanded(child: Text('受付メニュー', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Divider(color: Colors.grey[200]),
          ),
          // 受付状況サマリー
          StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('tournaments').doc(_tournamentId).collection('entries').snapshots(),
            builder: (_, entriesSnap) {
              return StreamBuilder<QuerySnapshot>(
                stream: _firestore.collection('tournaments').doc(_tournamentId).collection('checkIns').snapshots(),
                builder: (_, checkInSnap) {
                  final total = entriesSnap.data?.docs.length ?? 0;
                  final checked = checkInSnap.data?.docs.length ?? 0;
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        SizedBox(
                          width: 44, height: 44,
                          child: CircularProgressIndicator(
                            value: total > 0 ? checked / total : 0,
                            strokeWidth: 5,
                            backgroundColor: Colors.grey[200],
                            valueColor: AlwaysStoppedAnimation<Color>(checked >= total && total > 0 ? AppTheme.success : AppTheme.primaryColor),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('$checked / $total チーム到着', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          Text(checked >= total && total > 0 ? '全チーム到着済み' : '受付中...', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        ]),
                      ]),
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 4),
          _menuTile(ctx, Icons.qr_code, '大会QRコードを表示', 'スマホ・PC・タブレットで表示、または印刷', () {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => CheckInScreen(tournamentId: _tournamentId, tournamentName: tournData['title'] ?? '')));
          }, color: AppTheme.primaryColor),
          _menuTile(ctx, Icons.checklist, '手動チェックイン', 'リストからチームを手動でチェックイン', () {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => CheckInScreen(tournamentId: _tournamentId, tournamentName: tournData['title'] ?? '', initialTab: 1)));
          }, color: AppTheme.success),
          _menuTile(ctx, Icons.payment, '参加費の確認', '各チームの入金状況を確認', () {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => TournamentFinanceScreen(tournamentId: _tournamentId, tournamentData: tournData)));
          }, color: AppTheme.accentColor),
        ]),
      ),
    );
  }

  void _showOrganizerMenuSheet(Map<String, dynamic> tournData) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _OrganizerMenuScreen(
        tournData: tournData,
        tournamentId: _tournamentId,
        onEditTournament: (ctx) => _showEditTournamentSheet(tournData, ctx),
        onSelfEntry: () => _showEntrySheet(context),
        onRecruit: () => _showRecruitSheet(context),
        onCheckIn: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CheckInScreen(tournamentId: _tournamentId, tournamentName: tournData['title'] ?? ''))),
        onCsvMenu: _showCsvImportMenu,
        onDeleteTeams: _deleteEntryTeams,
        onFinance: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TournamentFinanceScreen(tournamentId: _tournamentId, tournamentData: tournData))),
        onGenerateRound1: () => _generateMatches(1),
        onGenerateRound2: () => _generateMatches(2),
        onGenerateFinals: _generateFinals,
        onReset: _showResetMenu,
        onEndTournament: _showEndTournamentDialog,
        onSaveTemplate: () => _saveAsTemplate(tournData),
        onDelete: () => _showDeleteDialog(tournData['title'] ?? ''),
        onUpdateBracketCourts: _updateBracketCourtsAndReferees,
      ),
    ));
  }

  Widget _sectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary, letterSpacing: 0.5)),
    );
  }

  Widget _menuTile(BuildContext ctx, IconData icon, String title, String subtitle, VoidCallback onTap, {Color color = AppTheme.primaryColor, bool isDestructive = false}) {
    final c = isDestructive ? AppTheme.error : color;
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: c),
      ),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDestructive ? AppTheme.error : AppTheme.textPrimary)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      trailing: Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
      onTap: () { Navigator.pop(ctx); onTap(); },
    );
  }

  bool _isTournamentToday() {
    try {
      final dateStr = widget.tournament['date'] as String? ?? '';
      final parts = dateStr.split('/');
      if (parts.length == 3) {
        final d = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        return d == today;
      }
    } catch (_) {}
    return false;
  }

  void _showCheckInOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 20),
            const Text('チェックイン', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '会場に掲示されている大会のQRコードを、この端末でスキャンしてください。\n主催者が手動で登録した場合は不要です。',
              style: TextStyle(fontSize: 13, height: 1.45, color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Web版ではカメラスキャンを利用できません。スマホアプリで同じ大会を開くか、主催者に手動登録を依頼してください。',
                  style: TextStyle(fontSize: 13, height: 1.45, color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final tid = await Navigator.push<String?>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TournamentCheckinScanScreen(expectedTournamentId: _tournamentId),
                      ),
                    );
                    if (tid != null && mounted) {
                      await _performSelfCheckIn();
                    }
                  },
                  icon: const Icon(Icons.qr_code_scanner, size: 22),
                  label: const Text('大会QRをスキャン', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomButtons() {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('tournaments').doc(_tournamentId).snapshots(),
      builder: (context, snap) {
        final live = (snap.hasData && snap.data!.exists) ? snap.data!.data() as Map<String, dynamic>? ?? {} : <String, dynamic>{};
        final t = live.isNotEmpty ? live : widget.tournament;
        final status = normalizeTournamentStatus(t['status'] ?? '準備中');
        final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
        final isOrganizer = _canManageTournament(t);

        // 主催者の場合
        if (isOrganizer) {
          if (status != '開催中') {
            // 当日（開催中）以外 → 主催者メニューのみ
            return _buildOrganizerOnlyBottom(t);
          }
          // 当日（開催中） → チェックイン状況を確認して受付メニュー＋主催者メニュー
          return StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('tournaments').doc(_tournamentId).collection('entries').snapshots(),
            builder: (context, entriesSnap) {
              return StreamBuilder<QuerySnapshot>(
                stream: _firestore.collection('tournaments').doc(_tournamentId).collection('checkIns').snapshots(),
                builder: (context, checkInSnap) {
                  final totalEntries = entriesSnap.data?.docs.length ?? 0;
                  final checkedIn = checkInSnap.data?.docs.length ?? 0;
                  final allCheckedIn = totalEntries > 0 && checkedIn >= totalEntries;

                  if (allCheckedIn) {
                    // 全チーム受付完了 → 主催者メニューのみ
                    return _buildOrganizerOnlyBottom(t);
                  }

                  // 受付中 → 受付メニュー＋主催者メニューの2ボタン
                  return Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -2))],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // 受付状況バー
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                        child: Row(children: [
                          Icon(Icons.how_to_reg, size: 16, color: AppTheme.success),
                          const SizedBox(width: 8),
                          Text('受付状況: $checkedIn/$totalEntries チーム', style: TextStyle(fontSize: 13, color: AppTheme.success, fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Text('${totalEntries > 0 ? (checkedIn * 100 ~/ totalEntries) : 0}%', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.success)),
                        ]),
                      ),
                      const SizedBox(height: 10),
                      // 2ボタン
                      Row(children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _showReceptionMenuSheet(t),
                            icon: const Icon(Icons.how_to_reg, size: 18),
                            label: const Text('受付メニュー', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.success, foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _showOrganizerMenuSheet(t),
                            icon: const Icon(Icons.admin_panel_settings, size: 18),
                            label: const Text('大会主催者メニュー', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primaryColor,
                              side: const BorderSide(color: AppTheme.primaryColor, width: 2),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ]),
                    ]),
                  );
                },
              );
            },
          );
        }

        final isEnded = status == '開催済み' || status == '開催中' || status == '決勝中' || status == '順位決定中' || status == '終了' || status.contains('完了');
        if (isEnded) return const SizedBox.shrink();

        // 大会当日 & エントリー済み → 自チームのチェックイン完了まで表示
        if (_isTournamentToday() && _myEntryTeamId.isNotEmpty) {
          return StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('tournaments').doc(_tournamentId).collection('checkIns').snapshots(),
            builder: (context, checkInSnap) {
              final checkInDocs = checkInSnap.data?.docs ?? [];
              final myTeamCheckedIn = checkInDocs.any((d) {
                final data = d.data() as Map<String, dynamic>;
                return data['teamId'] == _myEntryTeamId;
              });
              // 自チームのチェックイン完了 → ボタン非表示
              if (myTeamCheckedIn) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -2))],
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _showCheckInOptions,
                    icon: const Icon(Icons.check_circle_outline, size: 20),
                    label: const Text('チェックイン', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.success,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              );
            },
          );
        }

        final maxTeams = t['maxTeams'] is int ? t['maxTeams'] as int : 0;

        // entriesの実数で満員判定
        return StreamBuilder<QuerySnapshot>(
          stream: _firestore.collection('tournaments').doc(_tournamentId).collection('entries').snapshots(),
          builder: (context, entriesSnap) {
            final entryCount = entriesSnap.data?.docs.length ?? 0;
            final isFull = maxTeams > 0 && entryCount >= maxTeams;

        // 満員の場合はキャンセル待ちUI表示
        if (isFull || status == '満員') {
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -2))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.info_outline, size: 16, color: AppTheme.warning),
                    const SizedBox(width: 8),
                    Text('現在満員です ($entryCount/$maxTeamsチーム)', style: TextStyle(fontSize: 13, color: AppTheme.warning, fontWeight: FontWeight.w600)),
                  ]),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _showWaitlistSheet(context),
                    icon: const Icon(Icons.hourglass_empty, size: 18),
                    label: const Text('キャンセル待ちに登録', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.warning,
                      side: const BorderSide(color: AppTheme.warning, width: 2),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final isDisabled = false;
        final officialSpectator = _viewerIsOfficial == true;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -2))],
          ),
          child: officialSpectator
              ? Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isDisabled ? null : () => _showRecruitSheet(context),
                        icon: const Icon(Icons.person_add, size: 18),
                        label: const Text('メンバー募集する', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryColor,
                          side: const BorderSide(color: AppTheme.primaryColor, width: 2),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: isDisabled
                            ? null
                            : () async {
                                final ok = await _ensureFollowingForEntry();
                                if (!mounted) return;
                                if (ok) {
                                  _showEntrySheet(context);
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('主催者をフォローできなかったためエントリーできませんでした'),
                                      backgroundColor: AppTheme.warning,
                                    ),
                                  );
                                }
                              },
                        icon: const Icon(Icons.how_to_reg, size: 18),
                        label: Text(
                          isDisabled ? (status == '満員' ? '満員です' : '開催済み') : 'エントリー',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          disabledBackgroundColor: Colors.grey[300],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                )
              : _isFollowing
                  ? Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: isDisabled ? null : () => _showRecruitSheet(context),
                            icon: const Icon(Icons.person_add, size: 18),
                            label: const Text('メンバー募集する', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primaryColor,
                              side: const BorderSide(color: AppTheme.primaryColor, width: 2),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: isDisabled ? null : () => _showEntrySheet(context),
                            icon: const Icon(Icons.how_to_reg, size: 18),
                            label: Text(
                              isDisabled ? (status == '満員' ? '満員です' : '開催済み') : 'エントリー',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryColor,
                              disabledBackgroundColor: Colors.grey[300],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    )
                  : SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          await _followOrganizer();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('大会主催者をフォローしました！エントリーできます'), backgroundColor: AppTheme.success),
                            );
                          }
                        },
                        icon: const Icon(Icons.person_add, size: 18),
                        label: const Text('フォローしてエントリー', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
        );
          },
        );
      },
    );
  }

  // ━━━ キャンセル待ち ━━━
  void _showWaitlistSheet(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    final teamNameCtrl = TextEditingController();

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (ctx) {
        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () {
              if (teamNameCtrl.text.trim().isNotEmpty) {
                showDialog(context: ctx, builder: (c) => AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: const Text('入力内容を破棄しますか？'),
                  content: const Text('入力した内容は保存されません。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('キャンセル')),
                    TextButton(onPressed: () { Navigator.pop(c); Navigator.pop(ctx); }, child: const Text('破棄する', style: TextStyle(color: Colors.red))),
                  ],
                ));
              } else {
                Navigator.pop(ctx);
              }
            }),
            title: const Text('補欠エントリー', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            centerTitle: true,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.warning.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.warning.withValues(alpha: 0.2)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((widget.tournament['name'] ?? widget.tournament['title'] ?? '') as String,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                const SizedBox(height: 4),
                Text('空きが出た場合に通知が届きます', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ]),
            ),
            const SizedBox(height: 20),
            const Text('チーム名', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: teamNameCtrl,
              decoration: InputDecoration(
                hintText: 'チーム名を入力',
                filled: true, fillColor: AppTheme.backgroundColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
            const SizedBox(height: 24),

            // 現在のキャンセル待ち状況
            StreamBuilder<QuerySnapshot>(
              stream: _firestore.collection('tournaments').doc(_tournamentId)
                  .collection('waitlist').orderBy('createdAt').snapshots(),
              builder: (context, snap) {
                final waitlist = snap.data?.docs ?? [];
                final alreadyWaiting = waitlist.any((d) => (d.data() as Map<String, dynamic>)['userId'] == uid);
                if (alreadyWaiting) {
                  final myPosition = waitlist.indexWhere((d) => (d.data() as Map<String, dynamic>)['userId'] == uid) + 1;
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(children: [
                      Icon(Icons.check_circle, color: AppTheme.success, size: 32),
                      const SizedBox(height: 8),
                      Text('キャンセル待ち登録済み', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.success)),
                      const SizedBox(height: 4),
                      Text('現在$myPosition番目 / ${waitlist.length}人待ち', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () async {
                            final myDoc = waitlist.firstWhere((d) => (d.data() as Map<String, dynamic>)['userId'] == uid);
                            await _firestore.collection('tournaments').doc(_tournamentId)
                                .collection('waitlist').doc(myDoc.id).delete();
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('キャンセル待ちを取り消しました'), backgroundColor: AppTheme.warning),
                              );
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.error,
                            side: const BorderSide(color: AppTheme.error),
                          ),
                          child: const Text('キャンセル待ちを取り消す'),
                        ),
                      ),
                    ]),
                  );
                }

                return Column(children: [
                  if (waitlist.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('現在${waitlist.length}チームがキャンセル待ち中', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final teamName = teamNameCtrl.text.trim();
                        if (teamName.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('チーム名を入力してください'), backgroundColor: AppTheme.warning),
                          );
                          return;
                        }

                        final userDoc = await _firestore.collection('users').doc(uid).get();
                        final nickname = userDoc.data()?['nickname'] ?? '名前なし';

                        await _firestore.collection('tournaments').doc(_tournamentId)
                            .collection('waitlist').add({
                          'userId': uid,
                          'userName': nickname,
                          'teamName': teamName,
                          'createdAt': FieldValue.serverTimestamp(),
                        });

                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('キャンセル待ちに登録しました（${waitlist.length + 1}番目）'),
                              backgroundColor: AppTheme.success,
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.hourglass_empty, size: 18),
                      label: const Text('キャンセル待ちに登録', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.warning,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ]);
              },
            ),
            const SizedBox(height: 8),
          ]),
          ),
        );
      },
    ));
  }

  // ━━━ メンバー募集（全画面ダイアログ） ━━━
  void _showRecruitSheet(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) => _RecruitFullScreen(
        tournamentId: _tournamentId,
        tournament: widget.tournament,
        firestore: _firestore,
      ),
    ));
  }

  // ━━━ シェアシート ━━━
  String _buildShareUrl() {
    // Uri.base.origin はネイティブ（file:// スキーム）で例外を投げ、共有ボタンが
    // 無反応になる。ドメイン統一済みの sofvo.com を直接使う。
    return 'https://sofvo.com/?t=$_tournamentId';
  }

  void _showShareOptions(BuildContext context) {
    final tournamentName = (widget.tournament['name'] ?? widget.tournament['title'] ?? '') as String;
    final canManage = _canManageTournament(widget.tournament);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            const Text('\u5927\u4f1a\u3092\u30b7\u30a7\u30a2', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _buildShareOption(
                icon: Icons.chat_bubble,
                label: 'LINE',
                color: const Color(0xFF06C755),
                onTap: () async {
                  Navigator.pop(ctx);
                  final url = _buildShareUrl();
                  final text = Uri.encodeComponent('$tournamentName\n$url');
                  final lineUrl = 'https://line.me/R/share?text=$text';
                  final uri = Uri.parse(lineUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
              _buildShareOption(
                icon: Icons.link,
                label: 'URL\u30b3\u30d4\u30fc',
                color: AppTheme.primaryColor,
                onTap: () {
                  Navigator.pop(ctx);
                  final url = _buildShareUrl();
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('URL\u3092\u30b3\u30d4\u30fc\u3057\u307e\u3057\u305f'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                },
              ),
            ]),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                canManage ? '\u62db\u5f85\u3057\u3066\u767b\u9332\u30fb\u53c2\u52a0\u3057\u3066\u3082\u3089\u3046' : '\u30e1\u30f3\u30d0\u30fc\u3092\u62db\u5f85\u3059\u308b',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 10),
            // \u5927\u4f1a\u904b\u55b6\u8005\uff1a\u30ad\u30e3\u30d7\u30c6\u30f3\u62db\u5f85\uff08\u5927\u4f1a\u30a8\u30f3\u30c8\u30ea\u30fc\u3078\u8a98\u5c0e\uff09
            if (canManage) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showInviteShareSheet(
                      context,
                      tournamentId: _tournamentId,
                      tournamentName: tournamentName,
                      title: '\u30ad\u30e3\u30d7\u30c6\u30f3\u3092\u62db\u5f85',
                      description: '\u3053\u306e\u5927\u4f1a\u306b\u51fa\u5834\u3059\u308b\u30c1\u30fc\u30e0\u306e\u30ad\u30e3\u30d7\u30c6\u30f3\u3092\u62db\u5f85\u3057\u307e\u3059\u3002\u30ea\u30f3\u30af\u3068\u30b3\u30fc\u30c9\u3092\u9001\u308b\u3068\u3001\u76f8\u624b\u306f\u767b\u9332\u5f8c\u306b\u3053\u306e\u5927\u4f1a\u3078\u6848\u5185\u3055\u308c\u3001\u30c1\u30fc\u30e0\u3067\u30a8\u30f3\u30c8\u30ea\u30fc\u3067\u304d\u307e\u3059\u3002',
                    );
                  },
                  icon: const Icon(Icons.shield_outlined, size: 20),
                  label: const Text('\u30ad\u30e3\u30d7\u30c6\u30f3\u3092\u62db\u5f85', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryColor,
                    side: const BorderSide(color: AppTheme.primaryColor),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            // \u30ad\u30e3\u30d7\u30c6\u30f3\uff0f\u53c2\u52a0\u8005\uff1a\u30e1\u30f3\u30d0\u30fc\u62db\u5f85
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  showInviteShareSheet(
                    context,
                    tournamentId: _tournamentId,
                    tournamentName: tournamentName,
                    title: '\u30e1\u30f3\u30d0\u30fc\u3092\u62db\u5f85',
                    description: '\u4e00\u7dd2\u306b\u51fa\u308b\u30e1\u30f3\u30d0\u30fc\u3092\u62db\u5f85\u3057\u307e\u3059\u3002\u30ea\u30f3\u30af\u3068\u30b3\u30fc\u30c9\u3092\u9001\u308b\u3068\u3001\u76f8\u624b\u306f\u767b\u9332\u5f8c\u306b\u3053\u306e\u5927\u4f1a\u3078\u6848\u5185\u3055\u308c\u3001\u30d5\u30a9\u30ed\u30fc\u4e2d\u306b\u4e26\u3093\u3067\u30e1\u30f3\u30d0\u30fc\u3068\u3057\u3066\u9078\u3079\u308b\u3088\u3046\u306b\u306a\u308a\u307e\u3059\u3002',
                  );
                },
                icon: const Icon(Icons.person_add_alt, size: 20),
                label: const Text('\u30e1\u30f3\u30d0\u30fc\u3092\u62db\u5f85', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryColor,
                  side: const BorderSide(color: AppTheme.primaryColor),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _openSummaryDownload() {
    final tournamentName = (widget.tournament['name'] ?? widget.tournament['title'] ?? '大会').toString();
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => TournamentSummaryDownloadScreen(tournamentId: _tournamentId, tournamentName: tournamentName),
    ));
  }

  Widget _buildShareOption({required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(width: 56, height: 56,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, color: color, size: 28)),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(fontSize: 12, color: AppTheme.textPrimary, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  // ━━━ 共通ウィジェット ━━━
  /// 閲覧数カード（主催者のみ表示）。延べアクセス数とユニーク閲覧者数を表示する。
  Widget _buildViewStatsCard() {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore
          .collection('tournaments')
          .doc(_tournamentId)
          .collection('stats')
          .doc('summary')
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() as Map<String, dynamic>? ?? {};
        final viewCount = (data['viewCount'] as num?)?.toInt() ?? 0;
        final uniqueViewCount = (data['uniqueViewCount'] as num?)?.toInt() ?? 0;
        return _buildCard(
          title: '閲覧数',
          titleIcon: Icons.visibility_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _buildViewStatItem(
                      icon: Icons.person_outline,
                      label: '閲覧した人数',
                      value: '$uniqueViewCount',
                      unit: '人',
                    ),
                  ),
                  Container(width: 1, height: 44, color: Colors.grey[200]),
                  Expanded(
                    child: _buildViewStatItem(
                      icon: Icons.bar_chart,
                      label: '延べアクセス数',
                      value: '$viewCount',
                      unit: '回',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '主催者にのみ表示されます',
                style: TextStyle(fontSize: 11, color: AppTheme.textHint),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildViewStatItem({
    required IconData icon,
    required String label,
    required String value,
    required String unit,
  }) {
    return Column(
      children: [
        Icon(icon, size: 20, color: AppTheme.primaryColor),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary)),
            const SizedBox(width: 2),
            Text(unit,
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
        ),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ],
    );
  }

  Widget _buildCard({String? title, IconData? titleIcon, required Widget child}) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null) ...[
          Row(children: [
            if (titleIcon != null) ...[
              Icon(titleIcon, size: 18, color: AppTheme.primaryColor),
              const SizedBox(width: 8),
            ],
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
          ]),
          const SizedBox(height: 12),
        ],
        child,
      ]),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: AppTheme.primaryColor),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary, fontWeight: FontWeight.w500)),
        ])),
      ]),
    );
  }

  Widget _buildAddressRow(String address) {
    return GestureDetector(
      onTap: () {
        final encoded = Uri.encodeComponent(address);
        final uri = Uri.parse('https://www.google.com/maps/search/$encoded');
        launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.map, size: 16, color: AppTheme.primaryColor),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('住所', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 2),
            Text(address, style: const TextStyle(fontSize: 14, color: AppTheme.primaryColor, fontWeight: FontWeight.w500, decoration: TextDecoration.underline)),
          ])),
          const Icon(Icons.open_in_new, size: 14, color: AppTheme.primaryColor),
        ]),
      ),
    );
  }

  Widget _buildDivider() => Divider(height: 1, color: Colors.grey[100]);

  Widget _heroChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: Colors.white70),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
      ]),
    );
  }

  Widget _buildTimelineRow(String rawTime, String label, IconData icon, {bool isLast = false}) {
    // 09:00 → 9:00 表示用（先頭ゼロ除去）
    final time = rawTime.trim().startsWith('0') ? rawTime.trim().substring(1) : rawTime.trim();
    const double dotSize = 10;
    const double rowMinHeight = 36;
    return IntrinsicHeight(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: rowMinHeight),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 時刻（ドットと中央揃え）
            SizedBox(
              width: 56,
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(time, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                ),
              ),
            ),
            // タイムライン（ドット＋縦線）
            SizedBox(
              width: dotSize,
              child: Column(children: [
                const SizedBox(height: 6),
                Container(
                  width: dotSize, height: dotSize,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3), width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(child: Container(width: 2, color: AppTheme.primaryColor.withValues(alpha: 0.15))),
              ]),
            ),
            const SizedBox(width: 12),
            // ラベル
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(icon, size: 16, color: AppTheme.textSecondary),
                    ),
                    const SizedBox(width: 6),
                    Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPointTableRow(IconData icon, String label, String points, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
          Text(points, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildDetailInfoRow(IconData icon, String label, String value, {String? subtitle, VoidCallback? onSubtitleTap, Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: valueColor ?? AppTheme.textPrimary)),
                if (subtitle != null)
                  GestureDetector(
                    onTap: onSubtitleTap,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(child: Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.primaryColor, decoration: onSubtitleTap != null ? TextDecoration.underline : null))),
                        if (onSubtitleTap != null) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.open_in_new, size: 12, color: AppTheme.primaryColor),
                        ],
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleSectionCard(String title, IconData icon, Color color, List<Widget> rows) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(children: [
        // ヘッダー
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
          ),
          child: Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
        // テーブル行
        ...rows,
      ]),
    );
  }

  Widget _buildRuleTableRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey[100]!)),
      ),
      child: Row(children: [
        SizedBox(
          width: 90,
          child: Text(label, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
      ]),
    );
  }

  Widget _buildTierInfoRow(int tierCount, int maxTeams) {
    final shortNames = _getTierDisplayNames(tierCount);
    final fullNames = _getTierFullNames(tierCount);
    final teamsPerTier = maxTeams > 0 ? (maxTeams / tierCount).ceil() : 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey[100]!)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('区分', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          ...List.generate(shortNames.length, (i) {
            final rankStart = i * teamsPerTier + 1;
            final rankEnd = ((i + 1) * teamsPerTier).clamp(1, maxTeams > 0 ? maxTeams : (i + 1) * teamsPerTier);
            final rankText = maxTeams > 0 ? '（予選$rankStart〜$rankEnd位）' : '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _tierColor(i, shortNames.length).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Center(
                      child: Text(shortNames[i],
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _tierColor(i, shortNames.length)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${fullNames[i]}$rankText',
                      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    ),
                  ),
                ],
              ),
            );
          }),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '予選リーグの順位をもとに$tierCount区分に分かれてトーナメント戦を行います',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// ルール設定用の短い名前（上/中/下）
  List<String> _getTierDisplayNames(int count) {
    switch (count) {
      case 1: return ['リーグ'];
      case 2: return ['上', '下'];
      case 3: return ['上', '中', '下'];
      case 4: return ['上', '中①', '中②', '下'];
      default:
        final names = <String>['上'];
        for (int i = 1; i < count - 1; i++) {
          names.add('中${count > 3 ? "①②③④⑤⑥⑦⑧"[i - 1] : ""}');
        }
        names.add('下');
        return names;
    }
  }

  /// 旧名称（上/中/下）をフルネームに変換
  /// 自分のチームがこのブラケットに属しているか判定
  bool _isMyBracket(Map<String, dynamic> bData) {
    final teamIds = List<String>.from(bData['teamIds'] ?? []);
    return _myTeamIds.any((tid) => teamIds.contains(tid));
  }

  String _toFullLeagueName(String name) {
    const map = {
      '上': '上位リーグ', '中': '中位リーグ', '下': '下位リーグ',
      '中①': '中位①リーグ', '中②': '中位②リーグ',
    };
    return map[name] ?? name;
  }

  /// 未確定チーム名のプレースホルダーをわかりやすい表記に変換
  String _friendlyPlaceholder(String name) {
    // 既に「第X試合」形式ならそのまま返す
    if (RegExp(r'^第\d+試合').hasMatch(name)) return name;
    // QF①勝者 or QF1勝者 → 第X試合 勝者
    final qfMatch = RegExp(r'^QF([①②③④1-4])(.+)$').firstMatch(name);
    if (qfMatch != null) {
      const numMap = {'①': '1', '②': '2', '③': '3', '④': '4'};
      final num = numMap[qfMatch.group(1)] ?? qfMatch.group(1)!;
      return '第${num}試合 ${qfMatch.group(2)}';
    }
    // SF1勝者 or SF①勝者 (4チームSE / 5-7チーム)
    final sfMatch = RegExp(r'^SF([①②1-2])(.+)$').firstMatch(name);
    if (sfMatch != null) {
      const numMap = {'①': '1', '②': '2'};
      final num = numMap[sfMatch.group(1)] ?? sfMatch.group(1)!;
      return '第${num}試合 ${sfMatch.group(2)}';
    }
    return name;
  }

  /// 表示用のフルネーム（上位リーグ/中位リーグ/下位リーグ）
  List<String> _getTierFullNames(int count) {
    switch (count) {
      case 1: return ['リーグ'];
      case 2: return ['上位リーグ', '下位リーグ'];
      case 3: return ['上位リーグ', '中位リーグ', '下位リーグ'];
      case 4: return ['上位リーグ', '中位①リーグ', '中位②リーグ', '下位リーグ'];
      default:
        final names = <String>['上位リーグ'];
        for (int i = 1; i < count - 1; i++) {
          names.add('中位${count > 3 ? "①②③④⑤⑥⑦⑧"[i - 1] : ""}リーグ');
        }
        names.add('下位リーグ');
        return names;
    }
  }

  Color _tierColor(int index, int total) {
    if (index == 0) return Colors.amber[700]!;
    if (index == total - 1) return AppTheme.primaryColor;
    return AppTheme.accentColor;
  }

  Widget _buildScoringTable(Map<String, dynamic> prelim, Map<String, dynamic> scoring) {
    final rounds = prelim['rounds'] ?? 1;
    final hasRound2 = rounds == 2 && scoring['round2'] != null;
    // 2ラウンド形式: scoring内もround1/round2に分かれている
    final s1 = hasRound2 ? (scoring['round1'] as Map<String, dynamic>? ?? scoring) : scoring;
    final s2 = hasRound2 ? (scoring['round2'] as Map<String, dynamic>?) : null;
    // sets も round1 キーから取得
    final r1Data = rounds == 2 ? (prelim['round1'] as Map<String, dynamic>? ?? {}) : prelim;
    final sets = r1Data['sets'] ?? 2;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.2)),
      ),
      child: Column(children: [
        // ヘッダー
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.accentColor.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
          ),
          child: Row(children: [
            Icon(Icons.emoji_events, size: 16, color: AppTheme.accentColor),
            const SizedBox(width: 6),
            Text('勝ち点制', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
          ]),
        ),
        // テーブルヘッダー
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: Colors.grey[50]),
          child: Row(children: [
            Expanded(flex: 3, child: Text('結果', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
            if (hasRound2) ...[
              Expanded(flex: 2, child: Text('R1', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
              Expanded(flex: 2, child: Text('R2', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
            ] else
              Expanded(flex: 2, child: Text('勝ち点', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
          ]),
        ),
        ..._buildScoringTableRows(sets, s1, s2),
      ]),
    );
  }

  List<Widget> _buildScoringTableRows(int sets, Map<String, dynamic> s1, Map<String, dynamic>? s2) {
    final entries = _scoringEntries(sets, s1, s2);
    return entries.asMap().entries.map((e) {
      final idx = e.key;
      final row = e.value;
      final isWin = row['label'].toString().contains('勝');
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: idx.isEven ? Colors.white : Colors.grey[50],
          border: Border(bottom: BorderSide(color: Colors.grey[100]!)),
          borderRadius: idx == entries.length - 1 ? const BorderRadius.vertical(bottom: Radius.circular(9)) : null,
        ),
        child: Row(children: [
          Container(
            width: 8, height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: isWin ? AppTheme.success : AppTheme.error.withValues(alpha: 0.6),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(flex: 3, child: Text(row['label'] as String, style: TextStyle(fontSize: 13, color: AppTheme.textPrimary, fontWeight: isWin ? FontWeight.w600 : FontWeight.normal))),
          if (s2 != null) ...[
            Expanded(flex: 2, child: Text('${row['pts1']}点', textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary))),
            Expanded(flex: 2, child: Text('${row['pts2']}点', textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary))),
          ] else
            Expanded(flex: 2, child: Text('${row['pts1']}点', textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary))),
        ]),
      );
    }).toList();
  }

  List<Map<String, dynamic>> _scoringEntries(int sets, Map<String, dynamic> s1, Map<String, dynamic>? s2) {
    switch (sets) {
      case 1:
        return [
          {'label': '勝利', 'pts1': s1['win'] ?? 3, 'pts2': s2?['win'] ?? s1['win'] ?? 3},
          {'label': '敗北', 'pts1': s1['lose'] ?? 0, 'pts2': s2?['lose'] ?? s1['lose'] ?? 0},
        ];
      case 3:
        return [
          {'label': '2-0 勝ち', 'pts1': s1['win20'] ?? 10, 'pts2': s2?['win20'] ?? s1['win20'] ?? 10},
          {'label': '2-1 勝ち', 'pts1': s1['win21'] ?? 7, 'pts2': s2?['win21'] ?? s1['win21'] ?? 7},
          {'label': '1-2 負け', 'pts1': s1['lose12'] ?? 2, 'pts2': s2?['lose12'] ?? s1['lose12'] ?? 2},
          {'label': '0-2 負け', 'pts1': s1['lose02'] ?? 0, 'pts2': s2?['lose02'] ?? s1['lose02'] ?? 0},
        ];
      default:
        return [
          {'label': '2-0 勝ち', 'pts1': s1['win20'] ?? 10, 'pts2': s2?['win20'] ?? s1['win20'] ?? 10},
          {'label': '1-1 得失差勝ち', 'pts1': s1['win11'] ?? 7, 'pts2': s2?['win11'] ?? s1['win11'] ?? 7},
          {'label': '1-1 引き分け', 'pts1': s1['draw'] ?? 4, 'pts2': s2?['draw'] ?? s1['draw'] ?? 4},
          {'label': '1-1 得失差負け', 'pts1': s1['lose11'] ?? 2, 'pts2': s2?['lose11'] ?? s1['lose11'] ?? 2},
          {'label': '0-2 負け', 'pts1': s1['lose02'] ?? 0, 'pts2': s2?['lose02'] ?? s1['lose02'] ?? 0},
        ];
    }
  }
}

// ━━━ 全予選合計の順位表ウィジェット ━━━
class _OverallStandingsAggregator extends StatefulWidget {
  final String tournamentId;
  final String tournamentName;
  final List<String> roundIds;
  final List<String> myTeamIds;

  const _OverallStandingsAggregator({
    required this.tournamentId,
    required this.tournamentName,
    required this.roundIds,
    required this.myTeamIds,
  });

  @override
  State<_OverallStandingsAggregator> createState() => _OverallStandingsAggregatorState();
}

class _OverallStandingsAggregatorState extends State<_OverallStandingsAggregator> {
  final _firestore = FirebaseFirestore.instance;
  final List<StreamSubscription<QuerySnapshot>> _subs = [];
  StreamSubscription<DocumentSnapshot>? _rulesSub;
  // key: "roundId/courtId" → team list
  final Map<String, List<Map<String, dynamic>>> _data = {};
  bool _loaded = false;
  // Track standing doc listeners per round
  final List<StreamSubscription<QuerySnapshot>> _standingSubs = [];

  // 決勝ルール情報
  int _tierCount = 3;
  String _finalFormat = '順位別複数';
  bool _finalEnabled = false;

  @override
  void initState() {
    super.initState();
    _subscribeRules();
    _subscribeAll();
  }

  @override
  void didUpdateWidget(covariant _OverallStandingsAggregator old) {
    super.didUpdateWidget(old);
    if (old.roundIds.length != widget.roundIds.length ||
        old.roundIds.join(',') != widget.roundIds.join(',')) {
      _cancelAll();
      _subscribeAll();
    }
  }

  void _subscribeRules() {
    _rulesSub = _firestore.collection('tournaments').doc(widget.tournamentId).snapshots().listen((snap) {
      if (!mounted) return;
      final data = snap.data() as Map<String, dynamic>? ?? {};
      final rules = data['rules'] as Map<String, dynamic>? ?? {};
      final finalRules = rules['final'] as Map<String, dynamic>? ?? {};
      setState(() {
        _tierCount = (finalRules['tierCount'] as num?)?.toInt() ?? 3;
        _finalFormat = finalRules['format'] as String? ?? '順位別複数';
        _finalEnabled = finalRules['enabled'] as bool? ?? false;
      });
    });
  }

  void _subscribeAll() {
    _data.clear();
    _loaded = false;
    // For each round, listen to standings collection to discover courts
    for (final roundId in widget.roundIds) {
      final sub = _firestore
          .collection('tournaments').doc(widget.tournamentId)
          .collection('rounds').doc(roundId)
          .collection('standings').snapshots()
          .listen((standingsSnap) {
        if (!mounted) return;
        // Remove old team subs for this round
        _removeSubsForRound(roundId);
        // Subscribe to each court's teams
        for (final courtDoc in standingsSnap.docs) {
          _subscribeCourtTeams(roundId, courtDoc.id);
        }
        if (standingsSnap.docs.isEmpty) {
          setState(() => _loaded = true);
        }
      });
      _standingSubs.add(sub);
    }
  }

  void _subscribeCourtTeams(String roundId, String courtId) {
    final key = '$roundId/$courtId';
    final sub = _firestore
        .collection('tournaments').doc(widget.tournamentId)
        .collection('rounds').doc(roundId)
        .collection('standings').doc(courtId)
        .collection('teams').snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _data[key] = snap.docs.map((d) => Map<String, dynamic>.from(d.data())).toList();
        _loaded = true;
      });
    });
    _subs.add(sub);
  }

  void _removeSubsForRound(String roundId) {
    final keysToRemove = _data.keys.where((k) => k.startsWith('$roundId/')).toList();
    for (final key in keysToRemove) {
      _data.remove(key);
    }
  }

  void _cancelAll() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    for (final sub in _standingSubs) {
      sub.cancel();
    }
    _standingSubs.clear();
    _data.clear();
    _loaded = false;
  }

  @override
  void dispose() {
    _rulesSub?.cancel();
    _cancelAll();
    super.dispose();
  }

  /// リーグ名を返す（match_generator.dart と同じロジック）
  List<String> _getLeagueNames(int count) {
    switch (count) {
      case 1: return ['リーグ'];
      case 2: return ['上位リーグ', '下位リーグ'];
      case 3: return ['上位リーグ', '中位リーグ', '下位リーグ'];
      case 4: return ['上位リーグ', '中位①リーグ', '中位②リーグ', '下位リーグ'];
      default:
        final names = <String>['上位リーグ'];
        for (int i = 1; i < count - 1; i++) {
          names.add('中位${count > 3 ? "①②③④⑤⑥⑦⑧"[i - 1] : ""}リーグ');
        }
        names.add('下位リーグ');
        return names;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(color: AppTheme.primaryColor)));

    // Aggregate: sum matchPoints/pointDiff/totalPoints per teamId across all rounds & courts
    final Map<String, Map<String, dynamic>> merged = {};
    for (final teams in _data.values) {
      for (final t in teams) {
        final teamId = t['teamId'] as String? ?? '';
        if (teamId.isEmpty) continue;
        if (merged.containsKey(teamId)) {
          merged[teamId]!['matchPoints'] = (merged[teamId]!['matchPoints'] as num) + ((t['matchPoints'] ?? 0) as num);
          merged[teamId]!['pointDiff'] = (merged[teamId]!['pointDiff'] as num) + ((t['pointDiff'] ?? 0) as num);
          merged[teamId]!['totalPoints'] = (merged[teamId]!['totalPoints'] as num) + ((t['totalPoints'] ?? 0) as num);
        } else {
          merged[teamId] = {
            'teamId': teamId,
            'teamName': t['teamName'] ?? '',
            'matchPoints': (t['matchPoints'] ?? 0) as num,
            'pointDiff': (t['pointDiff'] ?? 0) as num,
            'totalPoints': (t['totalPoints'] ?? 0) as num,
          };
        }
      }
    }

    final allTeams = merged.values.toList();

    if (allTeams.isEmpty) {
      return const Center(child: Text('まだ試合結果がありません', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)));
    }

    // Sort: matchPoints desc → pointDiff desc → totalPoints desc
    allTeams.sort((a, b) {
      final mp = (b['matchPoints'] as num).compareTo(a['matchPoints'] as num);
      if (mp != 0) return mp;
      final pd = (b['pointDiff'] as num).compareTo(a['pointDiff'] as num);
      if (pd != 0) return pd;
      return (b['totalPoints'] as num).compareTo(a['totalPoints'] as num);
    });

    // 同順位の計算（境界調整に使用）
    final ranks = <int>[];
    for (int i = 0; i < allTeams.length; i++) {
      if (i == 0) {
        ranks.add(1);
      } else {
        final prev = allTeams[i - 1];
        final curr = allTeams[i];
        if (curr['matchPoints'] == prev['matchPoints'] &&
            curr['pointDiff'] == prev['pointDiff'] &&
            curr['totalPoints'] == prev['totalPoints']) {
          ranks.add(ranks[i - 1]); // 同順位
        } else {
          ranks.add(i + 1);
        }
      }
    }

    // 区分境界を計算（均等分割、同順位チームには注記表示）
    final tierBoundaries = <int, String>{};
    final tiedBoundaries = <int>{};  // 同順位チームがまたぐ境界
    if (_finalEnabled && _finalFormat == '順位別複数' && _tierCount >= 2) {
      final leagueCount = _tierCount.clamp(1, allTeams.length);
      final teamsPerTier = (allTeams.length / leagueCount).ceil();
      final leagueNames = _getLeagueNames(leagueCount);
      for (int t = 0; t < leagueCount; t++) {
        final boundary = t * teamsPerTier;
        if (boundary < allTeams.length && t < leagueNames.length) {
          tierBoundaries[boundary] = leagueNames[t];
          // 境界で同順位が分断されているか
          if (t > 0 && boundary > 0 && boundary < allTeams.length && ranks[boundary] == ranks[boundary - 1]) {
            tiedBoundaries.add(boundary);
          }
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
      ),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(children: [
            const Icon(Icons.leaderboard, size: 18, color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            const Text('予選 総合順位', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text('${allTeams.length}チーム', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
        // Column labels
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(children: const [
            SizedBox(width: 28, child: Text('#', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
            Expanded(flex: 3, child: Text('チーム', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary))),
            SizedBox(width: 40, child: Text('勝点', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
            SizedBox(width: 40, child: Text('得失', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
            SizedBox(width: 40, child: Text('総得', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
          ]),
        ),
        Divider(height: 1, color: Colors.grey[200]),
        // Team rows（同順位対応）
        ...() {
          return allTeams.asMap().entries.expand((e) {
            final i = e.key;
            final t = e.value;
            final rank = ranks[i];
            final isMyTeam = widget.myTeamIds.contains(t['teamId'] ?? '');
            final tierLabel = tierBoundaries[i];
            final isTiedBoundary = tiedBoundaries.contains(i);
            return [
              // 区分ラベル + 境界線
              if (tierLabel != null) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Container(height: 2, color: isTiedBoundary ? Colors.orange.withValues(alpha: 0.5) : Colors.red.withValues(alpha: 0.3)),
                  ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  color: isTiedBoundary ? Colors.orange.withValues(alpha: 0.08) : AppTheme.primaryColor.withValues(alpha: 0.06),
                  child: Row(children: [
                    Text(tierLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                        color: isTiedBoundary ? Colors.orange[800]! : AppTheme.primaryColor)),
                    if (isTiedBoundary) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.warning_amber_rounded, size: 12, color: Colors.orange[700]),
                      const SizedBox(width: 2),
                      Text('同順位あり', style: TextStyle(fontSize: 10, color: Colors.orange[700])),
                    ],
                  ]),
                ),
              ] else if (i > 0)
                Divider(height: 1, color: Colors.grey[200]),
              InkWell(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamMatchResultsScreen(
                  tournamentId: widget.tournamentId,
                  tournamentName: widget.tournamentName,
                  teamId: t['teamId'] as String? ?? '',
                  teamName: t['teamName'] as String? ?? '',
                ))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(children: [
                    SizedBox(width: 28, child: Text('$rank', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                        color: rank == 1 ? Colors.amber[700] : (rank <= 3 ? AppTheme.primaryColor : AppTheme.textPrimary)))),
                    Expanded(flex: 3, child: Text(t['teamName'] ?? '', style: TextStyle(fontSize: 14,
                        color: isMyTeam ? Colors.red : null,
                        fontWeight: isMyTeam ? FontWeight.bold : FontWeight.normal), overflow: TextOverflow.ellipsis)),
                    SizedBox(width: 40, child: Text('${t['matchPoints']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                    SizedBox(width: 40, child: Text('${t['pointDiff']}', style: TextStyle(fontSize: 13,
                        color: (t['pointDiff'] as num) >= 0 ? AppTheme.success : AppTheme.error), textAlign: TextAlign.center)),
                    SizedBox(width: 40, child: Text('${t['totalPoints']}', style: const TextStyle(fontSize: 13), textAlign: TextAlign.center)),
                  ]),
                ),
              ),
            ];
          });
        }(),
      ]),
    );
  }
}

// ━━━ 最終順位（決勝トーナメント結果から算出） ━━━
class _FinalRankingsWidget extends StatefulWidget {
  final String tournamentId;
  final String tournamentName;
  final List<String> myTeamIds;

  const _FinalRankingsWidget({
    required this.tournamentId,
    required this.tournamentName,
    required this.myTeamIds,
  });

  @override
  State<_FinalRankingsWidget> createState() => _FinalRankingsWidgetState();
}

class _FinalRankingsWidgetState extends State<_FinalRankingsWidget> {
  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<QuerySnapshot>? _bracketsSub;
  StreamSubscription<DocumentSnapshot>? _tournamentSub;
  final List<StreamSubscription<QuerySnapshot>> _matchSubs = [];

  // bracketId → { rankStart, matches }
  final Map<String, _BracketInfo> _brackets = {};
  bool _loaded = false;
  int _maxTeams = 0;

  @override
  void initState() {
    super.initState();
    _subscribeTournament();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _FinalRankingsWidget old) {
    super.didUpdateWidget(old);
    if (old.tournamentId != widget.tournamentId) {
      _cancelAll();
      _subscribe();
    }
  }

  void _subscribeTournament() {
    _tournamentSub = _firestore
        .collection('tournaments').doc(widget.tournamentId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final data = snap.data() as Map<String, dynamic>? ?? {};
      setState(() {
        // ポイント表示は実参加チーム数（currentTeams）基準。無ければ募集枠
        _maxTeams = PointService.effectiveTeamCount(
          currentTeams: (data['currentTeams'] as num?)?.toInt(),
          maxTeams: (data['maxTeams'] as num?)?.toInt(),
        );
      });
    });
  }

  void _subscribe() {
    _bracketsSub = _firestore
        .collection('tournaments').doc(widget.tournamentId)
        .collection('brackets').snapshots()
        .listen((snap) {
      if (!mounted) return;
      // Cancel old match subs
      for (final sub in _matchSubs) sub.cancel();
      _matchSubs.clear();
      _brackets.clear();

      if (snap.docs.isEmpty) {
        setState(() => _loaded = true);
        return;
      }

      for (final bracketDoc in snap.docs) {
        final data = bracketDoc.data();
        final rankRange = data['rankRange'] as String? ?? '';
        final rankStart = _parseRankStart(rankRange);

        _brackets[bracketDoc.id] = _BracketInfo(
          rankStart: rankStart,
          teamCount: (data['teamCount'] as num?)?.toInt() ?? 0,
          matches: [],
        );

        // Subscribe to matches of this bracket
        final sub = bracketDoc.reference
            .collection('matches')
            .snapshots()
            .listen((matchSnap) {
          if (!mounted) return;
          setState(() {
            _brackets[bracketDoc.id]?.matches = matchSnap.docs
                .map((d) => Map<String, dynamic>.from(d.data()))
                .toList();
            _loaded = true;
          });
        });
        _matchSubs.add(sub);
      }
    });
  }

  int _parseRankStart(String rankRange) {
    // "1〜8位" → 1, "9〜16位" → 9
    final match = RegExp(r'(\d+)').firstMatch(rankRange);
    return match != null ? int.parse(match.group(1)!) : 1;
  }

  void _cancelAll() {
    _bracketsSub?.cancel();
    _tournamentSub?.cancel();
    for (final sub in _matchSubs) sub.cancel();
    _matchSubs.clear();
    _brackets.clear();
    _loaded = false;
  }

  @override
  void dispose() {
    _cancelAll();
    super.dispose();
  }

  /// 決勝系ラウンドから順位を抽出
  /// final_1st → winner=1, loser=2
  /// final_3rd → winner=3, loser=4
  /// final_5th → winner=5, loser=6
  /// final_7th → winner=7, loser=8
  int? _localRankFromRound(String round, {required bool isWinner}) {
    final mapping = {
      'final_1st': 1,
      'final_3rd': 3,
      'final_5th': 5,
      'final_7th': 7,
    };
    final base = mapping[round];
    if (base == null) return null;
    return isWinner ? base : base + 1;
  }

  List<_RankedTeam> _computeRankings() {
    final rankings = <_RankedTeam>[];

    for (final entry in _brackets.entries) {
      final info = entry.value;
      final rankStart = info.rankStart;

      for (final match in info.matches) {
        final round = match['round'] as String? ?? '';
        final status = match['status'] as String? ?? '';
        if (status != 'completed') continue;

        final result = match['result'] as Map<String, dynamic>? ?? {};
        final winnerId = result['winner'] as String? ?? '';
        if (winnerId.isEmpty || winnerId == '引き分け') continue;

        final teamAId = match['teamAId'] as String? ?? '';
        final teamBId = match['teamBId'] as String? ?? '';
        final teamAName = match['teamAName'] as String? ?? '';
        final teamBName = match['teamBName'] as String? ?? '';

        final winnerLocalRank = _localRankFromRound(round, isWinner: true);
        final loserLocalRank = _localRankFromRound(round, isWinner: false);

        if (winnerLocalRank != null) {
          final isA = winnerId == teamAId;
          final globalRank = rankStart + winnerLocalRank - 1;
          rankings.add(_RankedTeam(
            globalRank: globalRank,
            teamId: isA ? teamAId : teamBId,
            teamName: isA ? teamAName : teamBName,
            rewardPoints: _maxTeams > 0 ? PointService.calculateRankPoints(_maxTeams, globalRank) : 0,
          ));
        }
        if (loserLocalRank != null) {
          final isA = winnerId == teamAId;
          final globalRank = rankStart + loserLocalRank - 1;
          rankings.add(_RankedTeam(
            globalRank: globalRank,
            teamId: isA ? teamBId : teamAId,
            teamName: isA ? teamBName : teamAName,
            rewardPoints: _maxTeams > 0 ? PointService.calculateRankPoints(_maxTeams, globalRank) : 0,
          ));
        }
      }
    }

    rankings.sort((a, b) => a.globalRank.compareTo(b.globalRank));

    // 重複排除
    final seen = <String>{};
    return rankings.where((r) => seen.add(r.teamId)).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    if (_brackets.isEmpty) return const SizedBox.shrink();

    final rankings = _computeRankings();
    if (rankings.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.1),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(children: [
            const Icon(Icons.emoji_events, size: 18, color: Colors.amber),
            const SizedBox(width: 8),
            const Text('最終順位', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text('${rankings.length}チーム確定', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
        // Rankings
        ...rankings.asMap().entries.expand((e) {
          final i = e.key;
          final r = e.value;
          final isMyTeam = widget.myTeamIds.contains(r.teamId);
          return [
            if (i > 0) Divider(height: 1, color: Colors.grey[200]),
            InkWell(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamMatchResultsScreen(
                tournamentId: widget.tournamentId,
                tournamentName: widget.tournamentName,
                teamId: r.teamId,
                teamName: r.teamName,
                finalRank: r.globalRank,
              ))),
              child: Container(
                color: isMyTeam ? Colors.red.withValues(alpha: 0.08) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    SizedBox(
                      width: 36,
                      child: r.globalRank <= 3
                          ? Icon(
                              Icons.emoji_events,
                              size: 20,
                              color: r.globalRank == 1
                                  ? Colors.amber[700]
                                  : r.globalRank == 2
                                      ? Colors.grey[400]
                                      : Colors.brown[300],
                            )
                          : const SizedBox.shrink(),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${r.globalRank}位',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: r.globalRank == 1
                              ? Colors.amber[700]
                              : r.globalRank <= 3
                                  ? AppTheme.primaryColor
                                  : AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        r.teamName,
                        style: TextStyle(
                          fontSize: 14,
                          color: isMyTeam ? Colors.red : null,
                          fontWeight: isMyTeam ? FontWeight.bold : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (r.rewardPoints > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: r.globalRank == 1
                              ? Colors.amber.withValues(alpha: 0.15)
                              : r.globalRank <= 3
                                  ? AppTheme.primaryColor.withValues(alpha: 0.1)
                                  : Colors.grey.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${r.rewardPoints}pt',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: r.globalRank == 1
                                ? Colors.amber[700]
                                : r.globalRank <= 3
                                    ? AppTheme.primaryColor
                                    : AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 16, color: Color(0xFFCCCCCC)),
                  ]),
                ),
              ),
            ),
          ];
        }),
        // 画像で保存ボタン
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('順位表を画像で保存'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryColor,
                side: BorderSide(color: AppTheme.accentColor.withValues(alpha: 0.8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => _saveRankingImage(rankings),
            ),
          ),
        ),
      ]),
    );
  }

  void _saveRankingImage(List<_RankedTeam> rankings) {
    String? note(int rank) => rank == 1
        ? '優勝'
        : rank == 2
            ? '準優勝'
            : rank == 3
                ? '3位'
                : null;
    final data = ShareRankingData(
      tournamentTitle: widget.tournamentName,
      subtitle: '全${rankings.length}チーム',
      rows: [
        for (final r in rankings)
          ShareRankingRow(rank: r.globalRank, teamName: r.teamName, note: note(r.globalRank)),
      ],
    );
    ResultShareService.saveRanking(context, data);
  }
}

class _BracketInfo {
  final int rankStart;
  final int teamCount;
  List<Map<String, dynamic>> matches;

  _BracketInfo({required this.rankStart, required this.teamCount, required this.matches});
}

class _RankedTeam {
  final int globalRank;
  final String teamId;
  final String teamName;
  final int rewardPoints;

  _RankedTeam({
    required this.globalRank,
    required this.teamId,
    required this.teamName,
    this.rewardPoints = 0,
  });
}

// ━━━ ギャラリー写真ビューア（横スワイプ＋ダウンロード） ━━━
class _GalleryPhotoViewer extends StatefulWidget {
  final List<QueryDocumentSnapshot> photos;
  final int initialIndex;
  const _GalleryPhotoViewer({required this.photos, required this.initialIndex});

  @override
  State<_GalleryPhotoViewer> createState() => _GalleryPhotoViewerState();
}

class _GalleryPhotoViewerState extends State<_GalleryPhotoViewer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: SizedBox(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height,
        child: Stack(children: [
          // 横スワイプ可能な画像
          PageView.builder(
            controller: _pageController,
            itemCount: widget.photos.length,
            onPageChanged: (i) => setState(() => _currentIndex = i),
            itemBuilder: (context, index) {
              final data = widget.photos[index].data() as Map<String, dynamic>;
              final imageUrl = (data['imageUrl'] as String?) ?? '';
              return InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Center(
                  child: Image.network(imageUrl, fit: BoxFit.contain,
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));
                    },
                  ),
                ),
              );
            },
          ),
          // 上部バー: 閉じる + ページ番号
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16, right: 16,
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Icons.close, color: Colors.white, size: 22),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                child: Text('${_currentIndex + 1} / ${widget.photos.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              ),
              const Spacer(),
              // ダウンロードボタン
              GestureDetector(
                onTap: () async {
                  final data = widget.photos[_currentIndex].data() as Map<String, dynamic>;
                  final imageUrl = (data['imageUrl'] as String?) ?? '';
                  if (imageUrl.isNotEmpty) {
                    final uri = Uri.parse(imageUrl);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  }
                },
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Icons.download, color: Colors.white, size: 22),
                ),
              ),
            ]),
          ),
          // 下部: 投稿者情報
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16, right: 16,
            child: Center(child: Builder(builder: (_) {
              final data = widget.photos[_currentIndex].data() as Map<String, dynamic>;
              final uploaderName = (data['uploaderName'] as String?) ?? '';
              final createdAt = data['createdAt'] as Timestamp?;
              String timeText = '';
              if (createdAt != null) {
                final date = createdAt.toDate();
                timeText = '${date.year}/${date.month}/${date.day}';
              }
              if (uploaderName.isEmpty) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text('$uploaderName  $timeText', style: const TextStyle(color: Colors.white, fontSize: 13)),
              );
            })),
          ),
        ]),
      ),
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});
  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ━━━ 主催者メニュー全画面 ━━━
class _OrganizerMenuScreen extends StatelessWidget {
  final Map<String, dynamic> tournData;
  final String tournamentId;
  final void Function(BuildContext) onEditTournament;
  final VoidCallback onSelfEntry;
  final VoidCallback onRecruit;
  final VoidCallback onCheckIn;
  final VoidCallback onCsvMenu;
  final VoidCallback onDeleteTeams;
  final VoidCallback onFinance;
  final VoidCallback onGenerateRound1;
  final VoidCallback onGenerateRound2;
  final VoidCallback onGenerateFinals;
  final VoidCallback onReset;
  final VoidCallback onEndTournament;
  final VoidCallback onSaveTemplate;
  final VoidCallback onDelete;
  final VoidCallback onUpdateBracketCourts;

  const _OrganizerMenuScreen({
    required this.tournData,
    required this.tournamentId,
    required this.onEditTournament,
    required this.onSelfEntry,
    required this.onRecruit,
    required this.onCheckIn,
    required this.onCsvMenu,
    required this.onDeleteTeams,
    required this.onFinance,
    required this.onGenerateRound1,
    required this.onGenerateRound2,
    required this.onGenerateFinals,
    required this.onReset,
    required this.onEndTournament,
    required this.onSaveTemplate,
    required this.onDelete,
    required this.onUpdateBracketCourts,
  });

  @override
  Widget build(BuildContext context) {
    final rules = tournData['rules'] as Map<String, dynamic>? ?? {};
    final preliminary = rules['preliminary'] as Map<String, dynamic>? ?? {};
    final prelimRounds = preliminary['rounds'] ?? 1;
    final finalEnabled = (rules['final'] as Map<String, dynamic>?)?['enabled'] ?? true;
    final status = normalizeTournamentStatus(tournData['status'] ?? '準備中');
    final isRunning = status == '開催中' || status == '決勝中' || status == '順位決定中';

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('大会主催者メニュー', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 40),
        children: [
          // ━━━ 大会情報 ━━━
          _sectionLabel('大会情報'),
          _menuTileNavigate(context, Icons.edit_outlined, '大会を編集', '名前・日程・会場・ルールなど', () => onEditTournament(context), color: AppTheme.primaryColor),
          _menuTileNavigate(context, Icons.sync_outlined, 'ステータス変更', '準備中 → 募集中 → 締切 → 大会準備中 → 開催中 → 終了', () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => _StatusChangeScreen(
              tournamentId: tournamentId, currentStatus: tournData['status'] ?? '準備中')));
          }, color: AppTheme.primaryColor),

          // ━━━ 参加者管理 ━━━
          _sectionLabel('参加者管理'),
          _menuTile(context, Icons.how_to_reg, '自分もエントリー', 'チームを作成してエントリー', onSelfEntry, color: AppTheme.success),
          _menuTile(context, Icons.person_add, 'メンバー募集する', '一緒にプレーするメンバーを募集', onRecruit, color: AppTheme.success),
          _menuTile(context, Icons.qr_code_2, '受付・チェックイン', '大会QRの表示・手動チェックイン（参加者が掲示QRを読み取ります）', onCheckIn, color: AppTheme.success),
          _menuTile(context, Icons.upload_file, 'CSVインポート', 'エントリー・対戦表・決勝のCSV管理', onCsvMenu, color: AppTheme.success),

          // ━━━ 運営 ━━━
          _sectionLabel('運営'),
          _menuTile(context, Icons.account_balance_wallet_outlined, '収支管理', '参加費の入金状況・経費を管理', onFinance, color: AppTheme.accentColor),
          _menuTileNavigate(context, Icons.people_outline, '権限管理', '他のユーザーに編集権限を付与', () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => _EditorsScreen(tournamentId: tournamentId)));
          }, color: AppTheme.accentColor),
          _menuTileNavigate(context, Icons.campaign_outlined, 'お知らせ送信', '全参加者に通知を送信', () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => _AnnouncementScreen(
              tournamentId: tournamentId, tournamentData: tournData)));
          }, color: AppTheme.accentColor),
          if (status == '終了')
            _menuTile(context, Icons.notifications_active_outlined, '感想・ガジェット登録を再通知', '参加者に大会終了の通知を再送信', () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('再通知しますか？'),
                  content: const Text('全参加者に「大会終了・感想投稿・ガジェット登録」の通知を再送信します。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
                    ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('送信する')),
                  ],
                ),
              );
              if (confirm != true) return;
              final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
              final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
              final organizerName = userDoc.data()?['nickname'] ?? userDoc.data()?['displayName'] ?? '';
              await NotificationService.sendTournamentEndNotification(
                tournamentId: tournamentId,
                tournamentName: tournData['title'] ?? '',
                tournamentDate: tournData['date'] ?? '',
                organizerId: uid,
                organizerName: organizerName,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('参加者に再通知しました'), backgroundColor: AppTheme.success),
                );
              }
            }, color: AppTheme.accentColor),

          // ━━━ 試合進行 ━━━
          _sectionLabel('試合進行'),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('tournaments').doc(tournamentId)
                .collection('rounds').snapshots(),
            builder: (context, roundsSnap) {
              final roundDocs = roundsSnap.data?.docs ?? [];
              final existingRoundNumbers = roundDocs.map((d) => (d.data() as Map<String, dynamic>)['roundNumber'] ?? 1).toSet();
              final hasRound1 = existingRoundNumbers.contains(1);
              final hasRound2 = existingRoundNumbers.contains(2);

              // 最終ラウンドのmatchesをStreamで監視して全完了かチェック
              final lastRoundNum = hasRound2 ? 2 : (hasRound1 ? 1 : 0);

              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('tournaments').doc(tournamentId)
                    .collection('brackets').snapshots(),
                builder: (context, bracketsSnap) {
                  final hasBrackets = bracketsSnap.hasData && bracketsSnap.data!.docs.isNotEmpty;

                  if (lastRoundNum == 0) {
                    return _menuTile(context, Icons.auto_awesome, '予選1の対戦表を生成', 'エントリーチームからコート別の対戦表を自動生成', onGenerateRound1, color: AppTheme.info);
                  }

                  // 該当ラウンドの試合完了状況をリアルタイムで監視
                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('tournaments').doc(tournamentId)
                        .collection('rounds').doc('round_$lastRoundNum').collection('matches').snapshots(),
                    builder: (context, matchesSnap) {
                      final matchDocs = matchesSnap.data?.docs ?? [];
                      final allMatchesCompleted = matchDocs.isNotEmpty &&
                          matchDocs.every((d) => (d.data() as Map<String, dynamic>)['status'] == 'completed');

                      // 予選1完了 → 予選2ボタン表示
                      final showRound2Button = prelimRounds >= 2 && hasRound1 && !hasRound2 &&
                          lastRoundNum == 1 && allMatchesCompleted;

                      // 全予選完了 → 順位決定戦ボタン表示
                      final showFinalsButton = finalEnabled && !hasBrackets && allMatchesCompleted &&
                          (prelimRounds == 1 ? hasRound1 : (hasRound1 && hasRound2)) &&
                          lastRoundNum == (prelimRounds == 1 ? 1 : 2);

                      return Column(children: [
                        if (showRound2Button)
                          _menuTile(context, Icons.replay, '予選2の対戦表を生成', '予選1の全試合完了済み — 予選2を生成できます', onGenerateRound2, color: AppTheme.info),
                        if (showFinalsButton)
                          _menuTile(context, Icons.emoji_events, '順位決定戦の対戦表を生成', '全予選完了済み — 順位決定戦を生成できます', onGenerateFinals, color: AppTheme.info),
                        if (hasBrackets)
                          _menuTile(context, Icons.sports_volleyball, 'コート・審判を更新', '順位決定戦のコート割振・審判割当を再設定', onUpdateBracketCourts, color: Colors.amber),
                      ]);
                    },
                  );
                },
              );
            },
          ),

          // ━━━ その他 ━━━
          _sectionLabel('その他'),
          _menuTile(context, Icons.bookmark_add_outlined, 'テンプレートに保存', '大会設定をテンプレートとして保存', onSaveTemplate, color: AppTheme.textSecondary),

          // ━━━ リセット・削除 ━━━
          _sectionLabel('リセット・削除'),
          _menuTile(context, Icons.delete_sweep, 'エントリーチーム削除', '選択したチームをエントリーから削除', onDeleteTeams, isDestructive: true),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('tournaments').doc(tournamentId)
                .collection('rounds').snapshots(),
            builder: (context, roundsSnap) {
              final hasAnyRound = roundsSnap.hasData && roundsSnap.data!.docs.isNotEmpty;
              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('tournaments').doc(tournamentId)
                    .collection('brackets').snapshots(),
                builder: (context, bracketsSnap) {
                  final hasBrackets = bracketsSnap.hasData && bracketsSnap.data!.docs.isNotEmpty;
                  if (!hasAnyRound && !hasBrackets) return const SizedBox();
                  return _menuTile(context, Icons.refresh, 'リセット', '対戦表・スコアをリセット', onReset, isDestructive: true);
                },
              );
            },
          ),
          _menuTile(context, Icons.delete_outline, '大会を削除', 'この大会を完全に削除', onDelete, isDestructive: true),

          // ━━━ 大会を終了する ━━━
          if (isRunning) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () { Navigator.pop(context); onEndTournament(); },
                  icon: const Icon(Icons.flag, size: 18),
                  label: const Text('大会を終了する', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.error, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary, letterSpacing: 0.5)),
    );
  }

  Widget _menuTile(BuildContext context, IconData icon, String title, String subtitle, VoidCallback onTap, {Color color = AppTheme.primaryColor, bool isDestructive = false}) {
    final c = isDestructive ? AppTheme.error : color;
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: c),
      ),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDestructive ? AppTheme.error : AppTheme.textPrimary)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      trailing: Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
      onTap: () { Navigator.pop(context); onTap(); },
    );
  }

  /// Menu tile that navigates to a full-screen page without popping the menu first.
  Widget _menuTileNavigate(BuildContext context, IconData icon, String title, String subtitle, VoidCallback onTap, {Color color = AppTheme.primaryColor}) {
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      trailing: Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
      onTap: onTap,
    );
  }
}

// ━━━ ブラケット全試合完了検出＋大会終了ボタン ━━━
class _BracketsWithCompletion extends StatelessWidget {
  final String tournamentId;
  final List<QueryDocumentSnapshot> allBrackets;
  final bool isOrganizer;
  final String status;
  final Widget Function(String id, Map<String, dynamic> data) buildBracketSection;
  final VoidCallback onEndTournament;

  const _BracketsWithCompletion({
    required this.tournamentId,
    required this.allBrackets,
    required this.isOrganizer,
    required this.status,
    required this.buildBracketSection,
    required this.onEndTournament,
  });

  @override
  Widget build(BuildContext context) {
    // 全ブラケットのmatches completionを監視するために、各ブラケットのmatchesを監視
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      ...allBrackets.map((bDoc) {
        final bData = bDoc.data() as Map<String, dynamic>;
        return buildBracketSection(bDoc.id, bData);
      }),
      // 主催者のみ: 全ブラケット全試合完了時に大会終了ボタンを表示
      if (isOrganizer && (status == '順位決定中' || status == '決勝中' || status == '開催中'))
        _AllBracketsCompletionCheck(
          tournamentId: tournamentId,
          bracketDocs: allBrackets,
          onEndTournament: onEndTournament,
        ),
    ]);
  }
}

class _AllBracketsCompletionCheck extends StatelessWidget {
  final String tournamentId;
  final List<QueryDocumentSnapshot> bracketDocs;
  final VoidCallback onEndTournament;

  const _AllBracketsCompletionCheck({
    required this.tournamentId,
    required this.bracketDocs,
    required this.onEndTournament,
  });

  @override
  Widget build(BuildContext context) {
    // 再帰的に各ブラケットのmatchesを監視
    return _BracketCompletionStream(
      tournamentId: tournamentId,
      bracketDocs: bracketDocs,
      bracketIndex: 0,
      allCompleted: true,
      totalMatches: 0,
      onEndTournament: onEndTournament,
    );
  }
}

class _BracketCompletionStream extends StatelessWidget {
  final String tournamentId;
  final List<QueryDocumentSnapshot> bracketDocs;
  final int bracketIndex;
  final bool allCompleted;
  final int totalMatches;
  final VoidCallback onEndTournament;

  const _BracketCompletionStream({
    required this.tournamentId,
    required this.bracketDocs,
    required this.bracketIndex,
    required this.allCompleted,
    required this.totalMatches,
    required this.onEndTournament,
  });

  @override
  Widget build(BuildContext context) {
    // 全ブラケットチェック完了
    if (bracketIndex >= bracketDocs.length) {
      if (!allCompleted || totalMatches == 0) return const SizedBox();
      // 全試合完了 → 順位確認＋大会終了ボタン表示
      return _CompletionBanner(
        totalMatches: totalMatches,
        onEndTournament: onEndTournament,
      );
    }

    // 現在のブラケットのmatchesを監視
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('tournaments').doc(tournamentId)
          .collection('brackets').doc(bracketDocs[bracketIndex].id)
          .collection('matches').snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox();
        final matches = snap.data!.docs;
        final bracketComplete = matches.isNotEmpty &&
            matches.every((m) => (m.data() as Map<String, dynamic>)['status'] == 'completed');
        return _BracketCompletionStream(
          tournamentId: tournamentId,
          bracketDocs: bracketDocs,
          bracketIndex: bracketIndex + 1,
          allCompleted: allCompleted && bracketComplete,
          totalMatches: totalMatches + matches.length,
          onEndTournament: onEndTournament,
        );
      },
    );
  }
}

// ━━━ 全試合完了バナー ━━━
class _CompletionBanner extends StatelessWidget {
  final int totalMatches;
  final VoidCallback onEndTournament;

  const _CompletionBanner({required this.totalMatches, required this.onEndTournament});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.green[50]!, Colors.green[100]!],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.green[300]!, width: 1.5),
        ),
        child: Column(children: [
          const Icon(Icons.emoji_events, size: 40, color: Colors.amber),
          const SizedBox(height: 8),
          const Text('全試合が完了しました！', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          Text('$totalMatches試合すべて終了', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          // 順位を確認するボタン
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                // 順位表タブ(index 2)に遷移
                final state = context.findAncestorStateOfType<_TournamentDetailScreenState>();
                state?._tabController.animateTo(2);
              },
              icon: const Icon(Icons.leaderboard, size: 18),
              label: const Text('順位を確認する', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryColor,
                side: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // 大会を終了するボタン
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onEndTournament,
              icon: const Icon(Icons.flag, size: 18),
              label: const Text('大会を終了する', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ━━━ CSVインポートメニュー画面 ━━━
class _CsvImportMenuScreen extends StatelessWidget {
  final int prelimRounds;
  final bool finalEnabled;
  final VoidCallback onEntryUpload;
  final VoidCallback onEntryTemplate;
  final VoidCallback onMatchTableUpload1;
  final VoidCallback onMatchTableUpload2;
  final VoidCallback onMatchTableTemplate;
  final VoidCallback onFinalsUpload;
  final VoidCallback onFinalsTemplate;

  const _CsvImportMenuScreen({
    required this.prelimRounds,
    required this.finalEnabled,
    required this.onEntryUpload,
    required this.onEntryTemplate,
    required this.onMatchTableUpload1,
    required this.onMatchTableUpload2,
    required this.onMatchTableTemplate,
    required this.onFinalsUpload,
    required this.onFinalsTemplate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('CSVインポート', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 40),
        children: [
          // ━━━ エントリー用 ━━━
          _sectionLabel('エントリー用'),
          _csvTile(context, Icons.upload_file, 'チーム一括登録', 'CSVファイルからチームをまとめて登録', onEntryUpload, color: AppTheme.success),
          _csvTile(context, Icons.download, 'テンプレートDL', 'エントリー用のCSVテンプレート', onEntryTemplate, color: AppTheme.success),

          // ━━━ 予選対戦表 ━━━
          _sectionLabel('予選対戦表'),
          _csvTile(context, Icons.upload_file, '予選1 アップロード', 'CSVファイルから予選1の対戦表をインポート\n※ 得点列があればスコアも一括登録', onMatchTableUpload1, color: AppTheme.info),
          if (prelimRounds >= 2)
            _csvTile(context, Icons.upload_file, '予選2 アップロード', 'CSVファイルから予選2の対戦表をインポート\n※ 得点列があればスコアも一括登録', onMatchTableUpload2, color: AppTheme.info),
          _csvTile(context, Icons.download, 'テンプレートDL', 'この大会専用の予選対戦表テンプレート', onMatchTableTemplate, color: AppTheme.info),

          // ━━━ 決勝対戦表 ━━━
          if (finalEnabled) ...[
            _sectionLabel('決勝対戦表'),
            _csvTile(context, Icons.upload_file, '決勝 アップロード', 'CSVファイルから決勝トーナメントをインポート\n※ 得点列があればスコアも一括登録', onFinalsUpload, color: AppTheme.accentColor),
            _csvTile(context, Icons.download, 'テンプレートDL', 'この大会専用の決勝対戦表テンプレート', onFinalsTemplate, color: AppTheme.accentColor),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary, letterSpacing: 0.5)),
    );
  }

  Widget _csvTile(BuildContext context, IconData icon, String title, String subtitle, VoidCallback onTap, {Color color = AppTheme.primaryColor}) {
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
      trailing: Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
      onTap: () { Navigator.pop(context); onTap(); },
    );
  }
}

/// 同順位チーム振り分け方法の選択ボタン
class _TieOptionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  const _TieOptionButton({required this.icon, required this.label, required this.description, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.orange.withValues(alpha: 0.15) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.orange : Colors.grey.withValues(alpha: 0.3),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(children: [
          Icon(icon, size: 24, color: selected ? Colors.orange[800] : Colors.grey[600]),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
              color: selected ? Colors.orange[900] : AppTheme.textPrimary)),
          const SizedBox(height: 2),
          Text(description, style: TextStyle(fontSize: 10, color: AppTheme.textSecondary),
              textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// メンバー募集 全画面ダイアログ
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _RecruitFullScreen extends StatefulWidget {
  final String tournamentId;
  final Map<String, dynamic> tournament;
  final FirebaseFirestore firestore;
  const _RecruitFullScreen({required this.tournamentId, required this.tournament, required this.firestore});

  @override
  State<_RecruitFullScreen> createState() => _RecruitFullScreenState();
}

class _RecruitFullScreenState extends State<_RecruitFullScreen> {
  int _recruitCount = 1;
  final _commentController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  bool get _hasInput => _commentController.text.trim().isNotEmpty || _recruitCount != 1;

  Future<bool> _confirmDiscard() async {
    if (!_hasInput) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('入力内容を破棄しますか？'),
        content: const Text('入力した内容は保存されません。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('戻る')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('破棄する', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final userDoc = await widget.firestore.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? {};
      await widget.firestore.collection('recruitments').add({
        'tournamentId': widget.tournamentId,
        'tournamentName': widget.tournament['name'],
        'tournamentDate': widget.tournament['date'],
        'userId': uid,
        'nickname': userData['nickname'] ?? '',
        'avatarUrl': userData['avatarUrl'] ?? '',
        'experience': userData['experience'] ?? '',
        'recruitCount': _recruitCount,
        'comment': _commentController.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('募集を投稿しました！'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('投稿に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: AppTheme.backgroundColor,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _confirmDiscard() && mounted) Navigator.pop(context);
            },
          ),
          title: const Text('メンバー募集する', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          centerTitle: true,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity, padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.15)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((widget.tournament['name'] ?? widget.tournament['title'] ?? '') as String,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                  const SizedBox(height: 4),
                  Text((widget.tournament['date'] ?? '') as String,
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                ]),
              ),
              const SizedBox(height: 20),
              const Text('募集人数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: List.generate(4, (i) {
                  final count = i + 1;
                  final isSelected = _recruitCount == count;
                  return Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: GestureDetector(
                      onTap: () => setState(() => _recruitCount = count),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSelected ? AppTheme.primaryColor : AppTheme.backgroundColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isSelected ? AppTheme.primaryColor : Colors.grey[300]!),
                        ),
                        child: Text('${count}人', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : AppTheme.textPrimary)),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              const Text('コメント', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _commentController, maxLines: 3, maxLength: 200,
                decoration: InputDecoration(
                  hintText: '例: 一緒に楽しみましょう！初心者歓迎です',
                  hintStyle: TextStyle(fontSize: 14, color: AppTheme.textHint),
                  filled: true, fillColor: AppTheme.backgroundColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _submitting
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('募集を投稿する', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Firestore Web SDK 12.x の断続的な INTERNAL ASSERTION（WatchChangeAggregator）に対し1回だけ再試行する。
Future<void> _updateTournamentStatusWithRetry(String tournamentId, String status) async {
  try {
    await FirebaseFirestore.instance.collection('tournaments').doc(tournamentId).update({'status': status});
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('INTERNAL ASSERTION') || msg.contains('Unexpected state')) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await FirebaseFirestore.instance.collection('tournaments').doc(tournamentId).update({'status': status});
      return;
    }
    rethrow;
  }
}

// ━━━ ステータス変更画面（全画面） ━━━
class _StatusChangeScreen extends StatefulWidget {
  final String tournamentId;
  final String currentStatus;
  const _StatusChangeScreen({required this.tournamentId, required this.currentStatus});
  @override
  State<_StatusChangeScreen> createState() => _StatusChangeScreenState();
}

class _StatusChangeScreenState extends State<_StatusChangeScreen> {
  late String _selected;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected = normalizeTournamentStatus(widget.currentStatus);
  }

  @override
  Widget build(BuildContext context) {
    final statuses = ['準備中', '募集中', 'エントリー締切', '大会準備中', '開催中', '終了'];
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('ステータス変更', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: statuses.map((s) {
          return RadioListTile<String>(
            title: Text(s, style: const TextStyle(fontSize: 16)),
            value: s,
            groupValue: _selected,
            activeColor: AppTheme.primaryColor,
            onChanged: (v) {
              if (v != null) setState(() => _selected = v);
            },
          );
        }).toList(),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: ElevatedButton(
            onPressed: _selected == widget.currentStatus || _saving ? null : () async {
              setState(() => _saving = true);
              try {
                await _updateTournamentStatusWithRetry(widget.tournamentId, _selected);
                if (mounted) {
                  setState(() => _saving = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('ステータスを「$_selected」に変更しました'), backgroundColor: AppTheme.success),
                  );
                  Navigator.pop(context);
                }
              } catch (e) {
                if (mounted) {
                  setState(() => _saving = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('変更に失敗しました: $e'), backgroundColor: AppTheme.error),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _saving
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('変更を保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }
}

// ━━━ お知らせ送信画面（全画面） ━━━
class _AnnouncementScreen extends StatefulWidget {
  final String tournamentId;
  final Map<String, dynamic> tournamentData;
  const _AnnouncementScreen({required this.tournamentId, required this.tournamentData});
  @override
  State<_AnnouncementScreen> createState() => _AnnouncementScreenState();
}

class _AnnouncementScreenState extends State<_AnnouncementScreen> {
  final _messageCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('お知らせ送信', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('全参加者に通知が届きます', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _messageCtrl,
            maxLines: 6,
            maxLength: 200,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '例: 持ち物の確認、集合場所の変更など',
              hintStyle: TextStyle(fontSize: 14, color: AppTheme.textHint),
              filled: true, fillColor: AppTheme.backgroundColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.check_circle_outline, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text('掲示板にも同時投稿されます', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: ElevatedButton.icon(
            onPressed: _messageCtrl.text.trim().isEmpty || _sending ? null : () async {
              final message = _messageCtrl.text.trim();
              setState(() => _sending = true);

              final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
              final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
              final nickname = userDoc.data()?['nickname'] ?? '主催者';
              final avatar = (userDoc.data()?['avatarUrl'] ?? '') as String;

              await FirebaseFirestore.instance.collection('tournaments').doc(widget.tournamentId).collection('timeline').add({
                'authorId': uid,
                'authorName': nickname,
                'authorAvatar': avatar,
                'text': message,
                'isOrganizer': true,
                'pinned': true,
                'isAnnouncement': true,
                'likesCount': 0,
                'createdAt': FieldValue.serverTimestamp(),
              });

              final tournName = widget.tournamentData['name'] as String? ?? widget.tournamentData['title'] as String? ?? '';
              NotificationService.sendTournamentAnnouncement(
                tournamentId: widget.tournamentId,
                tournamentName: tournName,
                senderId: uid,
                senderName: nickname,
                message: message,
              );

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('お知らせを送信しました'), backgroundColor: AppTheme.success),
                );
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.send, size: 16),
            label: _sending
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('送信', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentColor, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ),
    );
  }
}

// ━━━ 権限管理画面（全画面） ━━━
class _EditorsScreen extends StatefulWidget {
  final String tournamentId;
  const _EditorsScreen({required this.tournamentId});
  @override
  State<_EditorsScreen> createState() => _EditorsScreenState();
}

class _EditorsScreenState extends State<_EditorsScreen> {
  final _firestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return Scaffold(
      appBar: AppBar(
        title: const Text('権限管理', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: const Center(child: Text('ログインしてください')),
    );

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('権限管理', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('編集権限を持つユーザーは大会情報を編集できます', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),

          // 現在の編集者リスト
          StreamBuilder<DocumentSnapshot>(
            stream: _firestore.collection('tournaments').doc(widget.tournamentId).snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
              final tournData = snap.data!.data() as Map<String, dynamic>? ?? {};
              final editors = List<String>.from(tournData['editors'] ?? []);

              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('編集者 ${editors.length}人', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (editors.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                    child: const Center(child: Text('まだ編集者がいません', style: TextStyle(color: AppTheme.textHint))),
                  )
                else
                  ...editors.map((editorUid) => FutureBuilder<DocumentSnapshot>(
                    future: _firestore.collection('users').doc(editorUid).get(),
                    builder: (context, userSnap) {
                      final userData = userSnap.data?.data() as Map<String, dynamic>?;
                      final name = userData?['nickname'] ?? '名前なし';
                      final avatar = (userData?['avatarUrl'] ?? '').toString();
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: avatar.isNotEmpty
                            ? CircleAvatar(radius: 18, backgroundImage: NetworkImage(avatar))
                            : CircleAvatar(radius: 18, backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                                child: Text(name.toString().isNotEmpty ? name.toString()[0] : '?',
                                    style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold))),
                        title: Text(name.toString(), style: const TextStyle(fontSize: 14)),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline, color: AppTheme.error),
                          onPressed: () async {
                            await _firestore.collection('tournaments').doc(widget.tournamentId).update({
                              'editors': FieldValue.arrayRemove([editorUid]),
                            });
                          },
                        ),
                      );
                    },
                  )),
              ]);
            },
          ),
          const SizedBox(height: 24),

          // フォロー中から追加
          const Text('フォロー中から追加', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('users').doc(uid).collection('following').snapshots(),
            builder: (context, followSnap) {
              if (!followSnap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
              final followings = followSnap.data!.docs;
              if (followings.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: const Center(child: Text('フォロー中のユーザーがいません', style: TextStyle(color: AppTheme.textHint))),
                );
              }
              return StreamBuilder<DocumentSnapshot>(
                stream: _firestore.collection('tournaments').doc(widget.tournamentId).snapshots(),
                builder: (context, tournSnap) {
                  final currentEditors = List<String>.from(
                      (tournSnap.data?.data() as Map<String, dynamic>?)?['editors'] ?? []);
                  return Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[200]!),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: followings.length,
                      itemBuilder: (context, index) {
                        final fDoc = followings[index];
                        final fUid = fDoc.id;
                        final isAlreadyEditor = currentEditors.contains(fUid);

                        return FutureBuilder<DocumentSnapshot>(
                          future: _firestore.collection('users').doc(fUid).get(),
                          builder: (context, userSnap) {
                            final fData = fDoc.data() as Map<String, dynamic>;
                            final userData = userSnap.data?.data() as Map<String, dynamic>?;
                            final fName = userData?['nickname'] ?? fData['nickname'] ?? fData['userName'] ?? '名前なし';
                            final fAvatar = userData?['avatarUrl'] ?? fData['avatarUrl'] ?? '';

                            return ListTile(
                              leading: fAvatar.toString().isNotEmpty
                                  ? CircleAvatar(backgroundImage: NetworkImage(fAvatar.toString()), radius: 18)
                                  : CircleAvatar(radius: 18, backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                                      child: Text(fName.toString().isNotEmpty ? fName.toString()[0] : '?',
                                          style: const TextStyle(color: AppTheme.primaryColor))),
                              title: Text(fName.toString(), style: const TextStyle(fontSize: 14)),
                              trailing: isAlreadyEditor
                                  ? const Icon(Icons.check_circle, color: AppTheme.success)
                                  : IconButton(
                                      icon: const Icon(Icons.add_circle_outline, color: AppTheme.primaryColor),
                                      onPressed: () async {
                                        await _firestore.collection('tournaments').doc(widget.tournamentId).update({
                                          'editors': FieldValue.arrayUnion([fUid]),
                                        });
                                      },
                                    ),
                            );
                          },
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
