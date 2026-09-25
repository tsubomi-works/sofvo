import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../config/app_theme.dart';
import '../../widgets/connectivity_banner.dart';
import '../../widgets/ban_guard.dart';
import '../home/home_screen.dart';
import '../tournament/tournament_search_screen.dart';
import '../recruitment/recruitment_screen.dart';
import '../chat/chat_list_screen.dart';
import '../profile/my_page_screen.dart';
import '../profile/profile_completion_screen.dart';

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 0;

  // 下スクロールでボトムナビを縮める（Instagram 風）
  final ValueNotifier<bool> _navCollapsed = ValueNotifier<bool>(false);

  final List<Widget> _screens = [
    const HomeScreen(),
    const TournamentSearchScreen(),
    const RecruitmentScreen(),
    const ChatListScreen(),
    const MyPageScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // 必須化以前に登録した既存ユーザーの未入力チェック（起動後に1回）
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkProfileCompletion());
  }

  /// ユーザーID・性別・生年月日・都道府県が未入力なら追加入力画面を表示する。
  /// 公式・デモアカウントは対象外。旧マップ形式の area は文字列へ静かに移行する。
  Future<void> _checkProfileCompletion() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
      // 起動直後はローカルキャッシュ（＝前回の未入力状態）が返り、保存済みでも
      // 再表示される。必ずサーバー最新を読む（オフライン時は例外→今回はスキップ）。
      final userDoc = await userRef.get(const GetOptions(source: Source.server));
      final data = userDoc.data();
      if (data == null) return;
      if (data['isOfficial'] == true || data['isDemo'] == true) return;

      // area は文字列（都道府県名）が基本。旧データはマップ {prefecture, city}
      final rawArea = data['area'];
      final area = rawArea is String
          ? rawArea
          : (rawArea is Map ? (rawArea['prefecture'] ?? '').toString() : '');
      if (rawArea is Map && area.isNotEmpty) {
        // おすすめ表示等のクエリが area 文字列前提のため移行しておく
        userRef.update({'area': area}).catchError((_) {});
      }

      final searchId = (data['searchId'] ?? '').toString();

      // 性別・生年月日は private/info が基本だが、旧ユーザーはメインドキュメント側に
      // 入っていることがあるため両方を見る（my_page と同じフォールバック）。
      String gender = (data['gender'] ?? '').toString();
      bool hasBirthDate = data['birthDate'] != null;
      try {
        final privateDoc = await userRef
            .collection('private')
            .doc('info')
            .get(const GetOptions(source: Source.server));
        final p = privateDoc.data() ?? {};
        if ((p['gender'] ?? '').toString().isNotEmpty) gender = p['gender'].toString();
        if (p['birthDate'] != null) hasBirthDate = true;
      } catch (_) {
        // private が読めない時はメインドキュメント側の判定に委ねる
      }

      final needsSearchId = searchId.isEmpty;
      final needsGender = gender.isEmpty;
      final needsBirthDate = !hasBirthDate;
      final needsArea = area.isEmpty;
      if (!(needsSearchId || needsGender || needsBirthDate || needsArea)) return;
      if (!mounted) return;

      Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ProfileCompletionScreen(
          needsSearchId: needsSearchId,
          needsGender: needsGender,
          needsBirthDate: needsBirthDate,
          needsArea: needsArea,
        ),
      ));
    } catch (e) {
      debugPrint('プロフィール未入力チェックに失敗: $e');
    }
  }

  @override
  void dispose() {
    _navCollapsed.dispose();
    super.dispose();
  }

  bool _onScroll(UserScrollNotification n) {
    // ネストしたスクロール（横スクロール等）は無視
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.direction == ScrollDirection.reverse) {
      _navCollapsed.value = true; // 下にスクロール → 縮める
    } else if (n.direction == ScrollDirection.forward) {
      _navCollapsed.value = false; // 上にスクロール → 戻す
    }
    return false;
  }

  // ホーム・チャット = 白背景 → ダークアイコン, マイページ = 暗い背景 → ライトアイコン
  // さがす・マイ大会 = AppBarが自動でハンドル
  SystemUiOverlayStyle _statusBarStyle() {
    switch (_currentIndex) {
      case 4: // マイページ（ダークヘッダー）
        return SystemUiOverlayStyle.light;
      default: // ホーム・さがす・マイ大会・チャット
        return SystemUiOverlayStyle.dark;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BanGuard(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _statusBarStyle(),
        child: Scaffold(
          extendBody: true,
          body: NotificationListener<UserScrollNotification>(
            onNotification: _onScroll,
            child: ConnectivityBanner(
              child: IndexedStack(
                index: _currentIndex,
                children: _screens,
              ),
            ),
          ),
          bottomNavigationBar: _BottomNav(
            currentIndex: _currentIndex,
            collapsed: _navCollapsed,
            onDestinationSelected: (index) {
              _navCollapsed.value = false; // タブ切替時は展開して見せる
              setState(() => _currentIndex = index);
            },
          ),
        ),
      ),
    );
  }
}

