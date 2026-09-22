import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/media_service.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../widgets/official_badge.dart';
import '../../config/app_theme.dart';
import '../../utils/tournament_status.dart';
import '../../services/follow_service.dart';
import '../../services/invite_service.dart';
import '../../utils/search_normalize.dart';
import '../tournament/tournament_detail_screen.dart';
import '../follow/follow_search_screen.dart';
import '../tournament/venue_search_screen.dart';
import '../tournament/prize_search_screen.dart';
import '../gadget/all_gadgets_screen.dart';
import '../../utils/entry_membership.dart';
import '../../widgets/rank_badge.dart';
import '../tournament/tournament_management_screen.dart';
import '../notification/create_notice_screen.dart';
import '../notification/notice_history_screen.dart';
import '../recruitment/recruitment_management_screen.dart';
import 'admin_stats_screen.dart';
import 'report_management_screen.dart';
import '../admin/survey_list_screen.dart';
import '../admin/season_management_screen.dart';
import '../admin/sponsor_management_screen.dart';
import '../admin/tournament_template_screen.dart';
import '../admin/analytics_screen.dart';
import '../admin/certification_screen.dart';
import '../admin/article_list_screen.dart';
import '../admin/broadcast_message_screen.dart';
import '../admin/campaign_management_screen.dart';
import '../admin/feedback_screen.dart';
import '../admin/faq_management_screen.dart';
import '../admin/reminder_settings_screen.dart';
import '../admin/user_segment_screen.dart';
import 'admin_user_list_screen.dart';
import 'follow_list_screen.dart';
import 'settings_screen.dart';
import '../gadget/gadget_list_screen.dart';
import 'tournament_history_screen.dart';
import 'ranking_screen.dart';
import 'point_history_screen.dart';
import 'user_profile_screen.dart';
import 'user_photos_screen.dart';
import '../../services/point_service.dart';

class MyPageScreen extends StatelessWidget {
  final String? targetUserId; // 管理者用: 他人のマイページを表示
  const MyPageScreen({super.key, this.targetUserId});

  String _safeString(dynamic value) {
    if (value is String) return value;
    if (value is Map) return value.values.join(' ');
    return value?.toString() ?? '';
  }

  int _safeInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final viewingUid = targetUserId ?? user?.uid;
    final isAdminViewing = targetUserId != null;

    if (viewingUid == null) {
      return const Scaffold(
        backgroundColor: AppTheme.backgroundColor,
        body: Center(child: Text('ログインしてください')),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users').doc(viewingUid).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryColor),
            );
          }

          final data = snapshot.data?.data() as Map<String, dynamic>? ?? {};
          final nickname = _safeString(data['nickname']).isEmpty
              ? '未設定' : _safeString(data['nickname']);
          final experience = _safeString(data['experience']);
          final avatarUrl = _safeString(data['avatarUrl']);
          final rawArea = data['area'];
          final area = rawArea is String
              ? rawArea
              : rawArea is Map
                  ? '${rawArea['prefecture'] ?? ''}${rawArea['city'] ?? ''}'
                  : '';
          final bio = _safeString(data['bio']);
          final socialLinks = data['socialLinks'] is Map<String, dynamic>
              ? data['socialLinks'] as Map<String, dynamic>
              : <String, dynamic>{};
          final isOfficial = data['isOfficial'] == true;
          final totalPoints = _safeInt(data['totalPoints']);
          final seasonPoints = _safeInt(data['seasonPoints']);
          final stats = data['stats'] is Map<String, dynamic>
              ? data['stats'] as Map<String, dynamic>
              : <String, dynamic>{};
          final tournamentsPlayed = _safeInt(stats['tournamentsPlayed']);
          final championships = _safeInt(stats['championships']);

