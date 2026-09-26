import 'dart:async';
import 'dart:convert';
import '../profile/user_profile_screen.dart';
import '../notification/notification_screen.dart';
import '../../services/notification_service.dart';
import '../../services/push_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;
import '../../config/app_theme.dart';
import '../../services/follow_service.dart';
import '../../widgets/official_badge.dart';
import '../../widgets/empty_state_view.dart';
import '../../widgets/post_media_carousel.dart';
import '../../widgets/likes_list_sheet.dart';
import '../tournament/tournament_detail_screen.dart';
import '../tournament/post_event_action_screen.dart';
import '../team/team_management_screen.dart';
import '../follow/follow_search_screen.dart';
import '../../widgets/sponsor_banner.dart';
import '../../widgets/active_tournament_banner.dart';
import 'create_post_screen.dart';
import 'comment_screen.dart';

// アプリ起動時ポップアップ（見逃し防止）1件分。大会エントリー招待・
// チーム参加リクエストなど、種類が違ってもまとめて1つの一覧で出すための共通形。
class _PendingActionItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final void Function(BuildContext dialogContext) onTap;
  _PendingActionItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  late TabController _noticeSubTabController;
  final Set<String> _hiddenPostIds = {};
  bool _initialLoaded = false;
  bool _viewerIsOfficial = false;
  final Map<String, bool> _officialCache = {};

  // タイムライン用: 公式アカウントのuid（フォロー数に関係なく必ず表示する）
  final Set<String> _officialUids = {};
  // whereIn は最大30件までなので、対象uidを30件ずつに分割して購読しマージする
  String _timelineKey = '';
  Stream<List<QueryDocumentSnapshot>>? _timelineStreamCache;
  StreamController<List<QueryDocumentSnapshot>>? _timelineController;
  final List<StreamSubscription<QuerySnapshot>> _timelineSubs = [];
  final Map<int, List<QueryDocumentSnapshot>> _timelineChunks = {};
  List<QueryDocumentSnapshot>? _timelineLast;

  Future<void> _checkOfficial(String userId) async {
    if (_officialCache.containsKey(userId)) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      if (mounted) {
        setState(() {
          _officialCache[userId] = doc.data()?['isOfficial'] == true;
        });
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: const Duration(milliseconds: 200),
    );
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _noticeSubTabController = TabController(length: 2, vsync: this);
    _loadInitialData();
    FollowService.instance.addListener(_onFollowChanged);
    WidgetsBinding.instance.addObserver(this);
    // アプリ起動時にバッジを正確な未読数に同期
    PushNotificationService.updateBadgeCount();
    // アプリ起動時、未対応（未承認）の大会エントリー招待があればポップアップで知らせる
    _checkPendingActionItems();
  }

  // 通知ベルを開かないと気づけない問題への対策。
  // notifications の read フラグではなく、entryDrafts/joinRequests の実際の
  // 承認待ち状態を直接見るので、一度ベルを開いただけでは消えない。
  // 大会エントリー招待（招待された本人が対応）とチーム参加リクエスト
  // （チームオーナーが対応）をまとめて1つのポップアップで案内する。
  Future<void> _checkPendingActionItems() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final results = await Future.wait([
        _fetchPendingEntryInviteItems(uid),
        _fetchPendingTeamJoinRequestItems(uid),
      ]);
      final items = [...results[0], ...results[1]];
      if (items.isEmpty || !mounted) return;

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(children: [
            Icon(Icons.how_to_reg, color: AppTheme.primaryColor),
            SizedBox(width: 8),
            Expanded(child: Text('対応が必要な項目があります', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ]),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: items.map((item) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(item.icon, color: AppTheme.primaryColor),
                  title: Text(item.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  subtitle: Text(item.subtitle, style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => item.onTap(ctx),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('あとで')),
          ],
        ),
      );
    } catch (e) {
      debugPrint('対応が必要な項目の確認に失敗: $e');
    }
  }

  // ── 大会エントリー招待（招待された本人が承認/辞退する）──
  Future<List<_PendingActionItem>> _fetchPendingEntryInviteItems(String uid) async {
    final snap = await FirebaseFirestore.instance
        .collectionGroup('entryDrafts')
        .where('invitedUids', arrayContains: uid)
        .get();
    final pending = snap.docs.where((d) {
      final data = d.data();
      final leaderUid = (data['leaderUid'] ?? '').toString();
      final approvals = Map<String, dynamic>.from(data['approvals'] as Map? ?? {});
      final myState = (approvals[uid] ?? 'pending').toString();
      return leaderUid != uid && myState == 'pending';
    }).toList();
    if (pending.isEmpty) return [];

    // どの大会への招待か分かるよう、大会名・日付も添える
    final tournamentIds = pending.map((d) => d.reference.parent.parent!.id).toSet().toList();
    final tournamentDocs = await Future.wait(
      tournamentIds.map((id) => FirebaseFirestore.instance.collection('tournaments').doc(id).get()),
    );
    final tournamentById = {
      for (var i = 0; i < tournamentIds.length; i++) tournamentIds[i]: tournamentDocs[i],
    };

    // 起動時ポップアップに表示される＝招待を見たので既読にする（失敗しても無視）
    for (final d in pending) {
      if ((d.data()['seenAt'] as Map?)?[uid] != null) continue;
      FirebaseFunctions.instance.httpsCallable('markEntryDraftSeen').call({
        'tournamentId': d.reference.parent.parent!.id,
        'draftId': d.id,
      }).then<void>((_) {}, onError: (_) {});
    }

    return pending.map((d) {
      final data = d.data();
      final tid = d.reference.parent.parent!.id;
      final tDoc = tournamentById[tid];
      final tData = (tDoc != null && tDoc.exists) ? tDoc.data()! : <String, dynamic>{};
      final teamName = (data['teamName'] ?? '').toString();
      final leaderName = (data['leaderName'] ?? '').toString();
      final tournamentName = (tData['name'] ?? tData['title'] ?? '大会').toString();
      final tournamentDate = (tData['date'] ?? '').toString();
      final dateText = tournamentDate.isNotEmpty ? '$tournamentDate・' : '';
      return _PendingActionItem(
        icon: Icons.groups,
        title: '$dateText$tournamentName',
        subtitle: '「$teamName」への招待・$leaderName さんから',
        onTap: (ctx) async {
          Navigator.pop(ctx);
          final doc = await FirebaseFirestore.instance.collection('tournaments').doc(tid).get();
          if (!doc.exists || !mounted) return;
          final fullTData = doc.data()!;
          fullTData['id'] = doc.id;
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => TournamentDetailScreen(tournament: fullTData),
          ));
        },
      );
    }).toList();
  }

  // ── チーム参加リクエスト（チームオーナーが承認/却下する）──
  Future<List<_PendingActionItem>> _fetchPendingTeamJoinRequestItems(String uid) async {
    final teamsSnap = await FirebaseFirestore.instance
        .collection('teams')
        .where('ownerId', isEqualTo: uid)
        .get();
    if (teamsSnap.docs.isEmpty) return [];

    final reqSnaps = await Future.wait(
      teamsSnap.docs.map((t) => t.reference.collection('joinRequests').get()),
    );

    final items = <_PendingActionItem>[];
    for (var i = 0; i < teamsSnap.docs.length; i++) {
      final teamData = teamsSnap.docs[i].data();
      final teamName = (teamData['name'] ?? teamData['teamName'] ?? 'チーム').toString();
      for (final req in reqSnaps[i].docs) {
        final r = req.data();
        final applicantName = (r['name'] ?? '名前なし').toString();
        items.add(_PendingActionItem(
          icon: Icons.group_add,
          title: '「$teamName」への参加リクエスト',
          subtitle: '$applicantName さんから',
          onTap: (ctx) {
            Navigator.pop(ctx);
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => const TeamManagementScreen(),
            ));
          },
        ));
      }
    }
    return items;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PushNotificationService.updateBadgeCount();
    }
  }

  void _onFollowChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadInitialData() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final results = await Future.wait([
      FirebaseFirestore.instance
          .collection('users').doc(uid).collection('hiddenPosts').get(),
      FirebaseFirestore.instance
          .collection('users').doc(uid).get(),
      FirebaseFirestore.instance
          .collection('users').where('isOfficial', isEqualTo: true).get(),
    ]);
    if (!mounted) return;
    final hiddenSnap = results[0] as QuerySnapshot;
    final userDoc = results[1] as DocumentSnapshot;
    final officialSnap = results[2] as QuerySnapshot;
    final userData = userDoc.data() as Map<String, dynamic>?;
    setState(() {
      _hiddenPostIds.addAll(hiddenSnap.docs.map((d) => d.id));
      _viewerIsOfficial = userData?['isOfficial'] == true;
      _officialUids.addAll(officialSnap.docs.map((d) => d.id));
      _initialLoaded = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FollowService.instance.removeListener(_onFollowChanged);
    _disposeTimelineStream();
    _tabController.dispose();
    _noticeSubTabController.dispose();
    super.dispose();
  }

  void _openCreatePost() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreatePostScreen()),
    );
    if (result == true) setState(() {});
  }

  void _showFullImage(BuildContext context, List<ImageProvider> images, int initialIndex) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => _FullScreenImageViewer(
          images: images,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  // ── いいね切り替え ──
  Future<void> _toggleLike(String postId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final likeRef = FirebaseFirestore.instance
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(uid);

    final postRef = FirebaseFirestore.instance.collection('posts').doc(postId);

    final likeDoc = await likeRef.get();

    if (likeDoc.exists) {
      await likeRef.delete();
    } else {
      await likeRef.set({
        'userId': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      // いいね通知を送信
      final postDoc = await postRef.get();
      final postData = postDoc.data() as Map<String, dynamic>?;
      if (postData != null) {
        final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        final userData = userDoc.data() as Map<String, dynamic>?;
        final senderName = userData?['nickname'] ?? '不明';
        final senderAvatar = userData?['avatarUrl'] ?? '';
        NotificationService.sendLikeNotification(
          postOwnerId: postData['userId'] ?? '',
          senderId: uid,
          senderName: senderName,
          senderAvatar: senderAvatar,
          postId: postId,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          // ━━━ 統一ヘッダー ━━━
          Material(
            color: Colors.white,
            child: Column(children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(children: [
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: 'Sof',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w900,
                            fontSize: 24,
                            letterSpacing: 2,
                            color: AppTheme.primaryColor,
                          ),
                        ),
                        TextSpan(
                          text: 'vo',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w900,
                            fontSize: 24,
                            letterSpacing: 2,
                            color: AppTheme.accentColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // 投稿作成（旧・下部FAB）。通知ベルの左に配置してナビとの重なりを解消。
                  // 旧FABと同じくタイムラインタブ（index 0）でのみ表示する。
                  AnimatedBuilder(
                    animation: _tabController,
                    builder: (context, _) {
                      if (_tabController.index != 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: GestureDetector(
                          onTap: _openCreatePost,
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: const BoxDecoration(
                              color: AppTheme.primaryColor,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.add, color: Colors.white, size: 22),
                          ),
                        ),
                      );
                    },
                  ),
                  StreamBuilder<int>(
                    stream: NotificationService.unreadCountStream(
                        FirebaseAuth.instance.currentUser?.uid ?? ''),
                    builder: (context, snap) {
                      final count = snap.data ?? 0;
                      return GestureDetector(
                        onTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const NotificationScreen())),
                        child: Stack(children: [
                          const Icon(Icons.notifications_outlined, size: 26, color: AppTheme.textPrimary),
                          if (count > 0)
                            Positioned(
                              right: 0, top: 0,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                                child: Text('$count',
                                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center),
                              ),
                            ),
                        ]),
                      );
                    },
                  ),
                ]),
              ),
              ),
              const SizedBox(height: 12),
              TabBar(
                controller: _tabController,
                labelColor: AppTheme.textPrimary,
                unselectedLabelColor: AppTheme.textSecondary,
                labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
                indicatorColor: AppTheme.primaryColor,
                indicatorWeight: 3,
                dividerColor: Colors.grey[200],
                tabs: [
                  const Tab(text: 'タイムライン'),
                  Tab(
                    child: _buildNoticeTabLabel(),
                  ),
                ],
              ),
            ]),
          ),
          // 進行中の大会（エントリー済み）があれば上部に導線を表示
          const ActiveTournamentBanner(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _KeepAlivePage(child: _buildTimelineTab()),
                _KeepAlivePage(child: _buildNoticeTab()),
              ],
            ),
          ),
        ]),
      ),
      // 投稿ボタンはヘッダー（通知ベルの左）に移動したため FAB は廃止
    );
  }

  /// タイムラインの投稿ストリーム。
  ///
  /// Firestore の whereIn は最大30件までのため、以前は「自分＋フォロー中」の
  /// 先頭30件だけを渡していた。followingIds は順序を持たない Set なので、
  /// 30人以上フォローしているユーザーでは対象が不定になり、公式アカウントを
  /// 含む一部のフォロー相手の投稿がタイムラインに出ないことがあった。
  /// ここでは対象uidを30件ずつに分割して全て購読し、結果をマージする。
  /// 公式アカウントは必ず先頭に入れる。
  Stream<List<QueryDocumentSnapshot>> _buildTimelineStream(String uid) {
    final posts = FirebaseFirestore.instance.collection('posts');

    if (_viewerIsOfficial) {
      if (_timelineKey != 'official') {
        _disposeTimelineStream();
        _timelineKey = 'official';
        _timelineStreamCache = posts
            .orderBy('createdAt', descending: true)
            .limit(50)
            .snapshots()
            .map((s) => s.docs.cast<QueryDocumentSnapshot>());
      }
      return _timelineStreamCache!;
    }

    // 自分 → 公式 → フォロー中の順（重複は除く）
    final ids = <String>{uid, ..._officialUids, ...FollowService.instance.followingIds}.toList();
    final key = ids.join(',');
    if (key == _timelineKey && _timelineStreamCache != null) {
      return _timelineStreamCache!;
    }

    _disposeTimelineStream();
    _timelineKey = key;

    late final StreamController<List<QueryDocumentSnapshot>> controller;
    controller = StreamController<List<QueryDocumentSnapshot>>.broadcast(onListen: () {
      // broadcast は直前の値を再送しないため、購読開始時に最後の結果を流す
      final last = _timelineLast;
      if (last != null) {
        Future.microtask(() {
          if (!controller.isClosed) controller.add(last);
        });
      }
    });
    _timelineController = controller;

    void emitMerged() {
      final merged = <String, QueryDocumentSnapshot>{};
      for (final docs in _timelineChunks.values) {
        for (final d in docs) {
          merged[d.id] = d;
        }
      }
      final list = merged.values.toList()
        ..sort((a, b) {
          final ta = (a.data() as Map<String, dynamic>?)?['createdAt'];
          final tb = (b.data() as Map<String, dynamic>?)?['createdAt'];
          if (ta is! Timestamp && tb is! Timestamp) return 0;
          if (ta is! Timestamp) return 1; // serverTimestamp 反映前は先頭に置かない
          if (tb is! Timestamp) return -1;
          return tb.compareTo(ta);
        });
      final result = list.take(50).toList();
      _timelineLast = result;
      if (!controller.isClosed) {
        controller.add(result);
      }
    }

    for (var i = 0; i < ids.length; i += 30) {
      final chunkIndex = i ~/ 30;
      final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
      final sub = posts
          .where('userId', whereIn: chunk)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots()
          .listen((snap) {
        _timelineChunks[chunkIndex] = snap.docs.cast<QueryDocumentSnapshot>();
        emitMerged();
      }, onError: (Object e) {
        debugPrint('TIMELINE CHUNK ERROR: $e');
        if (!controller.isClosed) controller.addError(e);
      });
      _timelineSubs.add(sub);
    }

    _timelineStreamCache = controller.stream;
    return _timelineStreamCache!;
  }

  void _disposeTimelineStream() {
    for (final s in _timelineSubs) {
      s.cancel();
    }
    _timelineSubs.clear();
    _timelineChunks.clear();
    _timelineLast = null;
    _timelineController?.close();
    _timelineController = null;
    _timelineStreamCache = null;
    _timelineKey = '';
  }

  Widget _buildTimelineTab() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return const Center(child: Text('ログインしてください'));
    }

    if (!_initialLoaded) {
      return const SizedBox.shrink();
    }

    final uid = currentUser.uid;

    return StreamBuilder<List<QueryDocumentSnapshot>>(
        stream: _buildTimelineStream(uid),
        builder: (context, postSnapshot) {
        if (postSnapshot.hasError) {
          debugPrint("TIMELINE ERROR: ${postSnapshot.error}");
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off, size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  const Text('データの取得に失敗しました',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 8),
                  Text(
                    'ネットワーク接続を確認して\nもう一度お試しください',
                    style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                        height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => setState(() {}),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('再読み込み'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        if (!postSnapshot.hasData) {
          return ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [
            SizedBox(height: 200),
            Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
          ]);
        }

        final allPosts = postSnapshot.data ?? <QueryDocumentSnapshot>[];
        final posts = allPosts.where((doc) => !_hiddenPostIds.contains(doc.id)).toList();
        if (posts.isEmpty) {
          return EmptyStateView(
            icon: Icons.people_outline,
            title: 'タイムラインに投稿がありません',
            subtitle: _viewerIsOfficial
                ? 'まだ誰も投稿していません。'
                : 'フォロー中のユーザーの投稿がここに表示されます。\n仲間を見つけてフォローしましょう！',
            actions: [
              EmptyStateAction(
                label: '投稿する',
                icon: Icons.edit,
                onPressed: _openCreatePost,
              ),
              EmptyStateAction(
                label: '友達をさがす',
                icon: Icons.person_search,
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const FollowSearchScreen())),
                isPrimary: false,
              ),
            ],
          );
        }

        return RefreshIndicator(
          color: AppTheme.primaryColor,
          onRefresh: () async {
            await _loadInitialData();
            setState(() {});
          },
          child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: 4, bottom: 92 + MediaQuery.of(context).padding.bottom),
          itemCount: posts.length + 1,
          separatorBuilder: (_, index) => index == 0
              ? const SizedBox.shrink()
              : Divider(height: 1, thickness: 1, color: Colors.grey[100]),
          itemBuilder: (context, index) {
            if (index == 0) return const SponsorBanner();
            final data =
                posts[index - 1].data() as Map<String, dynamic>? ?? {};
            return _buildPostItem(posts[index - 1].id, data);
          },
        ),
      );
      },
    );
  }


  static const _badgeIconMap = <String, IconData>{
    '初参加': Icons.flag_rounded,
    '5大会参加': Icons.emoji_events_rounded,
    '10大会参加': Icons.emoji_events_rounded,
    '20大会参加': Icons.emoji_events_rounded,
    '初優勝': Icons.military_tech_rounded,
    '3回優勝': Icons.military_tech_rounded,
    '5回優勝': Icons.military_tech_rounded,
    '100Pt達成': Icons.star_rounded,
    '500Pt達成': Icons.star_rounded,
    '1000Pt達成': Icons.diamond_rounded,
    'ガジェット5個': Icons.devices_other_rounded,
    'フォロワー10': Icons.people_rounded,
    'フォロワー50': Icons.people_rounded,
    '投稿10件': Icons.article_rounded,
  };

  /// ネットワーク画像はCachedNetworkImageでプレースホルダー＋フェードイン表示
  Widget _buildFeedImage(List<String> urls, List<ImageProvider> base64Providers, int index, {double? width, double? height}) {
    if (index < urls.length) {
      return CachedNetworkImage(
        imageUrl: urls[index],
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          width: width,
          height: height,
          color: Colors.grey[200],
          child: const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor))),
        ),
        errorWidget: (_, __, ___) => Container(
          width: width,
          height: height,
          color: Colors.grey[200],
          child: const Icon(Icons.broken_image_outlined, color: Colors.grey),
        ),
        fadeInDuration: const Duration(milliseconds: 200),
        memCacheWidth: width != null && width != double.infinity ? (width * 2).toInt() : 400,
        maxWidthDiskCache: 400,
        maxHeightDiskCache: 400,
      );
    }
    final b64Index = index - urls.length;
    return Image(image: base64Providers[b64Index], width: width, height: height, fit: BoxFit.cover);
  }

  /// フルスクリーン表示用にImageProvider一覧を構築
  List<ImageProvider> _buildAllProviders(List<String> urls, List<ImageProvider> base64Providers) {
    return [
      ...urls.map((u) => CachedNetworkImageProvider(u)),
      ...base64Providers,
    ];
  }

  /// media配列（画像・動画を表示順で保持）を全幅スワイプで描画。
  /// 比率そのまま（切り取らない）— フレームは先頭メディアの実比率に合わせる。
  Widget _buildMediaGallery(List<Map<String, dynamic>> media) {
    return PostMediaCarousel(media: media);
  }

  Widget _buildBadgeCard(Map<String, dynamic> data) {
    final badgeName = data['badgeName'] as String? ?? '';
    final colorValue = (data['badgeColorValue'] as num?)?.toInt() ?? 0xFF4CAF50;
    final color = Color(colorValue);
    final icon = _badgeIconMap[badgeName] ?? Icons.emoji_events_rounded;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.10), color.withValues(alpha: 0.03)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.15),
              border: Border.all(color: color.withValues(alpha: 0.4), width: 2.5),
            ),
            child: Icon(
              icon,
              color: color,
              size: 28,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  badgeName,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  'バッジ獲得！',
                  style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.7), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          Icon(Icons.verified, color: color, size: 26),
        ],
      ),
    );
  }

  Widget _buildAutoGeneratedPost(
    String postId, Map<String, dynamic> data, String text, String tournamentId,
    String nickname, String avatarUrl, String timeText,
    int likesCount, int commentsCount, Timestamp? createdAt,
    bool isMyPost, String? postUserId,
  ) {
    // テキストから大会名と優勝チーム名を抽出
    final nameMatch = RegExp(r'「(.+?)」').firstMatch(text);
    final tournamentName = nameMatch?.group(1) ?? '';
    final winnerMatch = RegExp(r'優勝: (.+)').firstMatch(text);
    final rawWinnerName = winnerMatch?.group(1)?.trim() ?? '';

    // 優勝チーム名がIDの場合、entriesから解決（FutureBuilderで非同期処理）
    final looksLikeId = rawWinnerName.isNotEmpty && RegExp(r'^[a-zA-Z0-9]{15,}$').hasMatch(rawWinnerName);

    if (looksLikeId) {
      return FutureBuilder<String>(
        future: _resolveTeamName(tournamentId, rawWinnerName),
        builder: (context, snapshot) {
          final resolvedName = snapshot.data ?? rawWinnerName;
          return _buildAutoGeneratedPostContent(
            postId, data, tournamentId, tournamentName, resolvedName,
            nickname, avatarUrl, timeText, likesCount, commentsCount, isMyPost, postUserId,
          );
        },
      );
    }

    return _buildAutoGeneratedPostContent(
      postId, data, tournamentId, tournamentName, rawWinnerName,
      nickname, avatarUrl, timeText, likesCount, commentsCount, isMyPost, postUserId,
    );
  }

  Future<String> _resolveTeamName(String tournamentId, String teamId) async {
    try {
      // まずdoc IDで直接取得
      final doc = await FirebaseFirestore.instance
          .collection('tournaments').doc(tournamentId)
          .collection('entries').doc(teamId).get();
      if (doc.exists) {
        final name = doc.data()?['teamName'] as String? ?? '';
        if (name.isNotEmpty) return name;
      }
      // teamIdフィールドで検索
      final query = await FirebaseFirestore.instance
          .collection('tournaments').doc(tournamentId)
          .collection('entries').where('teamId', isEqualTo: teamId).limit(1).get();
      if (query.docs.isNotEmpty) {
        final name = query.docs.first.data()['teamName'] as String? ?? '';
        if (name.isNotEmpty) return name;
      }
    } catch (_) {}
    return teamId;
  }

  Widget _buildAutoGeneratedPostContent(
    String postId, Map<String, dynamic> data, String tournamentId,
    String tournamentName, String winnerName,
    String nickname, String avatarUrl, String timeText,
    int likesCount, int commentsCount, bool isMyPost, String? postUserId,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ヘッダー: 主催者情報
                Row(
                  children: [
                    avatarUrl.isNotEmpty
                        ? CircleAvatar(radius: 16, backgroundImage: CachedNetworkImageProvider(avatarUrl),
                            backgroundColor: Colors.grey.shade200)
                        : CircleAvatar(radius: 16, backgroundColor: Colors.grey.shade200,
                            child: Text(nickname.isNotEmpty ? nickname[0] : '?',
                                style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold, fontSize: 12))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(child: Text(nickname,
                              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                              overflow: TextOverflow.ellipsis)),
                          if (postUserId != null && _officialCache[postUserId] == true)
                            const OfficialBadge(size: 13),
                          Text(' · $timeText',
                              style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.3)),
                      ),
                      child: const Text('大会結果', style: TextStyle(color: AppTheme.accentColor, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // トロフィーと大会名
                Row(
                  children: [
                    const Icon(Icons.emoji_events, color: AppTheme.accentColor, size: 28),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tournamentName.isNotEmpty ? '「$tournamentName」終了！' : '大会終了！',
                        style: TextStyle(color: Colors.grey.shade800, fontSize: 17, fontWeight: FontWeight.bold, height: 1.3),
                      ),
                    ),
                  ],
                ),
                if (winnerName.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  // 優勝チーム名
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      children: [
                        const Text('優勝', style: TextStyle(color: AppTheme.accentColor, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 2)),
                        const SizedBox(height: 4),
                        Text(winnerName,
                          style: const TextStyle(color: AppTheme.accentColor, fontSize: 22, fontWeight: FontWeight.w800),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Text('ご参加ありがとうございました！',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                const SizedBox(height: 14),
                // 大会結果を見るボタン
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final doc = await FirebaseFirestore.instance
                          .collection('tournaments').doc(tournamentId).get();
                      if (!doc.exists || !mounted) return;
                      final tData = doc.data()!;
                      tData['id'] = doc.id;
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => TournamentDetailScreen(tournament: tData, initialTab: 'standings'),
                      ));
                    },
                    icon: const Icon(Icons.emoji_events, size: 16),
                    label: const Text('大会結果を見る'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // いいね・コメントバー
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
            child: Row(
              children: [
                _buildLikeButton(postId, likesCount),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: () => _showCommentSheet(postId, nickname),
                  child: Row(children: [
                    Icon(Icons.chat_bubble_outline, size: 22, color: Colors.grey.shade400),
                    const SizedBox(width: 4),
                    Text('$commentsCount', style: TextStyle(fontSize: 14, color: Colors.grey.shade400)),
                  ]),
                ),
                const Spacer(),
                if (isMyPost) _buildPostMenu(postId, isMyPost),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPostItem(String postId, Map<String, dynamic> data) {
    final avatarUrl = _safeString(data['userAvatarUrl'], '');
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final postUserId = data['userId'] as String?;
    final isMyPost = currentUserId != null && postUserId == currentUserId;
    final nickname = _safeString(data['userNickname'], '名無し');
    final text = _safeString(data['text'], '');
    final tournamentId = data['tournamentId'] as String?;
    final isAutoGenerated = data['autoGenerated'] == true;
    final images = data['images'] is List ? List<String>.from(data['images']) : <String>[];
    final imageBase64 = data['imageBase64'] is List ? List<String>.from(data['imageBase64']) : <String>[];
    // media: 画像・動画を表示順で保持した [{type, url}]（Drive自動投稿等）
    final media = data['media'] is List
        ? (data['media'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((m) => (m['url'] ?? '').toString().isNotEmpty)
            .toList()
        : <Map<String, dynamic>>[];
    final likesCount = _safeInt(data['likesCount']);
    final commentsCount = _safeInt(data['commentsCount']);
    final createdAt = data['createdAt'] as Timestamp?;
    final timeText = _formatTime(createdAt);
    final hasBadge = data['badgeName'] != null;
    // 画像URL一覧（ネットワーク画像 + base64画像をImageProviderとして保持）
    final List<String> imageUrls = images.where((u) => u.isNotEmpty).toList();
    final List<ImageProvider> base64Providers = [];
    for (final b64 in imageBase64) {
      if (b64.isNotEmpty) {
        try { base64Providers.add(MemoryImage(base64Decode(b64))); } catch (_) {}
      }
    }
    final int totalImages = imageUrls.length + base64Providers.length;

    // isOfficial チェック
    if (postUserId != null && postUserId.isNotEmpty && !_officialCache.containsKey(postUserId)) {
      _checkOfficial(postUserId);
    }
    final isOfficial = postUserId != null && _officialCache[postUserId] == true;

    // 自動生成投稿（大会結果）の場合は特別なUI
    if (isAutoGenerated && tournamentId != null && tournamentId.isNotEmpty) {
      return _buildAutoGeneratedPost(postId, data, text, tournamentId, nickname, avatarUrl, timeText, likesCount, commentsCount, createdAt, isMyPost, postUserId);
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              debugPrint("Avatar tapped! postUserId=$postUserId");
              if (postUserId != null && postUserId.isNotEmpty) {
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => UserProfileScreen(userId: postUserId!),
                ));
              }
            },
            child: avatarUrl.isNotEmpty
                ? CircleAvatar(radius: 22, backgroundImage: CachedNetworkImageProvider(avatarUrl),
                    backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.15))
                : CircleAvatar(radius: 22, backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                    child: Text(nickname.isNotEmpty ? nickname[0] : '?',
                        style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold, fontSize: 18))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onTap: () {
                          if (postUserId != null && postUserId.isNotEmpty) {
                            Navigator.push(context, MaterialPageRoute(
                              builder: (_) => UserProfileScreen(userId: postUserId),
                            ));
                          }
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(nickname,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.primaryColor),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (isOfficial) const OfficialBadge(size: 15),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('· $timeText', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                  ],
                ),
                if (text.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(text, style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary, height: 1.5)),
                ],
                if (tournamentId != null && tournamentId.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: () async {
                      final doc = await FirebaseFirestore.instance
                          .collection('tournaments').doc(tournamentId).get();
                      if (!doc.exists || !mounted) return;
                      final tData = doc.data()!;
                      tData['id'] = doc.id;
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => TournamentDetailScreen(tournament: tData, initialTab: 'standings'),
                      ));
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.emoji_events, size: 16, color: AppTheme.primaryColor),
                          SizedBox(width: 6),
                          Text('大会結果を見る',
                            style: TextStyle(fontSize: 13, color: AppTheme.primaryColor, fontWeight: FontWeight.w600)),
                          SizedBox(width: 4),
                          Icon(Icons.chevron_right, size: 16, color: AppTheme.primaryColor),
                        ],
                      ),
                    ),
                  ),
                ],
                if (hasBadge) ...[
                  const SizedBox(height: 10),
                  _buildBadgeCard(data),
                ],
                if (media.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _buildMediaGallery(media),
                ] else if (totalImages > 0) ...[
                  const SizedBox(height: 10),
                  totalImages == 1
                      ? GestureDetector(
                          onTap: () => _showFullImage(context, _buildAllProviders(imageUrls, base64Providers), 0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: _buildFeedImage(imageUrls, base64Providers, 0, width: double.infinity, height: 200),
                          ),
                        )
                      : SizedBox(
                          height: 160,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: totalImages,
                            separatorBuilder: (_, __) => const SizedBox(width: 8),
                            itemBuilder: (_, i) => GestureDetector(
                              onTap: () => _showFullImage(context, _buildAllProviders(imageUrls, base64Providers), i),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: _buildFeedImage(imageUrls, base64Providers, i, width: 160, height: 160),
                              ),
                            ),
                          ),
                        ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    _buildCommentButton(postId, commentsCount, nickname),
                    const SizedBox(width: 32),
                    _buildLikeButton(postId, likesCount),
                    const Spacer(),
                    _buildPostMenu(postId, isMyPost),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── いいねボタン（リアルタイム） ──
  Widget _buildLikeButton(String postId, int fallbackCount) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return _buildStaticActionButton(Icons.favorite_border, '$fallbackCount');
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .doc(postId)
          .collection('likes')
          .doc(uid)
          .snapshots(),
      builder: (context, likeSnapshot) {
        final isLiked = likeSnapshot.data?.exists ?? false;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ハート＝いいねON/OFF（従来どおり）
            GestureDetector(
              onTap: () => _toggleLike(postId),
              child: Icon(
                isLiked ? Icons.favorite : Icons.favorite_border,
                size: 22,
                color: isLiked ? Colors.red : AppTheme.textSecondary,
              ),
            ),
            if (fallbackCount > 0 || isLiked) ...[
              const SizedBox(width: 4),
              StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('posts')
                    .doc(postId)
                    .snapshots(),
                builder: (context, postSnap) {
                  final count = postSnap.data?.get('likesCount') ?? fallbackCount;
                  // 数字タップ＝いいねした人の一覧を表示
                  return GestureDetector(
                    onTap: () => showLikesSheet(context,
                        postId: postId,
                        likesCount: count is int ? count : fallbackCount),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 14,
                          color: isLiked ? Colors.red : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  // ── コメントボタン（後で実装） ──
  Widget _buildCommentButton(String postId, int count, String postOwnerName) {
    return GestureDetector(
      onTap: () => _showCommentSheet(postId, postOwnerName),
      child: Row(
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 22, color: AppTheme.textSecondary),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Text('$count',
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.textSecondary)),
          ],
        ],
      ),
    );
  }

  void _showCommentSheet(String postId, String postOwnerName) {
    final commentController = TextEditingController();
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) {
        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () {
              if (commentController.text.trim().isNotEmpty) {
                showDialog(context: context, builder: (c) => AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: const Text('入力内容を破棄しますか？'),
                  content: const Text('入力した内容は保存されません。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('キャンセル')),
                    TextButton(onPressed: () { Navigator.pop(c); Navigator.of(context).pop(); }, child: const Text('破棄する', style: TextStyle(color: Colors.red))),
                  ],
                ));
              } else {
                Navigator.of(context).pop();
              }
            }),
            title: const Text('コメント', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            centerTitle: true,
          ),
          body: Column(
            children: [
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('posts')
                      .doc(postId)
                      .collection('comments')
                      .orderBy('createdAt', descending: false)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
                    }
                    final comments = snapshot.data?.docs ?? [];
                    if (comments.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat_bubble_outline, size: 40, color: Colors.grey[300]),
                            const SizedBox(height: 8),
                            Text('まだコメントはありません', style: TextStyle(color: AppTheme.textSecondary)),
                          ],
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: comments.length,
                      itemBuilder: (context, index) {
                        final data = comments[index].data() as Map<String, dynamic>;
                        final cId = comments[index].id;
                        final nick = (data['userNickname'] as String?) ?? '名無し';
                        final text = (data['text'] as String?) ?? '';
                        final ts = data['createdAt'] as Timestamp?;
                        final t = _formatTime(ts);
                        final commentUserId = data['userId'] as String? ?? '';
                        final isMine = commentUserId == FirebaseAuth.instance.currentUser?.uid;
                        if (commentUserId.isNotEmpty && !_officialCache.containsKey(commentUserId)) {
                          _checkOfficial(commentUserId);
                        }
                        final commentIsOfficial = _officialCache[commentUserId] == true;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                                child: Text(nick.isNotEmpty ? nick[0] : '?',
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Text(nick, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                                      if (commentIsOfficial) const OfficialBadge(size: 13),
                                      const SizedBox(width: 6),
                                      Text(t, style: const TextStyle(fontSize: 11, color: AppTheme.textHint)),
                                      const Spacer(),
                                      if (isMine) GestureDetector(
                                        onTap: () async {
                                          await FirebaseFirestore.instance.collection('posts').doc(postId).collection('comments').doc(cId).delete();
                                        },
                                        child: Icon(Icons.close, size: 16, color: AppTheme.textHint),
                                      ),
                                    ]),
                                    const SizedBox(height: 4),
                                    Text(text, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary, height: 1.4)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.grey[200]!)),
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundColor,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: TextField(
                            controller: commentController,
                            style: const TextStyle(fontSize: 14),
                            decoration: const InputDecoration(
                              hintText: 'コメントを入力...',
                              hintStyle: TextStyle(color: AppTheme.textHint),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () async {
                          final txt = commentController.text.trim();
                          if (txt.isEmpty) return;
                          commentController.clear();
                          final uid = FirebaseAuth.instance.currentUser?.uid;
                          if (uid == null) return;
                          try {
                            final uDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
                            final uName = (uDoc.data()?['nickname'] as String?) ?? '名無し';
                            await FirebaseFirestore.instance.collection('posts').doc(postId).collection('comments').add({
                              'userId': uid,
                              'userNickname': uName,
                              'text': txt,
                              'createdAt': FieldValue.serverTimestamp(),
                            });
                          } catch (_) {
                            // Silently handle - comment will not appear but app won't crash
                          }
                        },
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(Icons.send, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    )).then((_) => commentController.dispose());
  }
  Widget _buildStaticActionButton(IconData icon, String count) {
    return Row(
      children: [
        Icon(icon, size: 22, color: AppTheme.textSecondary),
        if (count.isNotEmpty && count != '0') ...[
          const SizedBox(width: 4),
          Text(count,
              style: const TextStyle(
                  fontSize: 14, color: AppTheme.textSecondary)),
        ],
      ],
    );
  }

  Widget _buildPostMenu(String postId, bool isMyPost) {
    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (ctx) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    if (isMyPost) ...[
                      ListTile(
                        leading: const Icon(Icons.delete_outline,
                            color: AppTheme.error),
                        title: const Text('投稿を削除',
                            style: TextStyle(
                                color: AppTheme.error,
                                fontWeight: FontWeight.w600)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showDeletePostDialog(postId);
                        },
                      ),
                    ],
                    if (!isMyPost) ...[
                      ListTile(
                        leading: Icon(Icons.flag_outlined,
                            color: AppTheme.textSecondary),
                        title: const Text('この投稿を報告'),
                        onTap: () {
                          Navigator.pop(ctx);
                          _reportPost(postId);
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.visibility_off_outlined,
                            color: AppTheme.textSecondary),
                        title: const Text('この投稿を非表示'),
                        onTap: () {
                          Navigator.pop(ctx);
                          _hidePost(postId);
                        },
                      ),
                    ],
                    ListTile(
                      leading: Icon(Icons.close,
                          color: AppTheme.textSecondary),
                      title: const Text('キャンセル'),
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(Icons.more_horiz,
            size: 20, color: AppTheme.textSecondary),
      ),
    );
  }

  Future<void> _reportPost(String postId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final reasons = [
      'スパム・迷惑行為',
      '不適切なコンテンツ',
      'なりすまし',
      'ハラスメント',
      'その他',
    ];

    final selectedReason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('報告の理由を選択',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              ...reasons.map((reason) => ListTile(
                    title: Text(reason),
                    onTap: () => Navigator.pop(ctx, reason),
                  )),
            ],
          ),
        ),
      ),
    );

    if (selectedReason == null) return;

    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'postId': postId,
        'reporterId': uid,
        'reason': selectedReason,
        'type': 'post',
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('報告を受け付けました。ご協力ありがとうございます。'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('報告に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _hidePost(String postId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // UI即時更新
    setState(() => _hiddenPostIds.add(postId));
    try {
      await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('hiddenPosts').doc(postId)
          .set({'hiddenAt': FieldValue.serverTimestamp()});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('この投稿を非表示にしました'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hiddenPostIds.remove(postId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('非表示に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  void _showDeletePostDialog(String postId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('投稿を削除',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text(
            'この投稿を削除しますか？\nこの操作は取り消せません。',
            style: TextStyle(height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('キャンセル',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await FirebaseFirestore.instance
                    .collection('posts')
                    .doc(postId)
                    .delete();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('投稿を削除しました'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('削除に失敗しました: $e'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              minimumSize: const Size(100, 40),
            ),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeTabLabel() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Text('お知らせ');
    return StreamBuilder<int>(
      stream: NotificationService.unreadAnnouncementCountStream(uid),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('お知らせ'),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.error,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildNoticeTab() {
    return Stack(
      children: [
        Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
              ),
              child: TabBar(
                controller: _noticeSubTabController,
                labelColor: AppTheme.primaryColor,
                unselectedLabelColor: AppTheme.textSecondary,
                indicatorColor: AppTheme.primaryColor,
                indicatorWeight: 2.5,
                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                unselectedLabelStyle: const TextStyle(fontSize: 13),
                tabs: const [
                  Tab(text: '運営'),
                  Tab(text: 'あなた宛'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _noticeSubTabController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildOfficialNotices(),
                  _buildPersonalNotices(),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOfficialNotices() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('notices')
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('読み込みに失敗しました', style: TextStyle(color: AppTheme.textSecondary)));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }
        final allDocs = snap.data!.docs;
        // 配信対象 OS でフィルタ（iOS/Android 指定のお知らせは該当ユーザのみ表示）
        final docs = allDocs.where((d) {
          final data = d.data() as Map<String, dynamic>? ?? {};
          final platform = data['platform'] as String?;
          if (platform == null || platform == 'all') return true;
          if (kIsWeb) return false;
          if (platform == 'ios') return defaultTargetPlatform == TargetPlatform.iOS;
          if (platform == 'android') return defaultTargetPlatform == TargetPlatform.android;
          return true;
        }).toList();
        if (docs.isEmpty) {
          return const EmptyStateView(
            icon: Icons.campaign_outlined,
            title: '運営からのお知らせはありません',
          );
        }
        // ピン留めされたお知らせを上部に表示
        final sortedDocs = List<QueryDocumentSnapshot>.from(docs);
        sortedDocs.sort((a, b) {
          final aData = a.data() as Map<String, dynamic>? ?? {};
          final bData = b.data() as Map<String, dynamic>? ?? {};
          final aPinned = aData['pinned'] == true ? 1 : 0;
          final bPinned = bData['pinned'] == true ? 1 : 0;
          if (aPinned != bPinned) return bPinned - aPinned;
          return 0; // Firestore の createdAt 降順を維持
        });
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: sortedDocs.length,
          itemBuilder: (context, index) {
            final data = sortedDocs[index].data() as Map<String, dynamic>? ?? {};
            final type = data['type'] ?? 'info';
            final isPinned = data['pinned'] == true;
            IconData icon;
            Color color;
            switch (type) {
              case 'release':
                icon = Icons.campaign;
                color = AppTheme.accentColor;
                break;
              case 'update':
                icon = Icons.update;
                color = AppTheme.info;
                break;
              case 'maintenance':
                icon = Icons.build;
                color = AppTheme.warning;
                break;
              default:
                icon = Icons.info_outline;
                color = AppTheme.primaryColor;
            }
            final rawLink = data['link'];
            final link = (rawLink is String && rawLink.isNotEmpty) ? rawLink : null;
            final rawLinkLabel = data['linkLabel'];
            final linkLabel = (rawLinkLabel is String && rawLinkLabel.isNotEmpty)
                ? rawLinkLabel
                : null;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildOfficialNotice(
                icon: icon,
                color: color,
                title: data['title'] ?? '',
                body: data['body'] ?? '',
                time: _formatTime(data['createdAt'] as Timestamp?),
                isRead: true,
                isPinned: isPinned,
                link: link,
                linkLabel: linkLabel,
                onTap: link != null ? () => _openNoticeLink(link) : null,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPersonalNotices() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return Center(child: Text('ログインしてください', style: TextStyle(color: AppTheme.textSecondary)));
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .where('type', whereIn: NotificationService.announcementTypes)
          .orderBy('createdAt', descending: true)
          .limit(30)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('読み込みに失敗しました', style: TextStyle(color: AppTheme.textSecondary)));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const EmptyStateView(
            icon: Icons.notifications_none,
            title: 'あなた宛の通知はありません',
          );
        }
        _markAnnouncementsAsRead();
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>? ?? {};
            final type = data['type'] ?? '';
            final bool isRead = data['read'] ?? true;
            IconData icon;
            Color color;
            String title;
            switch (type) {
              case 'tournament_announcement':
                icon = Icons.campaign;
                color = AppTheme.accentColor;
                title = '大会お知らせ';
                break;
              case 'tournament_end':
                icon = Icons.emoji_events;
                color = AppTheme.accentColor;
                title = '大会終了';
                break;
              case 'waitlist_available':
                icon = Icons.how_to_reg;
                color = AppTheme.success;
                title = 'キャンセル待ち';
                break;
              case 'points_earned':
                icon = Icons.star_rounded;
                color = AppTheme.accentColor;
                title = 'ポイント獲得';
                break;
              case 'tournament_created':
                icon = Icons.sports_volleyball;
                color = AppTheme.primaryColor;
                title = '募集開始';
                break;
              case 'deadline_approaching':
                icon = Icons.schedule;
                color = AppTheme.warning;
                title = '締切間近';
                break;
              case 'slots_low':
                icon = Icons.group;
                color = AppTheme.error;
                title = '残りわずか';
                break;
              case 'entry_invite':
                icon = Icons.how_to_reg;
                color = AppTheme.primaryColor;
                title = '大会エントリー招待';
                break;
              default:
                icon = Icons.info_outline;
                color = AppTheme.primaryColor;
                title = 'お知らせ';
            }
            // entry_invite の message は「が大会「X」に招待しました」のように
            // 送信者名に続く体言止めなので、誰からの招待か一目でわかるよう
            // アバター＋太字の名前を添える
            final senderName = type == 'entry_invite' ? (data['senderName'] ?? '').toString() : '';
            final senderAvatar = type == 'entry_invite' ? (data['senderAvatar'] ?? '').toString() : '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildOfficialNotice(
                icon: icon,
                color: color,
                title: title,
                body: (data['message'] ?? '').toString(),
                time: _formatTime(data['createdAt'] as Timestamp?),
                isRead: isRead,
                senderName: senderName.isNotEmpty ? senderName : null,
                senderAvatar: senderAvatar.isNotEmpty ? senderAvatar : null,
                onTap: () => _onAnnouncementTap(data),
              ),
            );
          },
        );
      },
    );
  }



  Future<void> _markAnnouncementsAsRead() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final unread = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .where('read', isEqualTo: false)
        .where('type', whereIn: NotificationService.announcementTypes)
        .get();
    if (unread.docs.isEmpty) return;
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in unread.docs) {
      batch.update(doc.reference, {'read': true});
    }
    await batch.commit();
    PushNotificationService.updateBadgeCount();
  }

  Future<void> _onAnnouncementTap(Map<String, dynamic> data) async {
    final type = data['type'] ?? '';
    final tournamentId = data['tournamentId'] as String?;

    if (type == 'tournament_end' &&
        tournamentId != null &&
        tournamentId.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('tournaments')
            .doc(tournamentId)
            .get();
        if (!doc.exists || !mounted) return;
        final tData = doc.data() ?? {};
        final tournamentName =
            (tData['title'] ?? tData['name'] ?? '') as String;

        String? myResult;
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          final entries = await FirebaseFirestore.instance
              .collection('tournaments')
              .doc(tournamentId)
              .collection('entries')
              .get();
          for (final entry in entries.docs) {
            final memberUids = entry.data()['memberUids'] as List?;
            if (memberUids != null && memberUids.contains(uid)) {
              final rank = entry.data()['finalRank'];
              if (rank is int) {
                if (rank == 1) myResult = '優勝';
                else if (rank == 2) myResult = '準優勝';
                else if (rank == 3) myResult = '3位';
                else myResult = '$rank位';
              }
              break;
            }
          }
        }

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PostEventActionScreen(
              tournamentId: tournamentId,
              tournamentName: tournamentName,
              result: myResult,
            ),
          ),
        );
      } catch (e) {
        debugPrint('ふりかえり画面遷移に失敗: $e');
      }
      return;
    }

    if (type == 'entry_invite' && (data['canceled'] == true || data['resolved'] == true)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(data['canceled'] == true ? 'この招待は取り消されました' : 'この招待は対応済みです'),
        backgroundColor: AppTheme.textSecondary,
      ));
      return;
    }

    if ((type == 'tournament_announcement' ||
            type == 'waitlist_available' ||
            type == 'points_earned' ||
            type == 'tournament_created' ||
            type == 'deadline_approaching' ||
            type == 'slots_low' ||
            type == 'entry_invite') &&
        tournamentId != null &&
        tournamentId.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('tournaments')
            .doc(tournamentId)
            .get();
        if (!doc.exists || !mounted) return;
        final tData = doc.data() ?? {};
        tData['id'] = doc.id;
        tData['name'] = tData['title'] ?? tData['name'] ?? '';
        final initialTab =
            type == 'tournament_announcement' ? 'board' : null;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TournamentDetailScreen(
              tournament: tData,
              initialTab: initialTab,
            ),
          ),
        );
      } catch (e) {
        debugPrint('大会遷移に失敗: $e');
      }
    }
  }

  Future<void> _openNoticeLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('リンクを開けませんでした'), backgroundColor: AppTheme.error),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('リンクを開けませんでした'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Widget _buildOfficialNotice({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    required String time,
    bool isRead = true,
    bool isPinned = false,
    String? link,
    String? linkLabel,
    String? senderName,
    String? senderAvatar,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isPinned
              ? AppTheme.primaryColor.withValues(alpha: 0.04)
              : isRead
                  ? Colors.white
                  : AppTheme.primaryColor.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isPinned
                ? AppTheme.primaryColor.withValues(alpha: 0.3)
                : isRead
                    ? Colors.grey[200]!
                    : AppTheme.primaryColor.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            (senderName != null && senderName.isNotEmpty)
                // 差出人がいる通知（招待など）は、誰からかが一目でわかるようアバター＋種類バッジにする
                ? Stack(clipBehavior: Clip.none, children: [
                    (senderAvatar != null && senderAvatar.isNotEmpty)
                        ? CircleAvatar(
                            radius: 20,
                            backgroundImage: NetworkImage(senderAvatar),
                          )
                        : CircleAvatar(
                            radius: 20,
                            backgroundColor: color.withValues(alpha: 0.12),
                            child: Text(senderName[0],
                                style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                          ),
                    Positioned(
                      bottom: -2,
                      right: -2,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: Icon(icon, size: 14, color: color),
                      ),
                    ),
                  ])
                : Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (isPinned) ...[
                        Icon(Icons.push_pin, size: 14, color: AppTheme.primaryColor),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(title,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: AppTheme.textPrimary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  (senderName != null && senderName.isNotEmpty)
                      ? RichText(
                          text: TextSpan(
                            style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
                            children: [
                              TextSpan(text: senderName, style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                              TextSpan(text: ' $body'),
                            ],
                          ),
                        )
                      : Text(body,
                          style: const TextStyle(
                              fontSize: 14,
                              color: AppTheme.textSecondary)),
                  if (link != null && link.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Builder(builder: (_) {
                      final String url = link;
                      final String label = (linkLabel != null && linkLabel.isNotEmpty)
                          ? linkLabel
                          : '詳細を見る';
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: ElevatedButton.icon(
                          onPressed: () => _openNoticeLink(url),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: Text(
                            label,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: color,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            minimumSize: const Size(0, 34),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 6),
                  Text(time,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textHint)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _safeString(dynamic value, String fallback) {
    if (value is String && value.isNotEmpty) return value;
    return fallback;
  }

  int _safeInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    return 0;
  }

  String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return 'たった今';
    final now = DateTime.now();
    final date = timestamp.toDate();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'たった今';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 7) return '${diff.inDays}日前';
    return '${date.month}/${date.day}';
  }
}

// ── X風フルスクリーン画像ビューア ──
class _FullScreenImageViewer extends StatefulWidget {
  final List<ImageProvider> images;
  final int initialIndex;

  const _FullScreenImageViewer({
    required this.images,
    required this.initialIndex,
  });

  @override
  State<_FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<_FullScreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;
  double _verticalDrag = 0;
  double _opacity = 1.0;

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

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() {
      _verticalDrag += details.delta.dy;
      _opacity = (1 - (_verticalDrag.abs() / 300)).clamp(0.3, 1.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_verticalDrag.abs() > 100) {
      Navigator.pop(context);
    } else {
      setState(() {
        _verticalDrag = 0;
        _opacity = 1.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: _opacity),
      body: GestureDetector(
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        child: Stack(
          children: [
            // 画像 PageView
            Transform.translate(
              offset: Offset(0, _verticalDrag),
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.images.length,
                onPageChanged: (i) => setState(() => _currentIndex = i),
                itemBuilder: (_, i) => Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image(
                      image: widget.images[i],
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            // 閉じるボタン
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 12,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 22),
                ),
              ),
            ),
            // ページインジケーター (2枚以上の場合のみ)
            if (widget.images.length > 1)
              Positioned(
                top: MediaQuery.of(context).padding.top + 14,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_currentIndex + 1} / ${widget.images.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
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