/// 分離されたナビゲーションバー — チャットバッジの更新で他のタブがリビルドされない
///
/// iOS 26 の Liquid Glass を liquid_glass_widgets の GlassTabBar で描く。
/// ネイティブ（Impeller）はシェーダーで縁の屈折・色収差・光沢まで再現し、
/// Web は軽量シェーダーに自動で切り替わる（プラットフォーム分岐はパッケージ側）。
/// 下スクロールで選択中タブの丸だけに縮み（iOS 26 の tabBarMinimizeBehavior）、
/// 縮んだ丸をタップ or 上スクロールで元に戻る。
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.collapsed,
  });
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final ValueNotifier<bool> collapsed;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return StreamBuilder<QuerySnapshot>(
      stream: uid.isNotEmpty
          ? FirebaseFirestore.instance
              .collection('chats')
              .where('members', arrayContains: uid)
              .snapshots()
          : null,
      builder: (context, chatSnap) {
        int unreadCount = 0;
        if (chatSnap.hasData) {
          for (final doc in chatSnap.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final lastMessage = (data['lastMessage'] as String?) ?? '';
            if (lastMessage.isEmpty) continue;
            // lastRead vs lastMessageAt のタイムスタンプ比較で判定
            final lastRead = (data['lastRead'] as Map<String, dynamic>?)?[uid];
            final lastMsg = data['lastMessageAt'];
            if (lastMsg is Timestamp) {
              if (lastRead == null || (lastRead is Timestamp && lastMsg.toDate().isAfter(lastRead.toDate()))) {
                // unreadCountマップから件数を取得（あれば）
                final unreadMap = data['unreadCount'] as Map<String, dynamic>?;
                final raw = unreadMap?[uid];
                final cnt = (raw is int) ? raw : (raw is num) ? raw.toInt() : 0;
                unreadCount += cnt > 0 ? cnt : 1;
              }
            }
          }
        }

        final tabs = <GlassTab>[
          const GlassTab(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'ホーム'),
          const GlassTab(icon: Icon(Icons.search_outlined), activeIcon: Icon(Icons.search), label: 'さがす'),
          const GlassTab(
              icon: Icon(Icons.calendar_today_outlined),
              activeIcon: Icon(Icons.calendar_today),
              label: 'マイ大会'),
          GlassTab(
            icon: _withBadge(const Icon(Icons.chat_bubble_outline), unreadCount),
            activeIcon: _withBadge(const Icon(Icons.chat_bubble), unreadCount),
            label: 'チャット',
          ),
          const GlassTab(icon: Icon(Icons.person_outline), activeIcon: Icon(Icons.person), label: 'マイページ'),
        ];

        // セーフエリア（ホームインジケータ領域）の余白を一部だけ残して下に詰める
        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom * 0.75),
          child: ValueListenableBuilder<bool>(
            valueListenable: collapsed,
            builder: (context, isCollapsed, _) => GlassTabBar.minimizable(
              tabs: tabs,
              selectedIndex: currentIndex,
              onTabSelected: onDestinationSelected,
              minimized: isCollapsed,
              onMinimizedTabTap: () => collapsed.value = false,
              horizontalPadding: 16,
              verticalPadding: 5,
              barHeight: 64,
              minimizedBarHeight: 52,
              // 選択中はブランドネイビーで主張、非選択は濃いグレー
              selectedIconColor: AppTheme.primaryColor,
              unselectedIconColor: Colors.black87,
              selectedLabelColor: AppTheme.primaryColor,
              unselectedLabelColor: Colors.black87,
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
              iconSize: 25,
            ),
          ),
        );
      },
    );
  }

  static Widget _withBadge(Widget icon, int count) {
    if (count <= 0) return icon;
    return Badge(
      label: Text('$count', style: const TextStyle(fontSize: 10, color: Colors.white)),
      backgroundColor: AppTheme.error,
      child: icon,
    );
  }
}