          return CustomScrollView(
            slivers: [
              // ━━━ コンパクトヘッダー ━━━
              SliverToBoxAdapter(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.primaryDark, AppTheme.primaryColor, AppTheme.primaryLight],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 8, 14),
                      child: Column(
                        children: [
                          // ── トップバー ──
                          Row(
                            children: [
                              if (isAdminViewing)
                                GestureDetector(
                                  onTap: () => Navigator.pop(context),
                                  child: const Padding(
                                    padding: EdgeInsets.only(right: 8),
                                    child: Icon(Icons.arrow_back, size: 22, color: Colors.white),
                                  ),
                                ),
                              Text(isAdminViewing ? '$nickname（管理）' : 'マイページ',
                                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white)),
                              const Spacer(),
                              if (!isAdminViewing) ...[
                                GestureDetector(
                                  onTap: () => Navigator.push(context,
                                      MaterialPageRoute(builder: (_) => UserProfileScreen(userId: viewingUid, preview: true))),
                                  child: const Icon(Icons.visibility_outlined, size: 24, color: Colors.white),
                                ),
                                const SizedBox(width: 12),
                                GestureDetector(
                                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FollowSearchScreen())),
                                  child: const Icon(Icons.person_add_outlined, size: 24, color: Colors.white),
                                ),
                                const SizedBox(width: 12),
                                GestureDetector(
                                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                                  child: const Icon(Icons.settings_outlined, size: 24, color: Colors.white),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          // ── プロフィール行（横レイアウト） ──
                          Row(
                            children: [
                              GestureDetector(
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => ProfileEditScreen(userData: data, targetUserId: isAdminViewing ? viewingUid : null))),
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2.5),
                                  ),
                                  child: avatarUrl.isNotEmpty
                                      ? ClipOval(
                                          child: CachedNetworkImage(
                                            imageUrl: avatarUrl,
                                            width: 60,
                                            height: 60,
                                            fit: BoxFit.cover,
                                            placeholder: (context, url) => Container(
                                              width: 60, height: 60,
                                              color: Colors.white.withValues(alpha: 0.2),
                                            ),
                                            errorWidget: (context, url, error) => CircleAvatar(
                                              radius: 30,
                                              backgroundColor: Colors.white.withValues(alpha: 0.2),
                                              child: Text(nickname.isNotEmpty ? nickname[0] : '?',
                                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                                            ),
                                          ),
                                        )
                                      : CircleAvatar(
                                          radius: 30,
                                          backgroundColor: Colors.white.withValues(alpha: 0.2),
                                          child: Text(
                                            nickname.isNotEmpty ? nickname[0] : '?',
                                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(child: Text(nickname,
                                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                                            overflow: TextOverflow.ellipsis)),
                                        if (data['isOfficial'] == true)
                                          const OfficialBadge(size: 18, color: Colors.white),
                                      ],
                                    ),
                                    if (!isOfficial) ...[
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          if (experience.isNotEmpty) _buildHeaderTag('競技歴 $experience'),
                                          if (area.isNotEmpty) _buildHeaderTag(area),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              OutlinedButton(
                                onPressed: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => ProfileEditScreen(userData: data, targetUserId: isAdminViewing ? viewingUid : null))),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: const Text('編集', style: TextStyle(fontSize: 12, color: Colors.white)),
                              ),
                            ],
                          ),
                          if (bio.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _ExpandableBio(bio: bio),
                          ],
                          if (socialLinks.values.any((v) => v is String && v.isNotEmpty)) ...[
                            const SizedBox(height: 8),
                            _SocialLinkIcons(socialLinks: socialLinks),
                          ],
                          const SizedBox(height: 12),
                          // ── フォロー / フォロワー（横一列コンパクト）──
                          // 公式アカウントも自分で管理・確認できるよう表示する
                          _FollowCounts(userId: viewingUid),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ━━━ ダッシュボード（スタッツ）※公式アカウントは非表示 ━━━
              if (!isOfficial)
              SliverToBoxAdapter(
                child: Transform.translate(
                  offset: const Offset(0, -8),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 4))],
                    ),
                    child: Row(
                      children: [
                        Expanded(child: _buildDashboardStat(Icons.calendar_today_rounded, '$seasonPoints', 'シーズンPt', AppTheme.accentColor)),
                        Container(width: 1, height: 36, color: Colors.grey[200]),
                        Expanded(child: _buildDashboardStat(Icons.star_rounded, '$totalPoints', '通算Pt', AppTheme.textSecondary)),
                        Container(width: 1, height: 36, color: Colors.grey[200]),
                        Expanded(child: _buildDashboardStat(Icons.emoji_events_rounded, '$tournamentsPlayed', '大会参加', AppTheme.primaryColor)),
                        Container(width: 1, height: 36, color: Colors.grey[200]),
                        Expanded(child: _buildDashboardStat(Icons.military_tech_rounded, '$championships', '優勝', AppTheme.warning)),
                      ],
                    ),
                  ),
                ),
              ),

              // ━━━ ポイント関連ボタン ※公式アカウントは非表示 ━━━
              if (!isOfficial)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const PointHistoryScreen())),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: AppTheme.accentColor.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.history, size: 16, color: AppTheme.accentColor),
                                const SizedBox(width: 6),
                                Text('ポイント履歴',
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.accentColor)),
                                const SizedBox(width: 4),
                                Icon(Icons.chevron_right, size: 16, color: AppTheme.accentColor),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => PointService.showPointSystemInfo(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, size: 16, color: AppTheme.primaryColor),
                              const SizedBox(width: 6),
                              Text('ポイントの仕組み',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ━━━ コンテンツ ━━━
              SliverPadding(
                padding: EdgeInsets.fromLTRB(0, 20, 0, 92 + MediaQuery.of(context).padding.bottom),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // ━━━ 大会結果・ガジェット・バッジ ※公式アカウントは非表示 ━━━
                    if (!isOfficial) ...[
                      _buildCardSection(
                        context: context,
                        title: '大会結果',
                        icon: Icons.emoji_events_rounded,
                        seeAllTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const TournamentHistoryScreen())),
                        child: _TournamentCardsRow(userId: viewingUid),
                      ),
                      const SizedBox(height: 24),

                      _buildCardSection(
                        context: context,
                        title: 'フォト',
                        icon: Icons.photo_library_rounded,
                        seeAllTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => UserPhotosScreen(userId: viewingUid, displayName: nickname))),
                        child: PhotoCardsRow(userId: viewingUid, displayName: nickname),
                      ),
                      const SizedBox(height: 24),

                      _buildCardSection(
                        context: context,
                        title: 'マイガジェット',
                        icon: Icons.devices_other_rounded,
                        seeAllTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const GadgetListScreen())),
                        child: _GadgetCardsRow(userId: viewingUid),
                      ),
                      const SizedBox(height: 24),

                      _buildCardSection(
                        context: context,
                        title: 'バッジコレクション',
                        icon: Icons.workspace_premium_rounded,
                        child: _BadgeCollectionRow(userId: viewingUid),
                      ),
                      const SizedBox(height: 24),
                    ],

                    // ── お知らせ配信（公式アカウントのみ） ──
                    if (isOfficial) ...[
                      _buildCardSection(
                        context: context,
                        title: 'お知らせ配信',
                        icon: Icons.campaign_rounded,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.send_rounded,
                              title: 'お知らせを作成',
                              subtitle: '全ユーザーに一斉配信',
                              color: AppTheme.accentColor,
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateNoticeScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.history,
                              title: '配信履歴',
                              subtitle: '過去のお知らせ管理',
                              color: AppTheme.primaryColor,
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NoticeHistoryScreen())),
                            ))],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildCardSection(
                        context: context,
                        title: '管理',
                        icon: Icons.admin_panel_settings_rounded,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(children: [
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.analytics_rounded,
                              title: 'ユーザー統計',
                              subtitle: '登録数・大会数を確認',
                              color: AppTheme.info,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const AdminStatsScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.people_rounded,
                              title: '全登録ユーザー',
                              subtitle: 'ユーザー一覧・検索',
                              color: AppTheme.primaryColor,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const AdminUserListScreen())),
                            ))],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.flag_rounded,
                              title: '通報管理',
                              subtitle: 'ユーザーからの通報確認',
                              color: Colors.red,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const ReportManagementScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.poll_rounded,
                              title: 'アンケート',
                              subtitle: '作成・結果確認',
                              color: Colors.orange,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const SurveyListScreen())),
                            ))],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.trending_up_rounded,
                              title: 'アクセス解析',
                              subtitle: '登録数推移・統計',
                              color: Colors.blue,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.copy_rounded,
                              title: '大会テンプレート',
                              subtitle: 'テンプレート管理',
                              color: Colors.cyan,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const TournamentTemplateScreen())),
                            ))],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.workspace_premium,
                              title: '大会認定',
                              subtitle: '公式認定バッジ管理',
                              color: Colors.amber,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const CertificationScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.campaign_rounded,
                              title: 'スポンサー',
                              subtitle: 'バナー広告管理',
                              color: Colors.green,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const SponsorManagementScreen())),
                            ))],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.emoji_events_outlined,
                              title: 'シーズン管理',
                              subtitle: 'ランキング期間設定',
                              color: Colors.amber,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const SeasonManagementScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.article_rounded,
                              title: 'ブログ',
                              subtitle: '公式記事の管理',
                              color: Colors.deepPurple,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const ArticleListScreen())),
                            ))],
                          ),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // ── エンゲージメント ──
                      _buildCardSection(
                        context: context,
                        title: 'エンゲージメント',
                        icon: Icons.trending_up_rounded,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(children: [
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.campaign_outlined,
                              title: '一斉配信',
                              subtitle: 'チャット一斉送信',
                              color: Colors.indigo,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const BroadcastMessageScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.event_note_rounded,
                              title: 'キャンペーン',
                              subtitle: 'バナー・ポップアップ',
                              color: Colors.pink,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const CampaignManagementScreen())),
                            ))],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.pie_chart_rounded,
                              title: 'ユーザー分析',
                              subtitle: 'セグメント・属性分析',
                              color: Colors.teal,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const UserSegmentScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.alarm_rounded,
                              title: 'リマインダー',
                              subtitle: '自動通知タイミング設定',
                              color: Colors.orange,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const ReminderSettingsScreen())),
                            ))],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [Expanded(child: _buildMenuCard(
                              icon: Icons.feedback_rounded,
                              title: 'フィードバック',
                              subtitle: 'ユーザーからの要望・報告',
                              color: Colors.blue,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const FeedbackScreen())),
                            )), const SizedBox(width: 12), Expanded(child: _buildMenuCard(
                              icon: Icons.quiz_rounded,
                              title: 'FAQ管理',
                              subtitle: 'よくある質問の編集',
                              color: Colors.green,
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const FaqManagementScreen())),
                            ))],
                          ),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── 主催大会（公式アカウントのみ） ──
                    if (isOfficial) ...[
                      _buildCardSection(
                        context: context,
                        title: '主催大会',
                        icon: Icons.emoji_events_rounded,
                        seeAllTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const TournamentManagementScreen())),
                        child: _HostedTournamentCardsRow(userId: viewingUid),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── 大会主催者メニュー（カード型） ──
                    _buildCardSection(
                      context: context,
                      title: '大会主催者メニュー',
                      icon: Icons.sports_volleyball_rounded,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildMenuCard(
                                icon: Icons.emoji_events_outlined,
                                title: '大会管理',
                                subtitle: '大会の作成・運営',
                                color: AppTheme.primaryColor,
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TournamentManagementScreen())),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildMenuCard(
                                icon: Icons.card_giftcard_outlined,
                                title: '景品をさがす',
                                subtitle: '景品アイデア共有',
                                color: Colors.orange,
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrizeSearchScreen())),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── 公式アカウント専用メニュー ──
                    if (isOfficial) ...[
                      _buildCardSection(
                        context: context,
                        title: '公式メニュー',
                        icon: Icons.verified_rounded,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildMenuCard(
                                  icon: Icons.devices_other_outlined,
                                  title: 'みんなのガジェット',
                                  subtitle: '全ユーザーの登録ガジェット',
                                  color: Colors.blueGrey,
                                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AllGadgetsScreen())),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(child: SizedBox()),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── みんなのツール（カード型） ──
                    _buildCardSection(
                      context: context,
                      title: 'みんなのツール',
                      icon: Icons.handyman_rounded,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildMenuCard(
                                icon: Icons.person_search_outlined,
                                title: 'メンバー募集',
                                subtitle: '仲間をさがす',
                                color: Colors.teal,
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RecruitmentManagementScreen())),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildMenuCard(
                                icon: Icons.location_city_outlined,
                                title: '会場さがす',
                                subtitle: '登録・検索',
                                color: Colors.indigo,
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VenueSearchScreen())),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ━━━ 友達を紹介する ━━━
                    _buildCardSection(
                      context: context,
                      title: '友達を紹介する',
                      icon: Icons.card_giftcard_rounded,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppTheme.accentColor.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.people_outline, color: AppTheme.accentColor, size: 20),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Text(
                                      '紹介リンクを送ると、登録後に自動で友達になれます！',
                                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Builder(builder: (ctx) {
                              final referralUrl = 'https://sofvo.com/invite?ref=$viewingUid';
                              final shareText = 'ソフトバレーボールアプリ「Sofvo」を一緒に使おう！\n大会運営・エントリー・チャットがこれ一つで完結します。\n$referralUrl';
                              return Row(
                                children: [
                                  // LINE
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () {
                                        final encoded = Uri.encodeComponent(shareText);
                                        launchUrl(Uri.parse('https://line.me/R/share?text=$encoded'), mode: LaunchMode.externalApplication);
                                      },
                                      icon: const Icon(FontAwesomeIcons.line, size: 18),
                                      label: const Text('LINE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF06C755),
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size(0, 48),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // メール
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () {
                                        final subject = Uri.encodeComponent('Sofvo - ソフトバレーボールアプリ');
                                        final body = Uri.encodeComponent(shareText);
                                        launchUrl(Uri.parse('mailto:?subject=$subject&body=$body'), mode: LaunchMode.externalApplication);
                                      },
                                      icon: const Icon(Icons.mail_outline, size: 18),
                                      label: const Text('メール', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppTheme.accentColor,
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size(0, 48),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            }),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  final referralUrl = 'https://sofvo.com/invite?ref=$viewingUid';
                                  Clipboard.setData(ClipboardData(text: referralUrl));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('リンクをコピーしました'),
                                      backgroundColor: AppTheme.success,
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('リンクをコピー', style: TextStyle(fontSize: 14)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.accentColor,
                                  side: BorderSide(color: AppTheme.accentColor.withValues(alpha: 0.4)),
                                  minimumSize: const Size(double.infinity, 40),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // 自分の招待コードを発行して表示（相手が登録時に入力する用）
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () => _showInviteCodeDisplayDialog(context),
                                icon: const Icon(Icons.confirmation_number_outlined, size: 18),
                                label: const Text('招待コードを表示', style: TextStyle(fontSize: 14)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.primaryColor,
                                  side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.4)),
                                  minimumSize: const Size(double.infinity, 40),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ━━━ ランキング（公式アカウントも閲覧可能） ━━━
                    _buildCardSection(
                      context: context,
                      title: 'ランキング',
                      icon: Icons.leaderboard_rounded,
                      seeAllTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const RankingScreen())),
                      child: _RankingPreview(currentUid: viewingUid),
                    ),
                  ]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── ヘッダー上のタグ ──
  Widget _buildHeaderTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500)),
    );
  }

  // ── フォロー数（ヘッダー内） ──
  Widget _buildFollowCount(
      BuildContext context, String count, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(count, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.7))),
        ],
      ),
    );
  }

  // ── ダッシュボードスタッツ ──
  Widget _buildDashboardStat(IconData icon, String value, String label, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color, height: 1.1)),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ── アクションカード（友達をさがす等） ──
  Widget _buildActionCard({
    required IconData icon, required String title, required String subtitle,
    required Color color, required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40, height: 40,
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
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[400], size: 22),
            ],
          ),
        ),
      ),
    );
  }

  // ── 自分の招待コードを発行して表示（相手が登録時に入力する用） ──
  Future<void> _showInviteCodeDisplayDialog(BuildContext context) async {
    // ダイアログを開くたびにコードを1回だけ発行（rebuild で再発行しないよう先に生成）
    final codeFuture = InviteService.createInvite();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('招待コードを表示', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: FutureBuilder<String>(
          future: codeFuture,
          builder: (dialogCtx, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 96,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError || snapshot.data == null) {
              return const Text(
                '招待コードの発行に失敗しました。時間をおいて再度お試しください。',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
              );
            }
            final code = snapshot.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'このコードを友達に伝えてください。登録時に入力すると、自動でお互いに友達になれます。',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
                  ),
                  child: Center(
                    child: Text(
                      code,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 6,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(dialogCtx).showSnackBar(
                        const SnackBar(
                          content: Text('招待コードをコピーしました'),
                          backgroundColor: AppTheme.success,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('コードをコピー', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryColor,
                      side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.4)),
                      minimumSize: const Size(double.infinity, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final text = InviteService.shareText(code: code);
                      final encoded = Uri.encodeComponent(text);
                      launchUrl(
                        Uri.parse('https://line.me/R/share?text=$encoded'),
                        mode: LaunchMode.externalApplication,
                      );
                    },
                    icon: const Icon(FontAwesomeIcons.line, size: 18),
                    label: const Text('LINEで送る', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF06C755),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('閉じる')),
        ],
      ),
    );
  }

  // ── メニューカード（カード型メニュー項目） ──
  Widget _buildMenuCard({
    required IconData icon, required String title, required String subtitle,
    required Color color, required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Column(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 10),
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  // ── セクションラベル ──
  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
    );
  }

  // ── メニューグループ ──
  Widget _buildMenuGroup(List<_MenuItemData> items) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            _buildMenuItem(items[i].icon, items[i].title, items[i].onTap),
            if (i < items.length - 1)
              Divider(height: 1, indent: 54, color: Colors.grey[100]),
          ],
        ],
      ),
    );
  }

  // ── メニューアイテム ──
  Widget _buildMenuItem(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.primaryColor, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary)),
      trailing: Icon(Icons.chevron_right, color: Colors.grey[400], size: 22),
      onTap: onTap,
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
    );
  }

  // ── カードセクション（タイトル + 横スクロール） ──
  Widget _buildCardSection({
    required BuildContext context,
    required String title,
    required IconData icon,
    required Widget child,
    VoidCallback? seeAllTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.primaryColor, size: 18),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
              const Spacer(),
              if (seeAllTap != null)
                GestureDetector(
                  onTap: seeAllTap,
                  child: Row(
                    children: [
                      Text('すべて見る', style: TextStyle(fontSize: 12, color: AppTheme.primaryColor)),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right, size: 16, color: AppTheme.primaryColor),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  void _showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('この機能は準備中です'),
        backgroundColor: AppTheme.warning,
        duration: Duration(seconds: 2),
      ),
    );
  }
}

