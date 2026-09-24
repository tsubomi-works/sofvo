import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';
import '../../utils/tournament_status.dart';
import '../../widgets/empty_state_view.dart';
import '../../services/follow_service.dart';
import '../tournament/tournament_detail_screen.dart';

class RecruitmentScreen extends StatefulWidget {
  const RecruitmentScreen({super.key});
  @override
  State<RecruitmentScreen> createState() => _RecruitmentScreenState();
}

class _RecruitmentScreenState extends State<RecruitmentScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  User? get _currentUser => FirebaseAuth.instance.currentUser;
  List<Map<String, dynamic>> _upcoming = [];
  List<Map<String, dynamic>> _past = [];
  bool _loading = true;
  /// Sofvo公式など：参加者としてのエントリーは想定せず、主催大会のみ表示する。
  bool _isOfficialAccount = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: const Duration(milliseconds: 200),
    );
    _loadMyTournaments();
  }

  Future<void> _loadMyTournaments() async {
    final uid = _currentUser?.uid;
    if (uid == null) return;
    if (mounted) setState(() => _loading = true);

    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final isOfficial = userDoc.data()?['isOfficial'] == true;

      final upcoming = <Map<String, dynamic>>[];
      final past = <Map<String, dynamic>>[];

      if (isOfficial) {
        final hostedSnap = await FirebaseFirestore.instance
            .collection('tournaments')
            .where('organizerId', isEqualTo: uid)
            .get();

        for (final doc in hostedSnap.docs) {
          final data = doc.data();
          if (data['isDemo'] == true) continue; // 体験デモ大会は一般表示しない
          final status = normalizeTournamentStatus(data['status']);
          final entryCountSnap =
              await doc.reference.collection('entries').count().get();
          final entryCount = entryCountSnap.count ?? 0;
          final entry = {
            ...data,
            'id': doc.id,
            'teamName': '',
            'isOrganizer': true,
            'isEntered': false,
            'entryCount': entryCount,
            'status': status,
          };
          if (status == '終了') {
            past.add(entry);
          } else {
            upcoming.add(entry);
          }
        }
      } else {
        final tournSnap =
            await FirebaseFirestore.instance.collection('tournaments').get();

        for (final doc in tournSnap.docs) {
          final data = doc.data();
          if (data['isDemo'] == true) continue; // 体験デモ大会は一般表示しない
          final isOrganizer = data['organizerId'] == uid;
          final entriesSnap =
              await doc.reference.collection('entries').get();

          // enteredBy OR memberUids にUIDが含まれるエントリーを検索
          final myEntry = entriesSnap.docs.where((e) {
            final d = e.data();
            if (d['enteredBy'] == uid) return true;
            final memberUids = d['memberUids'];
            if (memberUids is List && memberUids.contains(uid)) return true;
            return false;
          });
          final isEntered = myEntry.isNotEmpty;

          if (!isEntered && !isOrganizer) continue;

          final teamName = isEntered
              ? (myEntry.first.data()['teamName'] ?? '')
              : '';
          final status = normalizeTournamentStatus(data['status']);
          final entry = {
            ...data,
            'id': doc.id,
            'teamName': teamName,
            'isOrganizer': isOrganizer,
            'isEntered': isEntered,
            'entryCount': entriesSnap.docs.length,
            'status': status,
          };

          if (status == '終了') {
            past.add(entry);
          } else {
            upcoming.add(entry);
          }
        }
      }

      upcoming.sort((a, b) => (a['date'] ?? '').compareTo(b['date'] ?? ''));
      past.sort((a, b) => (b['date'] ?? '').compareTo(a['date'] ?? ''));

      if (mounted) {
        setState(() {
          _isOfficialAccount = isOfficial;
          _upcoming = upcoming;
          _past = past;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('大会読み込みエラー: $e');
      if (mounted) {
        setState(() {
          _isOfficialAccount = false;
          _upcoming = [];
          _past = [];
          _loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('大会の読み込みに失敗しました。下に引いて再読み込みしてください。'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _navigateToDetail(Map<String, dynamic> t) {
    final status = normalizeTournamentStatus(t['status']);
    Color statusColor;
    switch (status) {
      case '募集中':
        statusColor = AppTheme.success;
        break;
      case 'エントリー締切':
        statusColor = AppTheme.accentColor;
        break;
      case '大会準備中':
        statusColor = AppTheme.primaryLight;
        break;
      case '開催中':
        statusColor = AppTheme.primaryColor;
        break;
      case '決勝中':
      case '順位決定中':
        statusColor = Colors.amber;
        break;
      default:
        statusColor = AppTheme.textSecondary;
    }
    final Map<String, dynamic> payload;
    if (_isOfficialAccount) {
      final orgId = (t['organizerId'] ?? '') as String;
      final uid = _currentUser?.uid ?? '';
      final isFollowing =
          orgId.isEmpty || orgId == uid || FollowService.instance.isFollowing(orgId);
      payload = {
        ...t,
        'name': t['title'] ?? '',
        'isFollowing': isFollowing,
        'status': status,
      };
    } else {
      payload = {
        ...t,
        'name': t['title'] ?? '',
        'isFollowing': true,
        'status': status,
      };
    }
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => TournamentDetailScreen(
                  tournament: payload,
                )));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ━━━ ヘッダー ━━━
  Widget _buildHeader() {
    return Material(
      color: Colors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: const Text('マイ大会',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
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
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('これから'),
              if (!_loading) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${_upcoming.length}', style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white,
                  )),
                ),
              ],
            ])),
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('これまで'),
              if (!_loading) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${_past.length}', style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary,
                  )),
                ),
              ],
            ])),
          ],
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          _buildHeader(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryColor))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _KeepAlivePage(child: _buildUpcomingTab()),
                      _KeepAlivePage(child: _buildPastTab()),
                    ],
                  ),
          ),
        ]),
      ),
    );
  }

  // ━━━ 開催予定タブ ━━━
  Widget _buildUpcomingTab() {
    if (_upcoming.isEmpty) {
      if (_isOfficialAccount) {
        return const EmptyStateView(
          icon: Icons.event_note_outlined,
          title: '予定されている大会はありません',
          subtitle: '大会の作成・管理はマイページの「大会主催者メニュー」から行えます。',
        );
      }
      return EmptyStateView(
        icon: Icons.event_note_outlined,
        title: '参加予定の大会はありません',
        subtitle: '大会を検索してエントリーしましょう！',
        actions: [
          EmptyStateAction(
            label: '大会を探す',
            icon: Icons.search,
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('下のメニューから「さがす」タブで大会を探せます'),
                  backgroundColor: AppTheme.primaryColor,
                ),
              );
            },
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMyTournaments,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 92 + MediaQuery.of(context).padding.bottom),
        children: [
          _buildNextHighlight(_upcoming.first),
          const SizedBox(height: 20),
          _sectionHeader(Icons.calendar_month, 'その他の予定', _upcoming.length - 1),
          const SizedBox(height: 10),
          ..._upcoming.skip(1).map((t) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildUpcomingCard(t),
              )),
        ],
      ),
    );
  }

  // ━━━ 次の大会ハイライト ━━━
  Widget _buildNextHighlight(Map<String, dynamic> t) {
    const navyColor = Color(0xFF1B3A5C);
    final dateStr = t['date'] ?? '';
    int daysLeft = -1;
    String month = '', day = '', weekday = '';
    try {
      final parts = dateStr.split('/');
      if (parts.length == 3) {
        final d = DateTime(int.parse(parts[0]), int.parse(parts[1]),
            int.parse(parts[2]));
        final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
        daysLeft = d.difference(today).inDays;
        month = '${int.parse(parts[1])}月';
        day = parts[2];
        const w = ['月', '火', '水', '木', '金', '土', '日'];
        weekday = w[d.weekday - 1];
      }
    } catch (_) {}
    final status = normalizeTournamentStatus(t['status']);
    final isOrganizer = t['isOrganizer'] == true;
    final roleLabel = isOrganizer ? '主催' : status;
    final roleColor = isOrganizer ? AppTheme.accentColor : AppTheme.success;

    return GestureDetector(
      onTap: () => _navigateToDetail(t),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: navyColor.withValues(alpha: 0.3)),
          boxShadow: [
            BoxShadow(
                color: navyColor.withValues(alpha: 0.10),
                blurRadius: 12,
                offset: const Offset(0, 4)),
          ],
        ),
        child: Column(children: [
          // 上部ヘッダー帯
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: navyColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(15)),
            ),
            child: Row(children: [
              const Icon(Icons.star_rounded,
                  size: 15, color: Colors.white),
              const SizedBox(width: 5),
              const Text('次の大会',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: daysLeft <= 0
                      ? AppTheme.error.withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.timer_outlined,
                      size: 13,
                      color: daysLeft <= 0
                          ? const Color(0xFFFF8A80)
                          : Colors.white),
                  const SizedBox(width: 4),
                  Text(
                      daysLeft == 0
                          ? '本日！'
                          : daysLeft < 0
                              ? '${-daysLeft}日前'
                              : 'あと$daysLeft日',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: daysLeft <= 0
                              ? const Color(0xFFFF8A80)
                              : Colors.white)),
                ]),
              ),
            ]),
          ),
          // 本体
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // 日付ブロック + 種別
              Column(children: [
                _dateBlock(month, day, weekday, navyColor),
                if ((t['type'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.textSecondary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(t['type'], style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary)),
                  ),
                ],
              ]),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                          child: Text(t['title'] ?? '',
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textPrimary),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                            color: roleColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6)),
                        child: Text(roleLabel,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: roleColor)),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    _infoRow(Icons.location_on_outlined, t['location'] ?? ''),
                    const SizedBox(height: 4),
                    if ((t['receptionTime'] ?? '').toString().isNotEmpty || (t['matchStartTime'] ?? '').toString().isNotEmpty) ...[
                      Row(children: [
                        if ((t['receptionTime'] ?? '').toString().isNotEmpty) ...[
                          Icon(Icons.how_to_reg, size: 13, color: AppTheme.primaryColor),
                          const SizedBox(width: 4),
                          Text('受付 ${t['receptionTime']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
                        ],
                        if ((t['receptionTime'] ?? '').toString().isNotEmpty && (t['matchStartTime'] ?? '').toString().isNotEmpty)
                          const SizedBox(width: 10),
                        if ((t['matchStartTime'] ?? '').toString().isNotEmpty) ...[
                          Icon(Icons.sports_volleyball, size: 13, color: AppTheme.warning),
                          const SizedBox(width: 4),
                          Text('試合 ${t['matchStartTime']}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.warning)),
                        ],
                      ]),
                      const SizedBox(height: 4),
                    ],
                    if (((t['teamName'] ?? '') as String).trim().isNotEmpty) ...[
                      _infoRow(Icons.groups_outlined, t['teamName'] ?? ''),
                      const SizedBox(height: 10),
                    ] else
                      const SizedBox(height: 10),
                    // 参加費・チーム数
                    Row(children: [
                      if (() {
                        final f = t['entryFee'] ?? t['fee'];
                        return f != null && f.toString().isNotEmpty && f.toString() != '0';
                      }()) ...[
                        Icon(Icons.payments_outlined, size: 14, color: AppTheme.primaryColor),
                        const SizedBox(width: 4),
                        Text(() {
                          final f = t['entryFee'] ?? t['fee'];
                          return f is int ? '¥$f' : '$f';
                        }(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
                        const SizedBox(width: 12),
                      ],
                      Icon(Icons.groups, size: 14, color: AppTheme.accentColor),
                      const SizedBox(width: 4),
                      Text('${t['entryCount'] ?? t['currentTeams'] ?? 0}チーム',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.accentColor)),
                    ]),
                  ])),
              Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
            ]),
          ),
        ]),
      ),
    );
  }

  // ━━━ 開催予定カード ━━━
  Widget _buildUpcomingCard(Map<String, dynamic> t) {
    final status = normalizeTournamentStatus(t['status']);
    final isOrganizer = t['isOrganizer'] == true;
    final dateStr = t['date'] ?? '';
    String month = '', day = '', weekday = '';
    try {
      final parts = dateStr.split('/');
      if (parts.length >= 3) {
        month = '${int.parse(parts[1])}月';
        day = parts[2];
        final d = DateTime(int.parse(parts[0]), int.parse(parts[1]),
            int.parse(parts[2]));
        const w = ['月', '火', '水', '木', '金', '土', '日'];
        weekday = w[d.weekday - 1];
      }
    } catch (_) {}

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
      case '開催中':
        sc = AppTheme.primaryColor;
        break;
      case '決勝中':
      case '順位決定中':
        sc = Colors.amber;
        break;
      default:
        sc = AppTheme.textSecondary;
    }
    final roleLabel = isOrganizer ? '主催' : status;
    final roleColor = isOrganizer ? AppTheme.accentColor : sc;

    return GestureDetector(
      onTap: () => _navigateToDetail(t),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey[200]!),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2))
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(children: [
              _dateBlock(month, day, weekday, sc),
              if ((t['type'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.textSecondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(t['type'], style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                ),
              ],
            ]),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                        child: Text(t['title'] ?? '',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textPrimary),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: roleColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(roleLabel,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: roleColor)),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  _infoRow(Icons.location_on_outlined, t['location'] ?? ''),
                  const SizedBox(height: 4),
                  if ((t['receptionTime'] ?? '').toString().isNotEmpty || (t['matchStartTime'] ?? '').toString().isNotEmpty) ...[
                    Row(children: [
                      if ((t['receptionTime'] ?? '').toString().isNotEmpty) ...[
                        Icon(Icons.how_to_reg, size: 13, color: AppTheme.primaryColor),
                        const SizedBox(width: 4),
                        Text('受付 ${t['receptionTime']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
                      ],
                      if ((t['receptionTime'] ?? '').toString().isNotEmpty && (t['matchStartTime'] ?? '').toString().isNotEmpty)
                        const SizedBox(width: 10),
                      if ((t['matchStartTime'] ?? '').toString().isNotEmpty) ...[
                        Icon(Icons.sports_volleyball, size: 13, color: AppTheme.warning),
                        const SizedBox(width: 4),
                        Text('試合 ${t['matchStartTime']}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.warning)),
                      ],
                    ]),
                    const SizedBox(height: 4),
                  ],
                  if (((t['teamName'] ?? '') as String).trim().isNotEmpty)
                    _infoRow(Icons.groups_outlined, t['teamName'] ?? ''),
                ])),
            Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
          ]),
        ),
      ),
    );
  }

  // ━━━ 過去の大会タブ ━━━
  Widget _buildPastTab() {
    if (_past.isEmpty) {
      if (_isOfficialAccount) {
        return const EmptyStateView(
          icon: Icons.history,
          title: '過去の大会はありません',
          subtitle: '終了した大会があればここに表示されます。',
        );
      }
      return const EmptyStateView(
        icon: Icons.history,
        title: '過去の大会はありません',
        subtitle: '大会に参加すると履歴がここに表示されます',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMyTournaments,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 92 + MediaQuery.of(context).padding.bottom),
        children: [
          // サマリー（一般ユーザーのみ。公式は年に数回程度の想定のため枠を省く）
          if (!_isOfficialAccount)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[200]!),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.03),
                      blurRadius: 6,
                      offset: const Offset(0, 2))
                ],
              ),
              child: Row(children: [
                Expanded(
                    child: _summaryItem(
                        '参加大会', '${_past.length}', AppTheme.primaryColor)),
                Container(width: 1, height: 40, color: Colors.grey[200]),
                Expanded(
                    child: _summaryItem(
                        '主催',
                        '${_past.where((t) => t['isOrganizer'] == true).length}',
                        AppTheme.accentColor)),
                Container(width: 1, height: 40, color: Colors.grey[200]),
                Expanded(
                    child: _summaryItem(
                        '出場',
                        '${_past.where((t) => t['isEntered'] == true).length}',
                        AppTheme.success)),
              ]),
            ),
          if (!_isOfficialAccount) const SizedBox(height: 20),
          _sectionHeader(
              Icons.history,
              _isOfficialAccount ? '過去の大会' : '参加履歴',
              _past.length),
          const SizedBox(height: 10),
          ..._past.map((t) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildPastCard(t),
              )),
        ],
      ),
    );
  }

  // ━━━ 過去の大会カード ━━━
  Widget _buildPastCard(Map<String, dynamic> t) {
    final dateStr = t['date'] ?? '';
    String month = '', day = '', weekday = '';
    try {
      final parts = dateStr.split('/');
      if (parts.length >= 3) {
        month = '${int.parse(parts[1])}月';
        day = parts[2];
        final d = DateTime(int.parse(parts[0]), int.parse(parts[1]),
            int.parse(parts[2]));
        const w = ['月', '火', '水', '木', '金', '土', '日'];
        weekday = w[d.weekday - 1];
      }
    } catch (_) {}
    final isOrganizer = t['isOrganizer'] == true;

    return GestureDetector(
      onTap: () => _navigateToDetail(t),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey[200]!),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2))
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _dateBlock(month, day, weekday, AppTheme.textSecondary),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                        child: Text(t['title'] ?? '',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textPrimary),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(isOrganizer ? '主催' : '出場',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textSecondary)),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  _infoRow(Icons.location_on_outlined, t['location'] ?? ''),
                  const SizedBox(height: 4),
                  if (((t['teamName'] ?? '') as String).trim().isNotEmpty) ...[
                    _infoRow(Icons.groups_outlined, t['teamName'] ?? ''),
                    const SizedBox(height: 8),
                  ] else
                    const SizedBox(height: 8),
                  Row(children: [
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.emoji_events_outlined,
                            size: 13, color: AppTheme.primaryColor),
                        const SizedBox(width: 4),
                        Text('結果を見る',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.primaryColor)),
                      ]),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right,
                        size: 20, color: Colors.grey[400]),
                  ]),
                ])),
          ]),
        ),
      ),
    );
  }

  // ━━━ 共通ウィジェット ━━━
  Widget _dateBlock(String month, String day, String weekday, Color color) {
    return SizedBox(
      width: 52,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: [
          Text(month,
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w600)),
          Text(day,
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: color,
                  height: 1.1)),
          if (weekday.isNotEmpty)
            Text('($weekday)',
                style: TextStyle(fontSize: 10, color: color)),
        ]),
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(children: [
      Icon(icon, size: 13, color: AppTheme.textSecondary),
      const SizedBox(width: 4),
      Flexible(
          child: Text(text,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
              overflow: TextOverflow.ellipsis)),
    ]);
  }

  Widget _sectionHeader(IconData icon, String title, int count) {
    return Row(children: [
      Icon(icon, size: 16, color: AppTheme.primaryColor),
      const SizedBox(width: 6),
      Text('$title ($count件)',
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppTheme.primaryColor)),
    ]);
  }

  Widget _summaryItem(String label, String value, Color color) {
    return Column(children: [
      Text(value,
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(height: 4),
      Text(label,
          style: const TextStyle(
              fontSize: 12, color: AppTheme.textSecondary)),
    ]);
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
