import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';
import '../../widgets/empty_state_view.dart';
import '../../widgets/official_badge.dart';
import '../../widgets/certified_badge.dart';
import '../../services/bookmark_notification_service.dart';
import '../../utils/tournament_status.dart';
import 'tournament_detail_screen.dart';
import '../chat/chat_screen.dart';
import '../profile/user_profile_screen.dart';

class TournamentSearchScreen extends StatefulWidget {
  const TournamentSearchScreen({super.key});
  @override
  State<TournamentSearchScreen> createState() => _TournamentSearchScreenState();
}

class _TournamentSearchScreenState extends State<TournamentSearchScreen>
    with TickerProviderStateMixin {
  User? get _currentUser => FirebaseAuth.instance.currentUser;
  final _searchController = TextEditingController();
  Set<String> _followingIds = {};
  Set<String> _bookmarkedTournaments = {};
  Set<String> _bookmarkedRecruits = {};

  // ── Top-level swipeable page (0=tournament, 1=recruitment) ──
  late TabController _tabController;
  int _currentPage = 0;

  // ── Sub-tab: friends-only toggle ──
  bool _friendsOnly = true;

  // ── Saved mode ──
  bool _isSavedMode = false;
  bool _savedFilterTournament = true;
  bool _savedFilterRecruitment = true;

  // ── Filters ──
  bool _showFilter = false;
  String _filterType = 'すべて';
  String _filterArea = 'すべて';
  DateTimeRange? _filterDateRange;
  bool _showPastTournaments = false;

  // ── Organizer avatar/name cache ──
  final Map<String, String> _organizerAvatarCache = {};
  final Map<String, String> _organizerNameCache = {};
  final Map<String, bool> _officialCache = {};

  // ── Debounce timer for search ──
  Timer? _debounceTimer;

  // ── Cached Firestore streams (prevent recreation on rebuild) ──
  late Stream<QuerySnapshot> _tournamentStream;
  late Stream<QuerySnapshot> _recruitmentStream;

  /// 公式アカウントは「さがす」で準備中・締切後・終了などステータス除外を行わず閲覧できる。
  /// 開催中・決勝中・順位決定中は公式のみ一覧表示（フォロー中／みんなの切り替えは適用しない）。
  bool _isOfficialAccount = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index != _currentPage) {
        setState(() => _currentPage = _tabController.index);
      }
    });
    _refreshStreams();
    _loadFollowing();
    _loadBookmarks();
    _loadOfficialFlag();
  }

  Future<void> _loadOfficialFlag() async {
    final uid = _currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (mounted) {
        setState(() => _isOfficialAccount = doc.data()?['isOfficial'] == true);
      }
    } catch (_) {}
  }

  void _refreshStreams() {
    _tournamentStream = _buildTournamentQuery().snapshots();
    _recruitmentStream = _buildRecruitQuery().snapshots();
  }

  Future<void> _loadFollowing() async {
    final user = _currentUser;
    if (user == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('users').doc(user.uid).collection('following').get();
    if (mounted) {
      setState(() {
        _followingIds = snap.docs.map((d) => d.id).toSet();
      });
    }
  }

  Future<void> _loadBookmarks() async {
    final user = _currentUser;
    if (user == null) return;
    final tSnap = await FirebaseFirestore.instance
        .collection('users').doc(user.uid).collection('bookmarks')
        .where('type', isEqualTo: 'tournament').get();
    final rSnap = await FirebaseFirestore.instance
        .collection('users').doc(user.uid).collection('bookmarks')
        .where('type', isEqualTo: 'recruitment').get();
    if (mounted) {
      setState(() {
        _bookmarkedTournaments = tSnap.docs.map((d) => (d.data()['targetId'] ?? '') as String).toSet();
        _bookmarkedRecruits = rSnap.docs.map((d) => (d.data()['targetId'] ?? '') as String).toSet();
      });
    }
  }

  Future<void> _toggleTournamentBookmark(String docId, Map<String, dynamic> meta) async {
    final user = _currentUser;
    if (user == null) return;
    await BookmarkNotificationService.toggleBookmark(
        uid: user.uid, targetId: docId, type: 'tournament', metadata: meta);
    setState(() {
      if (_bookmarkedTournaments.contains(docId)) {
        _bookmarkedTournaments.remove(docId);
      } else {
        _bookmarkedTournaments.add(docId);
      }
    });
  }

  Future<void> _toggleRecruitBookmark(String targetId, Map<String, dynamic> meta) async {
    final user = _currentUser;
    if (user == null) return;
    await BookmarkNotificationService.toggleBookmark(
        uid: user.uid, targetId: targetId, type: 'recruitment', metadata: meta);
    setState(() {
      if (_bookmarkedRecruits.contains(targetId)) {
        _bookmarkedRecruits.remove(targetId);
      } else {
        _bookmarkedRecruits.add(targetId);
      }
    });
  }

  Future<void> _applyToRecruitment(String recruiterId, String recruiterName, String tournamentName) async {
    if (_currentUser == null || recruiterId == _currentUser!.uid) return;
    final myUid = _currentUser!.uid;

    // 既存のDMを探す
    final existing = await FirebaseFirestore.instance
        .collection('chats')
        .where('type', isEqualTo: 'dm')
        .where('members', arrayContains: myUid)
        .get();

    String? chatId;
    for (final doc in existing.docs) {
      final members = List<String>.from(doc['members'] ?? []);
      if (members.contains(recruiterId)) {
        chatId = doc.id;
        break;
      }
    }

    // DMが無ければ作成
    if (chatId == null) {
      final myDoc = await FirebaseFirestore.instance.collection('users').doc(myUid).get();
      final myName = (myDoc.data()?['nickname'] as String?) ?? '自分';

      final ref = await FirebaseFirestore.instance.collection('chats').add({
        'type': 'dm',
        'members': [myUid, recruiterId],
        'memberNames': {myUid: myName, recruiterId: recruiterName},
        'lastMessage': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      chatId = ref.id;
    }

    // 自動メッセージを送信
    final myDoc = await FirebaseFirestore.instance.collection('users').doc(myUid).get();
    final myName = (myDoc.data()?['nickname'] as String?) ?? '自分';
    final messageText = tournamentName.isNotEmpty
        ? '「$tournamentName」のメンバー募集に応募します！よろしくお願いします。'
        : 'メンバー募集に応募します！よろしくお願いします。';

    await FirebaseFirestore.instance
        .collection('chats').doc(chatId).collection('messages').add({
      'senderId': myUid,
      'senderName': myName,
      'type': 'text',
      'text': messageText,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await FirebaseFirestore.instance.collection('chats').doc(chatId).update({
      'lastMessage': messageText,
      'lastMessageAt': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatId: chatId!,
          chatTitle: recruiterName,
          chatType: 'dm',
          otherUserId: recruiterId,
        ),
      ));
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  DateTime? _parseDate(String dateStr) {
    try {
      final p = dateStr.split('/');
      if (p.length >= 3) return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    } catch (_) {}
    return null;
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'メンズ': return Colors.blue[600]!;
      case 'レディース': return Colors.pink[400]!;
      case '混合': return Colors.green[600]!;
      default: return AppTheme.textSecondary;
    }
  }

  bool get _hasActiveFilter =>
      _filterType != 'すべて' || _filterArea != 'すべて' || _filterDateRange != null || _showPastTournaments;

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // BUILD
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          _buildHeader(),
          if (_showFilter && !_isSavedMode) _buildFilterPanel(),
          Expanded(child: _buildContent()),
        ]),
      ),
      // 保存済み切替はヘッダー（トグルの左）に移動したため FAB は廃止
    );
  }

  // 保存済み表示の切替ボタン（しおり型ブックマーク）。
  // 通常時は輪郭、保存済み表示中はネイビー塗りで状態を示す。
  Widget _buildSaveToggleButton() {
    return GestureDetector(
      onTap: () => setState(() => _isSavedMode = !_isSavedMode),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: _isSavedMode
              ? AppTheme.primaryColor
              : AppTheme.primaryColor.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Icon(
          _isSavedMode ? Icons.bookmark : Icons.bookmark_border,
          color: _isSavedMode ? Colors.white : AppTheme.primaryColor,
          size: 22,
        ),
      ),
    );
  }

  // ━━━ ヘッダー ━━━
  Widget _buildHeader() {
    return Material(
      color: Colors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Title + toggle
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Text(
                  _isSavedMode ? '保存済み' : 'さがす',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                ),
              ),
              // 右側クラスタ（保存ボタン＋トグル）を1つの FittedBox にまとめ、
              // 余白は Expanded が吸収。狭い端末（iPhone SE 等）で溢れる時だけ
              // クラスタ全体を縮小して逃がす（通常端末では等倍のまま右寄せ）。
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 保存済み切替（旧・下部FAB）。フォロー中/みんな トグルの左に配置
                      _buildSaveToggleButton(),
                      if (!_isSavedMode) const SizedBox(width: 8),
                      if (!_isSavedMode) _buildCompactToggle(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
        const SizedBox(height: 12),

        // ── メイン切替タブ (underline style) ──
        if (!_isSavedMode) ...[
          TabBar(
            controller: _tabController,
            labelColor: AppTheme.textPrimary,
            unselectedLabelColor: AppTheme.textSecondary,
            labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
            indicatorColor: AppTheme.primaryColor,
            indicatorWeight: 3,
            dividerColor: Colors.grey[200],
            tabs: const [
              Tab(text: '大会をさがす'),
              Tab(text: 'メンバーをさがす'),
            ],
          ),
          const SizedBox(height: 10),

          // ── 検索バー + フィルターボタン ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: _currentPage == 0
                          ? '大会名・会場名で検索'
                          : '名前・大会名で検索',
                      hintStyle: const TextStyle(fontSize: 14, color: AppTheme.textHint),
                      prefixIcon: const Icon(Icons.search, size: 20, color: AppTheme.textHint),
                      filled: true,
                      fillColor: AppTheme.backgroundColor,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (_) {
                      _debounceTimer?.cancel();
                      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
                        if (mounted) setState(() {});
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _showFilter = !_showFilter),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _hasActiveFilter ? AppTheme.primaryColor : AppTheme.backgroundColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(alignment: Alignment.center, children: [
                    Icon(Icons.tune, size: 20,
                        color: _hasActiveFilter ? Colors.white : AppTheme.textSecondary),
                    if (_hasActiveFilter)
                      Positioned(right: 6, top: 6, child: Container(
                        width: 7, height: 7,
                        decoration: const BoxDecoration(color: AppTheme.error, shape: BoxShape.circle),
                      )),
                  ]),
                ),
              ),
            ]),
          ),
        ],

        const SizedBox(height: 8),
      ]),
    );
  }

  // ── Compact toggle (右上の切替ボタン) ──
  Widget _buildCompactToggle() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _compactToggleButton(Icons.people, 'フォロー中', true),
        _compactToggleButton(Icons.public, 'みんな', false),
      ]),
    );
  }

  Widget _compactToggleButton(IconData icon, String label, bool isFriendsValue) {
    final isActive = _friendsOnly == isFriendsValue;
    return GestureDetector(
      onTap: () => setState(() => _friendsOnly = isFriendsValue),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.primaryColor : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: isActive ? Colors.white : AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              color: isActive ? Colors.white : AppTheme.textSecondary,
            ),
          ),
        ]),
      ),
    );
  }

  // ━━━ フィルターパネル ━━━
  Widget _buildFilterPanel() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Divider(height: 1),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _filterChip(
              Icons.sports_volleyball,
              _filterType == 'すべて' ? '種別' : _filterType,
              _filterType != 'すべて',
              color: _filterType != 'すべて' ? _typeColor(_filterType) : null,
              onTap: _showTypeFilter,
            ),
            const SizedBox(width: 8),
            _filterChip(
              Icons.location_on_outlined,
              _filterArea == 'すべて' ? 'エリア' : _filterArea,
              _filterArea != 'すべて',
              onTap: _showAreaFilter,
            ),
            const SizedBox(width: 8),
            _filterChip(
              Icons.calendar_month_outlined,
              _filterDateRange != null
                  ? '${_filterDateRange!.start.month}/${_filterDateRange!.start.day}〜${_filterDateRange!.end.month}/${_filterDateRange!.end.day}'
                  : '日付',
              _filterDateRange != null,
              onTap: _showDateFilter,
            ),
          ]),
        ),
        if (_currentPage == 0) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() => _showPastTournaments = !_showPastTournaments),
            child: Row(children: [
              SizedBox(width: 20, height: 20, child: Checkbox(
                value: _showPastTournaments,
                onChanged: (v) => setState(() => _showPastTournaments = v ?? false),
                activeColor: AppTheme.primaryColor,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )),
              const SizedBox(width: 8),
              const Text('終了した大会も表示', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
          ),
        ],
        if (_hasActiveFilter) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() {
              _filterType = 'すべて';
              _filterArea = 'すべて';
              _filterDateRange = null;
              _showPastTournaments = false;
              _refreshStreams();
            }),
            child: Row(children: [
              Icon(Icons.refresh, size: 14, color: AppTheme.error),
              const SizedBox(width: 4),
              Text('フィルターをリセット',
                  style: TextStyle(fontSize: 12, color: AppTheme.error, fontWeight: FontWeight.w600)),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _filterChip(IconData icon, String label, bool isActive, {Color? color, required VoidCallback onTap}) {
    final c = color ?? AppTheme.primaryColor;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? c.withValues(alpha: 0.08) : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isActive ? c : Colors.grey[300]!, width: isActive ? 1.5 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: isActive ? c : AppTheme.textSecondary),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: isActive ? c : AppTheme.textSecondary,
          )),
          const SizedBox(width: 3),
          Icon(Icons.keyboard_arrow_down, size: 14, color: isActive ? c : AppTheme.textHint),
        ]),
      ),
    );
  }

  void _showTypeFilter() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          const Text('種別で絞り込み', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ...['すべて', '混合', 'メンズ', 'レディース'].map((t) {
            final isSelected = _filterType == t;
            final c = t == 'すべて' ? AppTheme.textSecondary : _typeColor(t);
            return ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: c.withValues(alpha: 0.12),
                child: Icon(t == 'すべて' ? Icons.all_inclusive : Icons.circle, color: c, size: 14),
              ),
              title: Text(t, style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? c : AppTheme.textPrimary,
              )),
              trailing: isSelected ? Icon(Icons.check_circle, color: c) : null,
              onTap: () { setState(() { _filterType = t; _refreshStreams(); }); Navigator.pop(ctx); },
            );
          }),
        ]),
      ),
    );
  }

  void _showAreaFilter() {
    final areas = ['すべて', '北海道', '東北', '関東', '中部', '近畿', '中国', '四国', '九州・沖縄'];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          const Text('エリアで絞り込み', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Flexible(child: ListView(shrinkWrap: true, children: areas.map((a) => ListTile(
            dense: true,
            leading: Icon(
              a == 'すべて' ? Icons.public : Icons.location_on_outlined,
              color: _filterArea == a ? AppTheme.primaryColor : AppTheme.textSecondary,
              size: 20,
            ),
            title: Text(a, style: TextStyle(
              fontWeight: _filterArea == a ? FontWeight.bold : FontWeight.normal,
              color: _filterArea == a ? AppTheme.primaryColor : AppTheme.textPrimary,
            )),
            trailing: _filterArea == a ? const Icon(Icons.check_circle, color: AppTheme.primaryColor) : null,
            onTap: () { setState(() => _filterArea = a); Navigator.pop(ctx); },
          )).toList())),
        ]),
      ),
    );
  }

  void _showDateFilter() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365)),
      initialDateRange: _filterDateRange,
      locale: const Locale('ja'),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.light(
            primary: AppTheme.primaryColor,
            onPrimary: Colors.white,
            surface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (range != null) setState(() => _filterDateRange = range);
  }

  // ━━━ コンテンツ ━━━
  Widget _buildContent() {
    if (_isSavedMode) return _buildSavedList();

    // Swipeable TabBarView for tournament / recruitment
    return TabBarView(
      controller: _tabController,
      children: [
        _KeepAlivePage(child: _buildTournamentList(_friendsOnly)),
        _KeepAlivePage(child: _buildRecruitList(_friendsOnly)),
      ],
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 保存済み (Saved) - Improved UI
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildSavedList() {
    final user = _currentUser;
    if (user == null) {
      return const Center(
        child: Text('ログインしてください', style: TextStyle(color: AppTheme.textSecondary)),
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users').doc(user.uid)
          .collection('bookmarks').snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }

        final allDocs = snap.data?.docs ?? [];
        final tDocs = allDocs.where((d) => (d.data() as Map)['type'] == 'tournament').toList();
        final rDocs = allDocs.where((d) => (d.data() as Map)['type'] == 'recruitment').toList();

        if (allDocs.isEmpty) {
          return _buildSavedEmptyState();
        }

        // Build filtered items
        final List<DocumentSnapshot> visibleItems = [];
        if (_savedFilterTournament) visibleItems.addAll(tDocs);
        if (_savedFilterRecruitment) visibleItems.addAll(rDocs);

        return Column(children: [
          // ── Gradient header with counts ──
          _buildSavedHeader(tDocs.length, rDocs.length),

          // ── Filter toggle chips ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              _savedToggleChip(
                icon: Icons.emoji_events,
                label: '大会',
                count: tDocs.length,
                isActive: _savedFilterTournament,
                color: AppTheme.primaryColor,
                onTap: () => setState(() => _savedFilterTournament = !_savedFilterTournament),
              ),
              const SizedBox(width: 10),
              _savedToggleChip(
                icon: Icons.people,
                label: 'メンバー募集',
                count: rDocs.length,
                isActive: _savedFilterRecruitment,
                color: AppTheme.accentColor,
                onTap: () => setState(() => _savedFilterRecruitment = !_savedFilterRecruitment),
              ),
            ]),
          ),

          // ── List ──
          Expanded(
            child: visibleItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.filter_list_off, size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text(
                          'フィルターを調整してください',
                          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 92 + MediaQuery.of(context).padding.bottom),
                    itemCount: visibleItems.length,
                    itemBuilder: (ctx, i) {
                      final doc = visibleItems[i];
                      final data = doc.data() as Map<String, dynamic>;
                      final type = data['type'] ?? '';

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Dismissible(
                          key: Key(doc.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [AppTheme.error.withValues(alpha: 0.05), AppTheme.error.withValues(alpha: 0.15)],
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.delete_outline, color: AppTheme.error, size: 24),
                                const SizedBox(height: 2),
                                Text('削除', style: TextStyle(fontSize: 11, color: AppTheme.error, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                          confirmDismiss: (direction) async {
                            return await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                title: const Text('保存を解除', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                content: const Text('このブックマークを削除しますか？', style: TextStyle(fontSize: 14)),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('削除', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                            ) ?? false;
                          },
                          onDismissed: (_) async {
                            await doc.reference.delete();
                            _loadBookmarks();
                          },
                          child: type == 'tournament'
                              ? _buildSavedTournamentCard(doc)
                              : _buildSavedRecruitCard(doc),
                        ),
                      );
                    },
                  ),
          ),
        ]);
      },
    );
  }

  // ── Gradient header with bookmark counts ──
  Widget _buildSavedHeader(int tournamentCount, int recruitCount) {
    final total = tournamentCount + recruitCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primaryColor, AppTheme.primaryLight],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryColor.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.bookmark, color: Colors.white, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '$total件保存中',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.emoji_events, size: 13, color: Colors.white.withValues(alpha: 0.8)),
              const SizedBox(width: 4),
              Text(
                '大会 $tournamentCount件',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85)),
              ),
              const SizedBox(width: 12),
              Icon(Icons.people, size: 13, color: Colors.white.withValues(alpha: 0.8)),
              const SizedBox(width: 4),
              Text(
                '募集 $recruitCount件',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85)),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }

  // ── Toggle chip for saved filter ──
  Widget _savedToggleChip({
    required IconData icon,
    required String label,
    required int count,
    required bool isActive,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? color.withValues(alpha: 0.1) : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? color.withValues(alpha: 0.5) : Colors.grey[300]!,
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: isActive ? color : AppTheme.textHint),
          const SizedBox(width: 6),
          Text(
            '$label ($count)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              color: isActive ? color : AppTheme.textHint,
            ),
          ),
        ]),
      ),
    );
  }

  // ── Better empty state for saved view ──
  Widget _buildSavedEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.bookmark_outline, size: 48, color: AppTheme.accentColor.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 20),
          const Text(
            '保存した大会・募集はありません',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            '気になる大会やメンバー募集のブックマークアイコンをタップして、ここに保存しましょう。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => setState(() => _isSavedMode = false),
            icon: const Icon(Icons.search, size: 18),
            label: const Text('大会をさがす'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primaryColor,
              side: const BorderSide(color: AppTheme.primaryColor),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              minimumSize: Size.zero,
            ),
          ),
        ]),
      ),
    );
  }

  // ── Saved tournament card (improved) ──
  Widget _buildSavedTournamentCard(DocumentSnapshot bmDoc) {
    final bm = bmDoc.data() as Map<String, dynamic>;
    final tid = bm['targetId'] ?? '';

    return FutureBuilder<DocumentSnapshot>(
      future: tid.isNotEmpty ? FirebaseFirestore.instance.collection('tournaments').doc(tid).get() : null,
      builder: (context, snap) {
        final tData = (snap.data?.exists == true) ? snap.data!.data() as Map<String, dynamic> : <String, dynamic>{};
        final title = tData['title'] ?? bm['title'] ?? '';
        final date = tData['date'] ?? bm['date'] ?? '';
        final location = tData['location'] ?? bm['location'] ?? '';
        final status = normalizeTournamentStatus(tData['status'] ?? bm['status'], emptyAsPreparing: false);
        final type = tData['type'] ?? bm['tournamentType'] ?? '';
        final currentTeams = tData['currentTeams'] ?? 0;
        final maxTeams = tData['maxTeams'] ?? 8;
        final organizerName = tData['organizerName'] ?? '不明';
        final organizerId = tData['organizerId'] ?? '';
        final deadline = tData['deadline'] ?? '';
        final rawEntryFee = tData['entryFee'];
        final entryFee = rawEntryFee is int ? '¥$rawEntryFee' : (rawEntryFee ?? '').toString();
        final isFollowing = _followingIds.contains(organizerId) || organizerId == _currentUser?.uid;
        final progress = maxTeams > 0 ? (currentTeams as num) / (maxTeams as num) : 0.0;

        Color sc;
        switch (status) {
          case '募集中':
            sc = AppTheme.success;
            break;
          case 'エントリー締切':
            sc = AppTheme.accentColor;
            break;
          case '大会準備中':
            sc = AppTheme.primaryLight;
            break;
          case '満員':
            sc = AppTheme.error;
            break;
          default:
            sc = AppTheme.textSecondary;
        }

        String day = '', month = '', weekday = '';
        try {
          final p = date.toString().split('/');
          if (p.length >= 3) {
            month = '${int.parse(p[1])}月';
            day = p[2];
            final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
            const w = ['月', '火', '水', '木', '金', '土', '日'];
            weekday = w[d.weekday - 1];
          }
        } catch (_) {}
        final tc = _typeColor(type);

        return GestureDetector(
          onTap: () async {
            if (tid.isNotEmpty) {
              final doc = await FirebaseFirestore.instance.collection('tournaments').doc(tid).get();
              if (doc.exists && mounted) {
                final data = doc.data() as Map<String, dynamic>;
                final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                final orgId = data['organizerId'] ?? '';
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => TournamentDetailScreen(tournament: {
                    ...data, 'id': tid, 'name': data['title'] ?? '',
                    'isFollowing': _followingIds.contains(orgId) || orgId == uid,
                    'status': normalizeTournamentStatus(data['status']),
                  }),
                ));
              }
            }
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey[200]!),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _dateBlock(month, day, weekday, sc, type, tc),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // タイトル + ステータス
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Row(children: [
                      Flexible(child: Text(title,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                          maxLines: 2, overflow: TextOverflow.ellipsis)),
                      if (tData['isCertified'] == true) const CertifiedBadge(size: 14),
                    ])),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: sc.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                      child: Text(status.isNotEmpty ? status : '---', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: sc)),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  // 主催者
                  if (organizerId.isNotEmpty) ...[
                    FutureBuilder<List<String>>(
                      future: Future.wait([_getOrganizerAvatar(organizerId), _getOrganizerName(organizerId, organizerName)]),
                      builder: (context, snap) {
                        final url = snap.data?[0] ?? '';
                        final displayName = snap.data?[1] ?? organizerName;
                        return Row(children: [
                      url.isNotEmpty
                          ? CircleAvatar(radius: 9, backgroundImage: NetworkImage(url))
                          : CircleAvatar(
                            radius: 9,
                            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                            child: Text(
                              displayName.isNotEmpty ? displayName[0] : '?',
                              style: const TextStyle(fontSize: 9, color: AppTheme.primaryColor, fontWeight: FontWeight.bold),
                            ),
                          ),
                      const SizedBox(width: 5),
                      Text(displayName, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      if (_officialCache[organizerId] == true)
                        const OfficialBadge(size: 13),
                      if (!isFollowing) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(4)),
                          child: Text('未フォロー', style: TextStyle(fontSize: 9, color: AppTheme.textHint)),
                        ),
                      ],
                    ]);
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                  // 会場
                  Row(children: [
                    Icon(Icons.location_on_outlined, size: 13, color: AppTheme.textSecondary),
                    const SizedBox(width: 4),
                    Flexible(child: Text(location,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        overflow: TextOverflow.ellipsis)),
                  ]),
                  // 締切・参加費
                  if (deadline.toString().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.timer_outlined, size: 13, color: AppTheme.warning),
                      const SizedBox(width: 4),
                      Text('締切 $deadline', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.warning)),
                      if (entryFee.toString().isNotEmpty) ...[
                        const SizedBox(width: 12),
                        Icon(Icons.payments_outlined, size: 13, color: AppTheme.textSecondary),
                        const SizedBox(width: 4),
                        Text(entryFee.toString(), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      ],
                    ]),
                  ] else if (entryFee.toString().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.payments_outlined, size: 13, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(entryFee.toString(), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ]),
                  ],
                  const SizedBox(height: 10),
                  // 参加チーム数バー + ブックマーク
                  StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('tournaments').doc(tid).collection('entries').snapshots(),
                    builder: (context, entriesSnap) {
                      final entryCount = entriesSnap.data?.docs.length ?? 0;
                      final entryProgress = maxTeams > 0 ? entryCount / (maxTeams as num) : 0.0;
                      return Row(children: [
                        Text('$entryCount/$maxTeams', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                        const SizedBox(width: 8),
                        Expanded(child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: entryProgress.toDouble().clamp(0.0, 1.0),
                            backgroundColor: Colors.grey[200],
                            valueColor: AlwaysStoppedAnimation<Color>(
                                entryProgress >= 1.0 ? AppTheme.error : entryProgress >= 0.8 ? AppTheme.warning : AppTheme.success),
                            minHeight: 5,
                          ),
                        )),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () => _toggleTournamentBookmark(tid, {
                            'title': title, 'date': date, 'location': location,
                            'tournamentType': type, 'status': status,
                          }),
                          child: Icon(Icons.bookmark, size: 28, color: AppTheme.accentColor),
                        ),
                      ]);
                    },
                  ),
                ])),
              ]),
            ),
          ),
        );
      },
    );
  }

  // ── Saved recruit card (improved) ──
  Widget _buildSavedRecruitCard(DocumentSnapshot bmDoc) {
    final bm = bmDoc.data() as Map<String, dynamic>;
    final nickname = bm['nickname'] ?? '?';
    final savedRecruiterId = bmDoc.id;
    if (savedRecruiterId.isNotEmpty && !_officialCache.containsKey(savedRecruiterId)) {
      _fetchOrganizerData(savedRecruiterId);
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: AppTheme.accentColor.withValues(alpha: 0.7), width: 4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppTheme.accentColor.withValues(alpha: 0.12),
                child: Text(
                  nickname.isNotEmpty ? nickname[0] : '?',
                  style: const TextStyle(
                    color: AppTheme.accentColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(
                  children: [
                    Flexible(child: Text(
                      nickname,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    )),
                    if (_officialCache[savedRecruiterId] == true)
                      const OfficialBadge(size: 14),
                  ],
                ),
                if ((bm['tournamentName'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.emoji_events, size: 13, color: AppTheme.primaryColor),
                    const SizedBox(width: 4),
                    Flexible(child: Text(
                      '${bm['tournamentName']} ${bm['tournamentDate'] ?? ''}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    )),
                  ]),
                ],
              ])),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.chevron_right, size: 18, color: AppTheme.accentColor),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Standard empty state used by search lists ──
  Widget _emptyState(IconData icon, String title, String sub) {
    return EmptyStateView(
      icon: icon,
      title: title,
      subtitle: sub.isNotEmpty ? sub : null,
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 大会リスト
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Query<Map<String, dynamic>> _buildTournamentQuery() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection('tournaments');
    if (_filterType != 'すべて') {
      q = q.where('type', isEqualTo: _filterType);
    }
    return q;
  }

  Widget _buildTournamentList(bool friendsOnly) {
    return StreamBuilder<QuerySnapshot>(
      stream: _tournamentStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }
        final allDocs = snapshot.data?.docs ?? [];
        final query = _searchController.text.toLowerCase();
        final now = DateTime.now();

        final filtered = allDocs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          // 体験デモ用の大会は一覧に出さない
          if (data['isDemo'] == true) return false;
          final oid = data['organizerId'] ?? '';
          final status = normalizeTournamentStatus(data['status']);
          final isF = _followingIds.contains(oid) || oid == _currentUser?.uid;
          final isInProgress = status == '開催中' ||
              status == '決勝中' ||
              status == '順位決定中';
          if (isInProgress) {
            if (!_isOfficialAccount) return false;
            // 公式: 進行中はフォロー中／みんなに関係なく表示（下のフォロー判定をスキップ）
          } else {
            if (friendsOnly ? !isF : isF) return false;
          }
          if (!_isOfficialAccount) {
            if (status == 'エントリー締切') return false;
            if (status == '終了' && !_showPastTournaments) return false;
            if (status == '準備中') return false;
          }
          if (query.isNotEmpty) {
            final t = (data['title'] ?? '').toString().toLowerCase();
            final l = (data['location'] ?? '').toString().toLowerCase();
            if (!t.contains(query) && !l.contains(query)) return false;
          }
          if (_filterArea != 'すべて') {
            final l = (data['location'] ?? '').toString();
            if (!l.contains(_filterArea)) return false;
          }
          if (_filterDateRange != null) {
            final d = _parseDate(data['date'] ?? '');
            if (d == null || d.isBefore(_filterDateRange!.start) || d.isAfter(_filterDateRange!.end)) return false;
          }
          return true;
        }).toList();

        // 日付が近い順
        filtered.sort((a, b) {
          final da = _parseDate((a.data() as Map)['date'] ?? '') ?? DateTime(2099);
          final db = _parseDate((b.data() as Map)['date'] ?? '') ?? DateTime(2099);
          return da.difference(now).inDays.abs().compareTo(db.difference(now).inDays.abs());
        });

        if (filtered.isEmpty) {
          return _emptyState(
            friendsOnly ? Icons.emoji_events_outlined : Icons.explore_outlined,
            friendsOnly ? 'フォロー中のユーザーの大会はありません' : '大会が見つかりません',
            '',
          );
        }

        return RefreshIndicator(
          color: AppTheme.primaryColor,
          onRefresh: () async {
            await _loadOfficialFlag();
            await _loadFollowing();
            await _loadBookmarks();
            setState(() {});
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 12, 16, 92 + MediaQuery.of(context).padding.bottom),
            itemCount: filtered.length,
            itemBuilder: (ctx, i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildTournamentCard(filtered[i]),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTournamentCard(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final title = data['title'] ?? '';
    final date = data['date'] ?? '';
    final location = data['location'] ?? '';
    final status = normalizeTournamentStatus(data['status']);
    final type = data['type'] ?? '';
    final currentTeams = data['currentTeams'] ?? 0;
    final maxTeams = data['maxTeams'] ?? 8;
    final organizerName = data['organizerName'] ?? '不明';
    final organizerId = data['organizerId'] ?? '';
    final deadline = data['deadline'] ?? '';
    final rawEntryFee = data['entryFee'];
    final entryFee = rawEntryFee is int ? '¥$rawEntryFee' : (rawEntryFee ?? '').toString();
    final isFollowing = _followingIds.contains(organizerId) || organizerId == _currentUser?.uid;
    final isSaved = _bookmarkedTournaments.contains(doc.id);
    final progress = maxTeams > 0 ? (currentTeams as num) / (maxTeams as num) : 0.0;

    Color sc;
    switch (status) {
      case '募集中':
        sc = AppTheme.success;
        break;
      case '満員':
        sc = AppTheme.error;
        break;
      case 'エントリー締切':
        sc = AppTheme.accentColor;
        break;
      case '大会準備中':
        sc = AppTheme.primaryLight;
        break;
      default:
        sc = AppTheme.textSecondary;
    }

    String day = '', month = '', weekday = '';
    try {
      final p = date.split('/');
      if (p.length >= 3) {
        month = '${int.parse(p[1])}月';
        day = p[2];
        final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
        const w = ['月', '火', '水', '木', '金', '土', '日'];
        weekday = w[d.weekday - 1];
      }
    } catch (_) {}
    final tc = _typeColor(type);

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => TournamentDetailScreen(tournament: {
          ...data, 'id': doc.id, 'name': data['title'] ?? '', 'isFollowing': isFollowing,
          'status': status,
        }),
      )),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey[200]!),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 日付ブロック
            _dateBlock(month, day, weekday, sc, type, tc),
            const SizedBox(width: 14),
            // コンテンツ
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // タイトル + ステータス
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Row(children: [
                  Flexible(child: Text(title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                      maxLines: 2, overflow: TextOverflow.ellipsis)),
                  if (data['isCertified'] == true) const CertifiedBadge(size: 14),
                ])),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: sc.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                  child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: sc)),
                ),
              ]),
              const SizedBox(height: 6),
              // 主催者
              FutureBuilder<List<String>>(
                future: Future.wait([_getOrganizerAvatar(organizerId), _getOrganizerName(organizerId, organizerName)]),
                builder: (context, snap) {
                  final url = snap.data?[0] ?? '';
                  final displayName = snap.data?[1] ?? organizerName;
                  return Row(children: [
                url.isNotEmpty
                    ? CircleAvatar(radius: 9, backgroundImage: NetworkImage(url))
                    : CircleAvatar(
                      radius: 9,
                      backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                      child: Text(
                        displayName.isNotEmpty ? displayName[0] : '?',
                        style: const TextStyle(fontSize: 9, color: AppTheme.primaryColor, fontWeight: FontWeight.bold),
                      ),
                    ),
                const SizedBox(width: 5),
                Text(displayName, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                if (_officialCache[organizerId] == true)
                  const OfficialBadge(size: 13),
                if (!isFollowing) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(4)),
                    child: Text('未フォロー', style: TextStyle(fontSize: 9, color: AppTheme.textHint)),
                  ),
                ],
              ]);
                },
              ),
              const SizedBox(height: 4),
              // 会場
              Row(children: [
                Icon(Icons.location_on_outlined, size: 13, color: AppTheme.textSecondary),
                const SizedBox(width: 4),
                Flexible(child: Text(location,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    overflow: TextOverflow.ellipsis)),
              ]),
              // 締切・参加費
              if (deadline.toString().isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.timer_outlined, size: 13, color: AppTheme.warning),
                  const SizedBox(width: 4),
                  Text('締切 $deadline', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.warning)),
                  if (entryFee.toString().isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.payments_outlined, size: 13, color: AppTheme.textSecondary),
                    const SizedBox(width: 4),
                    Text(entryFee.toString(), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ]),
              ] else if (entryFee.toString().isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.payments_outlined, size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(entryFee.toString(), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ],
              const SizedBox(height: 10),
              // 参加チーム数バー + ブックマーク
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('tournaments').doc(doc.id).collection('entries').snapshots(),
                builder: (context, entriesSnap) {
                  final entryCount = entriesSnap.data?.docs.length ?? 0;
                  final entryProgress = maxTeams > 0 ? entryCount / (maxTeams as num) : 0.0;
                  return Row(children: [
                    Text('$entryCount/$maxTeams', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                    const SizedBox(width: 8),
                    Expanded(child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: entryProgress.toDouble().clamp(0.0, 1.0),
                        backgroundColor: Colors.grey[200],
                        valueColor: AlwaysStoppedAnimation<Color>(
                            entryProgress >= 1.0 ? AppTheme.error : entryProgress >= 0.8 ? AppTheme.warning : AppTheme.success),
                        minHeight: 5,
                      ),
                    )),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () => _toggleTournamentBookmark(doc.id, {
                        'title': title, 'date': date, 'location': location,
                        'tournamentType': type, 'status': status,
                      }),
                      child: Icon(isSaved ? Icons.bookmark : Icons.bookmark_border,
                          size: 28, color: isSaved ? AppTheme.accentColor : Colors.grey[400]),
                    ),
                  ]);
                },
              ),
            ])),
          ]),
        ),
      ),
    );
  }

  // ━━━ 日付ブロック ━━━
  Future<String> _getOrganizerAvatar(String uid) async {
    if (uid.isEmpty) return '';
    if (_organizerAvatarCache.containsKey(uid)) return _organizerAvatarCache[uid]!;
    await _fetchOrganizerData(uid);
    return _organizerAvatarCache[uid] ?? '';
  }

  Future<String> _getOrganizerName(String uid, String fallback) async {
    if (uid.isEmpty) return fallback;
    if (_organizerNameCache.containsKey(uid)) {
      final cached = _organizerNameCache[uid]!;
      return cached.isNotEmpty ? cached : fallback;
    }
    await _fetchOrganizerData(uid);
    final name = _organizerNameCache[uid] ?? '';
    return name.isNotEmpty ? name : fallback;
  }

  Future<void> _fetchOrganizerData(String uid) async {
    if (_organizerAvatarCache.containsKey(uid)) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data();
      _organizerAvatarCache[uid] = (data?['avatarUrl'] ?? '').toString();
      _organizerNameCache[uid] = (data?['nickname'] ?? '').toString();
      _officialCache[uid] = data?['isOfficial'] == true;
    } catch (_) {
      _organizerAvatarCache[uid] = '';
      _organizerNameCache[uid] = '';
    }
  }

  Widget _dateBlock(String month, String day, String weekday, Color sc, String type, Color tc) {
    return SizedBox(
      width: 52,
      child: Column(children: [
        Container(
          width: 52,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: sc.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(children: [
            Text(month, style: TextStyle(fontSize: 10, color: sc, fontWeight: FontWeight.w600)),
            Text(day, style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: sc, height: 1.1)),
            if (weekday.isNotEmpty)
              Text('($weekday)', style: TextStyle(fontSize: 10, color: sc)),
          ]),
        ),
        if (type.isNotEmpty) ...[
          const SizedBox(height: 5),
          Container(
            width: 52,
            padding: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              color: tc.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(type, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: tc)),
          ),
        ],
      ]),
    );
  }

  Widget _alertBadge(IconData icon, String label, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // メンバー募集リスト
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Query<Map<String, dynamic>> _buildRecruitQuery() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection('recruitments');
    if (_filterType != 'すべて') {
      q = q.where('tournamentType', isEqualTo: _filterType);
    }
    return q;
  }

  Widget _buildRecruitList(bool friendsOnly) {
    return StreamBuilder<QuerySnapshot>(
      stream: _recruitmentStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }
        final docs = snapshot.data?.docs ?? [];
        final query = _searchController.text.toLowerCase();
        final filtered = docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final recruiterId = data['userId'] ?? '';
          final isF = _followingIds.contains(recruiterId) || recruiterId == _currentUser?.uid;
          if (friendsOnly && !isF) return false;
          if (!friendsOnly && isF) return false;
          if (query.isNotEmpty) {
            final nn = (data['nickname'] ?? '').toString().toLowerCase();
            final tn = (data['tournamentName'] ?? '').toString().toLowerCase();
            if (!nn.contains(query) && !tn.contains(query)) return false;
          }
          if (_filterArea != 'すべて' && !(data['area'] ?? '').toString().contains(_filterArea)) return false;
          if (_filterDateRange != null) {
            final d = _parseDate(data['tournamentDate'] ?? '');
            if (d == null || d.isBefore(_filterDateRange!.start) || d.isAfter(_filterDateRange!.end)) return false;
          }
          return true;
        }).toList();

        if (filtered.isEmpty) {
          return _emptyState(
            friendsOnly ? Icons.people_outline : Icons.person_search,
            friendsOnly ? 'フォロー中のユーザーのメンバー募集はありません' : 'メンバー募集が見つかりません',
            '',
          );
        }

        return RefreshIndicator(
          color: AppTheme.primaryColor,
          onRefresh: () async {
            await _loadFollowing();
            await _loadBookmarks();
            setState(() {});
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 12, 16, 92 + MediaQuery.of(context).padding.bottom),
            itemCount: filtered.length,
            itemBuilder: (ctx, i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildRecruitCard(filtered[i]),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecruitCard(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final nickname = data['nickname'] ?? '不明';
    final experience = data['experience'] ?? '';
    final tournamentName = data['tournamentName'] ?? '';
    final tournamentDate = data['tournamentDate'] ?? '';
    final tournamentId = data['tournamentId'] ?? '';
    final recruitCount = data['recruitCount'] ?? 0;
    final comment = data['comment'] ?? '';
    final recruiterId = data['userId'] ?? '';
    final area = data['area'] ?? '';
    final tournamentType = data['tournamentType'] ?? '';
    final isFollowing = _followingIds.contains(recruiterId) || recruiterId == _currentUser?.uid;
    final isSaved = _bookmarkedRecruits.contains(recruiterId);
    // isOfficial チェック（recruiter）
    if (recruiterId.isNotEmpty && !_officialCache.containsKey(recruiterId)) {
      _fetchOrganizerData(recruiterId);
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GestureDetector(
              onTap: recruiterId.isNotEmpty
                  ? () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => UserProfileScreen(userId: recruiterId)))
                  : null,
              child: CircleAvatar(
                radius: 22,
                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                child: Text(
                  nickname.isNotEmpty ? nickname[0] : '?',
                  style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: GestureDetector(
                  onTap: recruiterId.isNotEmpty
                      ? () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => UserProfileScreen(userId: recruiterId)))
                      : null,
                  child: Text(nickname,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                )),
                if (_officialCache[recruiterId] == true)
                  const OfficialBadge(size: 15),
                const Spacer(),
                if (recruitCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'あと$recruitCount人',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.error),
                    ),
                  ),
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                if (experience.isNotEmpty) _smallTag('競技歴 $experience', AppTheme.primaryColor),
                if (area.isNotEmpty) _smallTag(area, AppTheme.textSecondary),
                if (tournamentType.isNotEmpty) _smallTag(tournamentType, _typeColor(tournamentType)),
              ]),
            ])),
          ]),
          if (tournamentName.isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: tournamentId.isNotEmpty ? () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => TournamentDetailScreen(tournament: {
                  'id': tournamentId, 'name': tournamentName, 'date': tournamentDate,
                }),
              )) : null,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Row(children: [
                  Icon(Icons.emoji_events, size: 16, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tournamentName,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
                    if (tournamentDate.isNotEmpty)
                      Text(tournamentDate,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ])),
                  if (tournamentId.isNotEmpty)
                    Icon(Icons.chevron_right, size: 18, color: AppTheme.textHint),
                ]),
              ),
            ),
          ],
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(comment,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary, height: 1.5),
                maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: isFollowing ? () => _applyToRecruitment(recruiterId, nickname, tournamentName) : null,
              icon: Icon(isFollowing ? Icons.send : Icons.person_add, size: 15),
              label: Text(
                isFollowing ? '応募する' : 'フォローして応募',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isFollowing ? AppTheme.primaryColor : Colors.grey[300],
                foregroundColor: isFollowing ? Colors.white : AppTheme.textSecondary,
                padding: const EdgeInsets.symmetric(vertical: 10),
                minimumSize: const Size(0, 40),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            )),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _toggleRecruitBookmark(recruiterId, {
                'nickname': nickname, 'tournamentName': tournamentName, 'tournamentDate': tournamentDate,
              }),
              child: Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: isSaved ? AppTheme.accentColor.withValues(alpha: 0.1) : Colors.grey[100],
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(isSaved ? Icons.bookmark : Icons.bookmark_border,
                    size: 28, color: isSaved ? AppTheme.accentColor : Colors.grey[400]),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _smallTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
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