// ── メニューアイテムデータ ──
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SNSリンクアイコン表示
class _SocialLinkIcons extends StatelessWidget {
  final Map<String, dynamic> socialLinks;
  const _SocialLinkIcons({required this.socialLinks});

  static const _snsDefs = <String, IconData>{
    'instagram': FontAwesomeIcons.instagram,
    'facebook': FontAwesomeIcons.facebook,
    'x': FontAwesomeIcons.xTwitter,
    'tiktok': FontAwesomeIcons.tiktok,
    'youtube': FontAwesomeIcons.youtube,
    'website': Icons.language,
  };

  @override
  Widget build(BuildContext context) {
    final entries = _snsDefs.entries
        .where((e) => socialLinks[e.key] is String && (socialLinks[e.key] as String).isNotEmpty)
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: entries.map((e) {
        final url = socialLinks[e.key] as String;
        final icon = e.value;
        return GestureDetector(
          onTap: () => _openUrl(url),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(icon, size: 18, color: Colors.white.withValues(alpha: 0.7)),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _openUrl(String url) async {
    var target = url;
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      target = 'https://$target';
    }
    final uri = Uri.tryParse(target);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

// 自己紹介（4行まで表示 → 「続きを読む」で全文展開）
class _ExpandableBio extends StatefulWidget {
  final String bio;
  const _ExpandableBio({required this.bio});

  @override
  State<_ExpandableBio> createState() => _ExpandableBioState();
}

class _ExpandableBioState extends State<_ExpandableBio> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final textSpan = TextSpan(
                text: widget.bio,
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.8), height: 1.3),
              );
              final tp = TextPainter(
                text: textSpan,
                maxLines: 2,
                textDirection: TextDirection.ltr,
              )..layout(maxWidth: constraints.maxWidth);
              final isOverflow = tp.didExceedMaxLines;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.bio,
                    softWrap: true,
                    style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.8), height: 1.3),
                    maxLines: _expanded ? null : 2,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                  ),
                  if (isOverflow)
                    GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          _expanded ? '閉じる' : '続きを読む',
                          style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.5)),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// フォロー / フォロワー カウント（リアルタイムストリーム）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _FollowCounts extends StatelessWidget {
  final String userId;
  const _FollowCounts({required this.userId});

  @override
  Widget build(BuildContext context) {
    final svc = FollowService.instance;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        StreamBuilder<int>(
          stream: svc.followingCountStream(userId),
          builder: (context, snap) {
            final count = snap.data ?? 0;
            return _buildCount('$count', 'フォロー', () {
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => FollowListScreen(
                    userId: userId, title: 'フォロー中', isFollowers: false)));
            });
          },
        ),
        Container(width: 1, height: 24, margin: const EdgeInsets.symmetric(horizontal: 24),
            color: Colors.white.withValues(alpha: 0.25)),
        StreamBuilder<int>(
          stream: svc.followersCountStream(userId),
          builder: (context, snap) {
            final count = snap.data ?? 0;
            return _buildCount('$count', 'フォロワー', () {
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => FollowListScreen(
                    userId: userId, title: 'フォロワー', isFollowers: true)));
            });
          },
        ),
      ],
    );
  }

  Widget _buildCount(String count, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(count, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}

class _MenuItemData {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const _MenuItemData(this.icon, this.title, this.onTap);
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 大会結果カード（横スクロール）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _TournamentCardsRow extends StatefulWidget {
  final String userId;
  const _TournamentCardsRow({required this.userId});

  @override
  State<_TournamentCardsRow> createState() => _TournamentCardsRowState();
}

class _TournamentCardsRowState extends State<_TournamentCardsRow> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadTournaments();
  }

  Future<List<Map<String, dynamic>>> _loadTournaments() async {
    final firestore = FirebaseFirestore.instance;
    final uid = widget.userId;
    final resultMap = <String, Map<String, dynamic>>{};

    // 主催した大会
    final organized = await firestore
        .collection('tournaments')
        .where('organizerId', isEqualTo: uid)
        .get();
    for (final doc in organized.docs) {
      final data = doc.data();
      if (data['status'] != '終了') continue;
      data['id'] = doc.id;
      resultMap[doc.id] = data;
    }

    // エントリーした大会を検索
    final allTournaments = await firestore
        .collection('tournaments')
        .orderBy('date', descending: true)
        .limit(100)
        .get();

    for (final doc in allTournaments.docs) {
      if (resultMap.containsKey(doc.id)) continue;
      final data = doc.data();
      if (data['status'] != '終了') continue;
      final entries = await firestore
          .collection('tournaments')
          .doc(doc.id)
          .collection('entries')
          .get();
      if (entriesForUser(entries, uid).isNotEmpty) {
        data['id'] = doc.id;
        resultMap[doc.id] = data;
      }
    }

    final result = resultMap.values.toList()
      ..sort((a, b) => ((b['date'] ?? '') as String).compareTo((a['date'] ?? '') as String));
    if (result.length > 10) result.removeRange(10, result.length);

    // 順位（pointHistory の rank: 1〜3位）を紐付け。取れなくても一覧自体は表示する
    try {
      final ph = await firestore
          .collection('users').doc(uid).collection('pointHistory').get();
      final rankMap = <String, int>{};
      for (final doc in ph.docs) {
        final r = doc.data()['rank'];
        if (r is num) rankMap[doc.id] = r.toInt();
      }
      for (final t in result) {
        final r = rankMap[t['id']];
        if (r != null) t['myRank'] = r;
      }
    } catch (_) {}
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SizedBox(
            height: 100,
            child: Center(
              child: Text('データの取得に失敗しました', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor)));
        }

        final tournaments = snapshot.data!;
        if (tournaments.isEmpty) {
          return SizedBox(
            height: 100,
            child: Center(
              child: Text('まだ大会結果がありません', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          );
        }

        return SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tournaments.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final d = tournaments[index];
              final title = (d['title'] ?? d['name'] ?? '大会') as String;
              final date = (d['date'] ?? '') as String;
              final location = (d['location'] ?? d['venue'] ?? '') as String;
              final type = (d['type'] ?? '') as String;
              final docId = d['id'] as String;

              return GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournament: {...d, 'id': docId, 'name': d['title'] ?? d['name'] ?? ''}))),
                child: Container(
                  width: 180,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // 順位を先頭で目立たせる（終了チップは冗長のため廃止）
                          if (d['myRank'] != null) ...[
                            RankBadge(rank: d['myRank'] as int?),
                            const SizedBox(width: 4),
                          ],
                          if (type.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.accentColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(type, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.accentColor)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.calendar_today, size: 11, color: AppTheme.textSecondary),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(date, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                      if (location.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.place, size: 11, color: AppTheme.textSecondary),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(location, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 主催大会カード（横スクロール）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _HostedTournamentCardsRow extends StatefulWidget {
  final String userId;
  const _HostedTournamentCardsRow({required this.userId});

  @override
  State<_HostedTournamentCardsRow> createState() => _HostedTournamentCardsRowState();
}

class _HostedTournamentCardsRowState extends State<_HostedTournamentCardsRow> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadHostedTournaments();
  }

  Future<List<Map<String, dynamic>>> _loadHostedTournaments() async {
    final snap = await FirebaseFirestore.instance
        .collection('tournaments')
        .where('organizerId', isEqualTo: widget.userId)
        .orderBy('createdAt', descending: true)
        .limit(5)
        .get();
    return snap.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return data;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SizedBox(
            height: 100,
            child: Center(
              child: Text('データの取得に失敗しました', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor)));
        }

        final tournaments = snapshot.data!;
        if (tournaments.isEmpty) {
          return SizedBox(
            height: 100,
            child: Center(
              child: Text('まだ主催大会がありません', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          );
        }

        return SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tournaments.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final d = tournaments[index];
              final title = (d['title'] ?? d['name'] ?? '大会') as String;
              final date = (d['date'] ?? '') as String;
              final status = normalizeTournamentStatus(d['status'] ?? '', emptyAsPreparing: false);
              final docId = d['id'] as String;

              Color statusColor;
              if (status == '終了') {
                statusColor = AppTheme.textSecondary;
              } else if (status == '募集中') {
                statusColor = AppTheme.accentColor;
              } else {
                statusColor = AppTheme.primaryColor;
              }

              return GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournament: {...d, 'id': docId, 'name': d['title'] ?? d['name'] ?? ''}))),
                child: Container(
                  width: 180,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(status.isEmpty ? '下書き' : status,
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: statusColor)),
                      ),
                      const SizedBox(height: 8),
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.calendar_today, size: 11, color: AppTheme.textSecondary),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(date, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ガジェットカード（横スクロール）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _GadgetCardsRow extends StatelessWidget {
  final String userId;
  const _GadgetCardsRow({required this.userId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users').doc(userId).collection('gadgets')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor)));
        }

        final gadgets = (snapshot.data?.docs ?? []).toList()
          ..sort((a, b) {
            final dataA = a.data() as Map<String, dynamic>;
            final dataB = b.data() as Map<String, dynamic>;
            final orderA = (dataA['sortOrder'] as num?) ?? 999999;
            final orderB = (dataB['sortOrder'] as num?) ?? 999999;
            return orderA.compareTo(orderB);
          });

        if (gadgets.isEmpty) {
          return SizedBox(
            height: 100,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('ガジェットを登録しよう', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GadgetListScreen())),
                    child: Text('登録する', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                  ),
                ],
              ),
            ),
          );
        }

        return SizedBox(
          height: 210,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: gadgets.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final d = gadgets[index].data() as Map<String, dynamic>;
              final name = (d['name'] ?? '') as String;
              final category = (d['category'] ?? '') as String;
              final imageUrl = (d['imageUrl'] ?? '') as String;
              final memo = (d['memo'] ?? '') as String;

              return GestureDetector(
                onTap: () => _showGadgetDetail(context, d),
                child: Container(
                  width: 140,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 正方形画像エリア ──
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: imageUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: imageUrl,
                                  fit: BoxFit.contain,
                                  placeholder: (_, __) => Container(
                                    color: Colors.grey[100],
                                    child: const Center(child: Icon(Icons.image, color: Colors.grey, size: 24)),
                                  ),
                                  errorWidget: (_, __, ___) => Container(
                                    color: Colors.grey[100],
                                    child: const Center(child: Icon(Icons.devices_other, color: Colors.grey, size: 24)),
                                  ),
                                )
                              : Container(
                                  color: AppTheme.primaryColor.withValues(alpha: 0.06),
                                  child: const Center(child: Icon(Icons.devices_other, color: AppTheme.primaryColor, size: 28)),
                                ),
                        ),
                      ),
                      // ── テキスト ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            if (category.isNotEmpty && category != 'カテゴリなし') ...[
                              const SizedBox(height: 2),
                              Text(category, style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                            if (memo.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(memo, style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showGadgetDetail(BuildContext context, Map<String, dynamic> d) {
    final name = (d['name'] ?? '') as String;
    final category = (d['category'] ?? '') as String;
    final imageUrl = (d['imageUrl'] ?? '') as String;
    final memo = (d['memo'] ?? '') as String;
    final amazonAffUrl = (d['amazonAffiliateUrl'] ?? '').toString();
    final rakutenAffUrl = (d['rakutenAffiliateUrl'] ?? '').toString();
    final hasAmazon = amazonAffUrl.isNotEmpty;
    final hasRakuten = rakutenAffUrl.isNotEmpty;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
              Align(alignment: Alignment.centerRight, child: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx))),
              if (imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    height: 200,
                    fit: BoxFit.contain,
                    placeholder: (_, __) => const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor))),
                    errorWidget: (_, __, ___) => const SizedBox(height: 200, child: Center(child: Icon(Icons.image_not_supported, size: 48, color: Colors.grey))),
                  ),
                )
              else
                Container(
                  height: 200,
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(12)),
                  child: const Center(child: Icon(Icons.devices_other, size: 48, color: Colors.grey)),
                ),
              const SizedBox(height: 16),
              Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              if (category.isNotEmpty && category != 'カテゴリなし') ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(category, style: const TextStyle(fontSize: 12, color: AppTheme.primaryColor, fontWeight: FontWeight.w600)),
                ),
              ],
              if (memo.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(memo, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 16),
              if (hasAmazon)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => launchUrl(Uri.parse(amazonAffUrl), mode: LaunchMode.externalApplication),
                    icon: const FaIcon(FontAwesomeIcons.amazon, size: 18, color: Colors.white),
                    label: const Text('Amazonで見る', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF9900),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              if (hasAmazon && hasRakuten) const SizedBox(height: 10),
              if (hasRakuten)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => launchUrl(Uri.parse(rakutenAffUrl), mode: LaunchMode.externalApplication),
                    icon: const Text('R', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white, fontStyle: FontStyle.italic)),
                    label: const Text('楽天で見る', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFBF0000),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              if (!hasAmazon && !hasRakuten)
                Text('購入リンクは登録されていません', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ],
          ),
        );
      },
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// バッジコレクション（YAMAP風 横スクロール）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _BadgeCollectionRow extends StatelessWidget {
  final String userId;
  const _BadgeCollectionRow({required this.userId});

  // バッジ定義（YAMAP風の達成系バッジ）
  static const _badgeDefinitions = [
    _BadgeDef('初参加', Icons.flag_rounded, Color(0xFF4CAF50), 'tournamentsPlayed', 1),
    _BadgeDef('5大会参加', Icons.emoji_events_rounded, Color(0xFF2196F3), 'tournamentsPlayed', 5),
    _BadgeDef('10大会参加', Icons.emoji_events_rounded, Color(0xFF9C27B0), 'tournamentsPlayed', 10),
    _BadgeDef('初優勝', Icons.military_tech_rounded, Color(0xFFFF9800), 'championships', 1),
    _BadgeDef('3回優勝', Icons.military_tech_rounded, Color(0xFFF44336), 'championships', 3),
    _BadgeDef('100Pt達成', Icons.star_rounded, Color(0xFFFFC107), 'totalPoints', 100),
    _BadgeDef('500Pt達成', Icons.star_rounded, Color(0xFFFF5722), 'totalPoints', 500),
    _BadgeDef('1000Pt達成', Icons.diamond_rounded, Color(0xFFE91E63), 'totalPoints', 1000),
    _BadgeDef('ガジェット5個', Icons.devices_other_rounded, Color(0xFF00BCD4), 'gadgetCount', 5),
    _BadgeDef('フォロワー10', Icons.people_rounded, Color(0xFF795548), 'followersCount', 10),
  ];

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users').doc(userId).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>? ?? {};
        final stats = data['stats'] is Map<String, dynamic>
            ? data['stats'] as Map<String, dynamic>
            : <String, dynamic>{};

        // 各値を取得
        final values = {
          'tournamentsPlayed': _intVal(stats['tournamentsPlayed']),
          'championships': _intVal(stats['championships']),
          'totalPoints': _intVal(data['totalPoints']),
          'gadgetCount': _intVal(data['gadgetCount']),
          'followersCount': _intVal(data['followersCount']),
        };

        return SizedBox(
          height: 120,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _badgeDefinitions.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final badge = _badgeDefinitions[index];
              final currentValue = values[badge.statKey] ?? 0;
              final earned = currentValue >= badge.threshold;

              return Container(
                width: 90,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                decoration: BoxDecoration(
                  color: earned ? Colors.white : Colors.grey[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: earned ? badge.color.withValues(alpha: 0.4) : Colors.grey[200]!,
                    width: earned ? 1.5 : 1,
                  ),
                  boxShadow: earned
                      ? [BoxShadow(color: badge.color.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 2))]
                      : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: earned
                            ? badge.color.withValues(alpha: 0.12)
                            : Colors.grey[200],
                        border: earned
                            ? Border.all(color: badge.color.withValues(alpha: 0.3), width: 2)
                            : null,
                      ),
                      child: Icon(
                        badge.icon,
                        color: earned ? badge.color : Colors.grey[400],
                        size: 24,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      badge.name,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: earned ? FontWeight.bold : FontWeight.normal,
                        color: earned ? AppTheme.textPrimary : AppTheme.textHint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    if (!earned)
                      Text(
                        '$currentValue/${badge.threshold}',
                        style: TextStyle(fontSize: 9, color: AppTheme.textHint),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  int _intVal(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    return 0;
  }
}

class _BadgeDef {
  final String name;
  final IconData icon;
  final Color color;
  final String statKey;
  final int threshold;
  const _BadgeDef(this.name, this.icon, this.color, this.statKey, this.threshold);
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ランキングプレビュー（トップ3表示）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _RankingPreview extends StatelessWidget {
  final String currentUid;
  const _RankingPreview({required this.currentUid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .orderBy('totalPoints', descending: true)
          .limit(3)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor)));
        }

        final users = snapshot.data?.docs ?? [];
        if (users.isEmpty) {
          return const SizedBox(
            height: 60,
            child: Center(child: Text('ランキングデータがありません', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              for (int i = 0; i < users.length; i++) ...[
                _buildRankRow(context, i + 1, users[i]),
                if (i < users.length - 1) Divider(height: 1, color: Colors.grey[100]),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildRankRow(BuildContext context, int rank, QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final nickname = (data['nickname'] as String?) ?? '名無し';
    final avatarUrl = (data['avatarUrl'] as String?) ?? '';
    final pts = _intVal(data['totalPoints']);
    final isMe = doc.id == currentUid;
    final rankColors = [const Color(0xFFFFD700), const Color(0xFFC0C0C0), const Color(0xFFCD7F32)];

    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => UserProfileScreen(userId: doc.id))),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        color: isMe ? AppTheme.primaryColor.withValues(alpha: 0.04) : Colors.transparent,
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Icon(Icons.emoji_events, size: 20, color: rankColors[rank - 1]),
            ),
            const SizedBox(width: 8),
            avatarUrl.isNotEmpty
                ? CircleAvatar(radius: 16, backgroundImage: CachedNetworkImageProvider(avatarUrl),
                    backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12))
                : CircleAvatar(radius: 16, backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                    child: Text(nickname.isNotEmpty ? nickname[0] : '?',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.primaryColor))),
            const SizedBox(width: 10),
            Expanded(
              child: Text(nickname, style: TextStyle(fontSize: 14,
                  fontWeight: isMe ? FontWeight.bold : FontWeight.w500,
                  color: isMe ? AppTheme.primaryColor : AppTheme.textPrimary)),
            ),
            Text('$pts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800,
                color: rankColors[rank - 1])),
            const SizedBox(width: 2),
            Text('Pt', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  int _intVal(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    return 0;
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// プロフィール編集画面（アバターアップロード対応）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class ProfileEditScreen extends StatefulWidget {
  final Map<String, dynamic> userData;
  final String? targetUserId; // admin用: 他人のプロフィールを編集する場合
  const ProfileEditScreen({super.key, required this.userData, this.targetUserId});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late TextEditingController _nicknameCtrl;
  late TextEditingController _bioCtrl;
  late TextEditingController _idCtrl;
  late TextEditingController _instagramCtrl;
  late TextEditingController _facebookCtrl;
  late TextEditingController _xCtrl;
  late TextEditingController _tiktokCtrl;
  late TextEditingController _youtubeCtrl;
  late TextEditingController _websiteCtrl;
  String _selectedExperience = '1年未満';
  String _selectedArea = '';
  String _selectedGender = '';
  DateTime? _birthDate;
  bool _isIdLocked = false;
  bool _isSaving = false;
  bool _isUploadingAvatar = false;
  String _avatarUrl = '';

  final _picker = ImagePicker();

  final _experiences = ['1年未満', '1〜3年', '3〜5年', '5〜10年', '10年以上'];
  final _genderChoices = ['男性', '女性', 'その他'];
  final _areas = [
    '北海道', '青森県', '岩手県', '宮城県', '秋田県', '山形県', '福島県',
    '茨城県', '栃木県', '群馬県', '埼玉県', '千葉県', '東京都', '神奈川県',
    '新潟県', '富山県', '石川県', '福井県', '山梨県', '長野県',
    '岐阜県', '静岡県', '愛知県', '三重県',
    '滋賀県', '京都府', '大阪府', '兵庫県', '奈良県', '和歌山県',
    '鳥取県', '島根県', '岡山県', '広島県', '山口県',
    '徳島県', '香川県', '愛媛県', '高知県',
    '福岡県', '佐賀県', '長崎県', '熊本県', '大分県', '宮崎県', '鹿児島県', '沖縄県',
  ];

  @override
  void initState() {
    super.initState();
    final d = widget.userData;
    _nicknameCtrl = TextEditingController(text: _str(d['nickname']));
    _bioCtrl = TextEditingController(text: _str(d['bio']));
    _idCtrl = TextEditingController(text: _str(d['searchId']));
    _avatarUrl = _str(d['avatarUrl']);
    final links = d['socialLinks'] is Map<String, dynamic>
        ? d['socialLinks'] as Map<String, dynamic>
        : <String, dynamic>{};
    _instagramCtrl = TextEditingController(text: _str(links['instagram']));
    _facebookCtrl = TextEditingController(text: _str(links['facebook']));
    _xCtrl = TextEditingController(text: _str(links['x']));
    _tiktokCtrl = TextEditingController(text: _str(links['tiktok']));
    _youtubeCtrl = TextEditingController(text: _str(links['youtube']));
    _websiteCtrl = TextEditingController(text: _str(links['website']));

    // ユーザーIDが設定済みなら変更不可
    final existingId = _str(d['searchId']);
    _isIdLocked = existingId.isNotEmpty;

    final rawExp = _str(d['experience']);
    _selectedExperience =
        _experiences.contains(rawExp) ? rawExp : '1年未満';

    // 性別・生年月日: まずメインドキュメントのフォールバック値を使用
    final rawGender = _str(d['gender']);
    _selectedGender = _genderChoices.contains(rawGender) ? rawGender : '';
    if (d['birthDate'] is Timestamp) {
      _birthDate = (d['birthDate'] as Timestamp).toDate();
    } else if (d['birthDate'] is String && (d['birthDate'] as String).isNotEmpty) {
      _birthDate = DateTime.tryParse(d['birthDate']);
    }
    // privateサブコレクションから最新値を非同期ロード
    _loadPrivateData();

    final rawArea = d['area'];
    String areaStr = '';
    if (rawArea is String) {
      areaStr = rawArea;
    } else if (rawArea is Map) {
      areaStr = '${rawArea['prefecture'] ?? ''}';
    }
    if (_areas.contains(areaStr)) {
      _selectedArea = areaStr;
    } else if (areaStr.isNotEmpty) {
      _selectedArea = _areas.firstWhere(
        (a) => areaStr.contains(a) || a.contains(areaStr),
        orElse: () => '',
      );
    } else {
      _selectedArea = '';
    }
  }

  Future<void> _loadPrivateData() async {
    final uid = widget.targetUserId ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final privateDoc = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('private').doc('info').get();
      if (privateDoc.exists && mounted) {
        final pd = privateDoc.data()!;
        setState(() {
          final g = pd['gender'] is String ? pd['gender'] as String : '';
          if (_genderChoices.contains(g)) _selectedGender = g;
          if (pd['birthDate'] is Timestamp) {
            _birthDate = (pd['birthDate'] as Timestamp).toDate();
          }
        });
      }
    } catch (_) {}
  }

  String _str(dynamic v) => v is String ? v : (v?.toString() ?? '');

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _bioCtrl.dispose();
    _idCtrl.dispose();
    _instagramCtrl.dispose();
    _facebookCtrl.dispose();
    _xCtrl.dispose();
    _tiktokCtrl.dispose();
    _youtubeCtrl.dispose();
    _websiteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadAvatar() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (picked == null || !mounted) return;

      // クロップUIを表示
      final bytes = await MediaService.cropIconImage(picked, context);
      if (bytes == null || !mounted) return;

      setState(() => _isUploadingAvatar = true);

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final fileName = picked.name;
      final ext = fileName.contains('.') ? fileName.split('.').last : 'jpg';

      final ref = FirebaseStorage.instance
          .ref()
          .child('avatars')
          .child('$uid.$ext');

      final metadata = SettableMetadata(
        contentType: 'image/$ext',
      );

      await ref.putData(bytes, metadata);
      final downloadUrl = await ref.getDownloadURL();

      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'avatarUrl': downloadUrl});

      if (mounted) {
        setState(() {
          _avatarUrl = downloadUrl;
          _isUploadingAvatar = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('アバターを更新しました'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploadingAvatar = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('アバターのアップロードに失敗しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1940),
      lastDate: now,
      locale: const Locale('ja'),
    );
    if (picked != null) {
      setState(() => _birthDate = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('プロフィール編集'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _saveProfile,
            child: _isSaving
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor))
                : const Text('保存',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryColor)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── アバター ──
          Center(
            child: GestureDetector(
              onTap: _isUploadingAvatar ? null : _pickAndUploadAvatar,
              child: Stack(
                children: [
                  _isUploadingAvatar
                      ? CircleAvatar(
                          radius: 48,
                          backgroundColor: AppTheme.primaryColor
                              .withValues(alpha: 0.12),
                          child: const CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: AppTheme.primaryColor,
                          ),
                        )
                      : _avatarUrl.isNotEmpty
                          ? CircleAvatar(
                              radius: 48,
                              backgroundImage:
                                  NetworkImage(_avatarUrl),
                              backgroundColor: AppTheme.primaryColor
                                  .withValues(alpha: 0.12),
                            )
                          : CircleAvatar(
                              radius: 48,
                              backgroundColor: AppTheme.primaryColor
                                  .withValues(alpha: 0.12),
                              child: Text(
                                _nicknameCtrl.text.isNotEmpty
                                    ? _nicknameCtrl.text[0]
                                    : '?',
                                style: const TextStyle(
                                    fontSize: 36,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.primaryColor),
                              ),
                            ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor,
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.camera_alt,
                          color: Colors.white, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'タップして写真を変更',
              style: TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
          const SizedBox(height: 24),

          // ── ニックネーム ──
          _buildSectionLabel('ニックネーム'),
          const SizedBox(height: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _nicknameCtrl,
            builder: (context, value, child) {
              return TextField(
                controller: _nicknameCtrl,
                maxLength: 15,
                decoration: _inputDecoration('ニックネームを入力'),
              );
            },
          ),
          const SizedBox(height: 8),

          // ── ユーザーID（一度決めたら変更不可） ──
          _buildSectionLabel('ユーザーID'),
          const SizedBox(height: 4),
          if (_isIdLocked)
            Text('一度設定したユーザーIDは変更できません',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          TextField(
            controller: _idCtrl,
            maxLength: 20,
            enabled: !_isIdLocked,
            decoration: _inputDecoration('@から始まるID').copyWith(
              fillColor: _isIdLocked ? Colors.grey[100] : Colors.white,
              prefixIcon: _isIdLocked ? const Icon(Icons.lock_outline, size: 18) : null,
            ),
          ),
          const SizedBox(height: 8),

          // ── 競技歴・性別・エリア・生年月日 ※公式アカウントは非表示 ──
          if (widget.userData['isOfficial'] != true) ...[
            _buildSectionLabel('競技歴'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _experiences.map((exp) {
                final sel = _selectedExperience == exp;
                return ChoiceChip(
                  label: Text(exp),
                  selected: sel,
                  onSelected: (s) {
                    if (s) setState(() => _selectedExperience = exp);
                  },
                  selectedColor:
                      AppTheme.primaryColor.withValues(alpha: 0.15),
                  labelStyle: TextStyle(
                    color: sel
                        ? AppTheme.primaryColor
                        : AppTheme.textSecondary,
                    fontWeight:
                        sel ? FontWeight.bold : FontWeight.normal,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            _buildSectionLabel('性別 *'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _genderChoices.map((g) {
                final sel = _selectedGender == g;
                return ChoiceChip(
                  label: Text(g),
                  selected: sel,
                  onSelected: (s) {
                    if (s) setState(() => _selectedGender = g);
                  },
                  selectedColor:
                      AppTheme.primaryColor.withValues(alpha: 0.15),
                  labelStyle: TextStyle(
                    color: sel
                        ? AppTheme.primaryColor
                        : AppTheme.textSecondary,
                    fontWeight:
                        sel ? FontWeight.bold : FontWeight.normal,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            _buildSectionLabel('エリア（都道府県） *'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: DropdownButton<String>(
                value: _selectedArea.isEmpty ? null : _selectedArea,
                isExpanded: true,
                underline: const SizedBox(),
                hint: const Text('都道府県を選択', style: TextStyle(color: AppTheme.textHint)),
                items: _areas
                    .map((a) =>
                        DropdownMenuItem(value: a, child: Text(a)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedArea = v);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (widget.userData['isOfficial'] != true) ...[
            _buildSectionLabel('生年月日 *'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickBirthDate,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today, size: 18,
                        color: _birthDate != null ? AppTheme.primaryColor : AppTheme.textHint),
                    const SizedBox(width: 12),
                    Text(
                      _birthDate != null
                          ? '${_birthDate!.year}年${_birthDate!.month}月${_birthDate!.day}日'
                          : '生年月日を選択',
                      style: TextStyle(
                        fontSize: 15,
                        color: _birthDate != null ? AppTheme.textPrimary : AppTheme.textHint,
                      ),
                    ),
                    const Spacer(),
                    Icon(Icons.chevron_right, color: Colors.grey[400], size: 20),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── 自己紹介 ──
          _buildSectionLabel('自己紹介'),
          const SizedBox(height: 8),
          TextField(
            controller: _bioCtrl,
            maxLines: 4,
            maxLength: 120,
            decoration: _inputDecoration('自己紹介を入力')
                .copyWith(alignLabelWithHint: true),
          ),
          const SizedBox(height: 24),

          // ── SNSリンク ──
          _buildSectionLabel('SNSリンク'),
          const SizedBox(height: 8),
          _buildSnsField(FontAwesomeIcons.instagram, 'Instagram URL', _instagramCtrl),
          _buildSnsField(FontAwesomeIcons.facebook, 'Facebook URL', _facebookCtrl),
          _buildSnsField(FontAwesomeIcons.xTwitter, 'X (Twitter) URL', _xCtrl),
          _buildSnsField(FontAwesomeIcons.tiktok, 'TikTok URL', _tiktokCtrl),
          _buildSnsField(FontAwesomeIcons.youtube, 'YouTube URL', _youtubeCtrl),
          _buildSnsField(Icons.language, 'その他URL', _websiteCtrl),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isSaving ? null : _saveProfile,
            child: const Text('保存する',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String text) {
    return Text(text,
        style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary));
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppTheme.textHint),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[200]!)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[200]!)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
              color: AppTheme.primaryColor, width: 2)),
    );
  }

  Widget _buildSnsField(IconData icon, String hint, TextEditingController ctrl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        decoration: _inputDecoration(hint).copyWith(
          prefixIcon: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, size: 20, color: AppTheme.textSecondary),
          ),
        ),
        keyboardType: TextInputType.url,
        style: const TextStyle(fontSize: 14),
      ),
    );
  }

  Future<void> _saveProfile() async {
    if (_nicknameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ニックネームを入力してください'), backgroundColor: AppTheme.warning));
      return;
    }

    final isOfficial = widget.userData['isOfficial'] == true;
    if (!isOfficial) {
      if (_selectedGender.isEmpty || !_genderChoices.contains(_selectedGender)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('性別を選択してください'), backgroundColor: AppTheme.warning));
        return;
      }
      if (_birthDate == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('生年月日を選択してください'), backgroundColor: AppTheme.warning));
        return;
      }
      if (_selectedArea.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エリア（都道府県）を選択してください'), backgroundColor: AppTheme.warning));
        return;
      }
    }

    // ユーザーID重複チェック（新規設定時のみ）
    final newId = _idCtrl.text.trim();
    if (!_isIdLocked && newId.isNotEmpty) {
      final existing = await FirebaseFirestore.instance
          .collection('users')
          .where('searchId', isEqualTo: newId)
          .get();
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final otherUsers = existing.docs.where((d) => d.id != uid);
      if (otherUsers.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('このユーザーIDは既に使用されています'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }
    }

    setState(() => _isSaving = true);
    try {
      final uid = widget.targetUserId ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final updateData = <String, dynamic>{
          'nickname': _nicknameCtrl.text.trim(),
          'nicknameNorm': normalizeForSearch(_nicknameCtrl.text.trim()),
          'bio': _bioCtrl.text.trim(),
          'experience': _selectedExperience,
          'area': _selectedArea,
          'avatarUrl': _avatarUrl,
          'socialLinks': {
            'instagram': _instagramCtrl.text.trim(),
            'facebook': _facebookCtrl.text.trim(),
            'x': _xCtrl.text.trim(),
            'tiktok': _tiktokCtrl.text.trim(),
            'youtube': _youtubeCtrl.text.trim(),
            'website': _websiteCtrl.text.trim(),
          },
        };

        // ユーザーIDは初回のみ設定可
        if (!_isIdLocked) {
          updateData['searchId'] = newId;
          updateData['searchIdNorm'] = normalizeForSearch(newId);
        }

        final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
        await userRef.update(updateData);

        if (!isOfficial) {
          final privateData = <String, dynamic>{
            'gender': _selectedGender,
            'birthDate': Timestamp.fromDate(_birthDate!),
            'updatedAt': FieldValue.serverTimestamp(),
          };
          await userRef.collection('private').doc('info').set(
                privateData,
                SetOptions(merge: true),
              );
        }

        // フォロワー・フォロー先のサブコレクションに保存された名前・アバターを同期
        final newNickname = _nicknameCtrl.text.trim();
        final newAvatar = _avatarUrl;
        final syncData = <String, dynamic>{
          'nickname': newNickname,
          'avatarUrl': newAvatar,
        };

        // followers（自分をフォローしている人の following サブコレクション内の自分のドキュメント）
        final followersSnap = await userRef.collection('followers').get();
        for (final doc in followersSnap.docs) {
          FirebaseFirestore.instance
              .collection('users').doc(doc.id)
              .collection('following').doc(uid)
              .update(syncData).catchError((_) {});
        }

        // following（自分がフォローしている人の followers サブコレクション内の自分のドキュメント）
        final followingSnap = await userRef.collection('following').get();
        for (final doc in followingSnap.docs) {
          FirebaseFirestore.instance
              .collection('users').doc(doc.id)
              .collection('followers').doc(uid)
              .update(syncData).catchError((_) {});
        }

        // 自分の投稿の userNickname / userAvatarUrl を同期
        final postsSnap = await FirebaseFirestore.instance
            .collection('posts')
            .where('userId', isEqualTo: uid)
            .get();
        for (final doc in postsSnap.docs) {
          doc.reference.update({
            'userNickname': newNickname,
            'userAvatarUrl': newAvatar,
          }).catchError((_) {});
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('プロフィールを更新しました！'),
            backgroundColor: AppTheme.success));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('エラーが発生しました: $e'),
            backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
