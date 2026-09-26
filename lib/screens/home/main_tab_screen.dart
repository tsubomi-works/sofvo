import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';
import '../../widgets/connectivity_banner.dart';
import '../../widgets/ban_guard.dart';
import '../home/home_screen.dart';
import '../tournament/tournament_search_screen.dart';
import '../recruitment/recruitment_screen.dart';
import '../chat/chat_list_screen.dart';
import '../profile/my_page_screen.dart';
import '../profile/profile_completion_screen.dart';
import '../../services/notification_service.dart';

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
class _BottomNav extends StatefulWidget {
  const _BottomNav({
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.collapsed,
  });
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final ValueListenable<bool> collapsed;

  @override
  State<_BottomNav> createState() => _BottomNavState();
}

class _BottomNavState extends State<_BottomNav>
    with TickerProviderStateMixin {
  // 指でなぞっている間のガラス化（1へフェードイン、離すとフェードアウト）
  late final AnimationController _glassCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  // タブ切替アニメ（前半で泡化して移動、後半でぷるぷる収束）。
  // 泡の現在位置からアイコンの点灯タブも算出するためコントローラで持つ
  late final AnimationController _moveCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
    value: 1.0, // 初期状態は着地済み
  );
  int _prevIndex = 0; // 直前に選択されていたタブ（移動の始点）
  bool _dragging = false;
  double _dragFrac = 0; // バー幅に対する指の位置（0〜1）
  int _dragHover = -1; // なぞり中に指が乗っているタブ（ハプティクス用）

  // 位置アニメ（300ms/easeOutBack）は全体620msのうちの前半に相当する
  static const double _movePhase = 300 / 620;

  @override
  void initState() {
    super.initState();
    _prevIndex = widget.currentIndex;
  }

  @override
  void didUpdateWidget(covariant _BottomNav old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex != old.currentIndex) {
      _prevIndex = old.currentIndex;
      _moveCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _glassCtrl.dispose();
    _moveCtrl.dispose();
    super.dispose();
  }

  /// いま泡が乗っているタブ。このタブのアイコンをネイビーに点灯させる
  int _bubbleTab(int n) {
    if (_dragging) return _dragHover;
    final t = _moveCtrl.value;
    if (t >= 1) return widget.currentIndex;
    // AnimatedAlign と同じカーブ・時間比で泡の現在位置を再現する
    final p = Curves.easeOutBack
        .transform(math.min(t / _movePhase, 1.0));
    final f = _prevIndex + (widget.currentIndex - _prevIndex) * p;
    return f.round().clamp(0, n - 1);
  }

  // 指の位置（0〜1）→ カプセル中心の Alignment.x（スロット中心にクランプ）
  double _alignForFrac(double f, int n) {
    if (n <= 1) return 0;
    final x = ((f - 0.5 / n) / (1 - 1 / n)) * 2 - 1;
    return x.clamp(-1.0, 1.0);
  }

  int _hoverIndex(double f, int n) => ((f * n).floor()).clamp(0, n - 1);

  void _onDragStart(double dx, double width, int n) {
    setState(() {
      _dragging = true;
      _dragFrac = (dx / width).clamp(0.0, 1.0);
      _dragHover = _hoverIndex(_dragFrac, n);
    });
    _glassCtrl.forward();
  }

  void _onDragUpdate(double dx, double width, int n) {
    final f = (dx / width).clamp(0.0, 1.0);
    final hover = _hoverIndex(f, n);
    if (hover != _dragHover) {
      HapticFeedback.selectionClick(); // タブ境界を跨いだらコツッと
    }
    setState(() {
      _dragFrac = f;
      _dragHover = hover;
    });
  }

  void _onDragEnd(int n) {
    final target = _hoverIndex(_dragFrac, n);
    setState(() => _dragging = false);
    _glassCtrl.reverse();
    widget.onDestinationSelected(target); // 最寄りのタブに吸着
  }

  void _onDragCancel() {
    // キャンセル時はタブを切り替えず、泡だけ元のタブへ戻す
    setState(() => _dragging = false);
    _glassCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    // ホームタブのバッジ = ベル通知（対人アクション）＋お知らせタブの未読合計
    return StreamBuilder<int>(
      stream: uid.isNotEmpty
          ? NotificationService.unreadCountStream(uid)
          : Stream.value(0),
      builder: (context, actionSnap) {
        return StreamBuilder<int>(
          stream: uid.isNotEmpty
              ? NotificationService.unreadAnnouncementCountStream(uid)
              : Stream.value(0),
          builder: (context, announceSnap) {
            final homeBadge = (actionSnap.data ?? 0) + (announceSnap.data ?? 0);

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

        final items = <_NavItemData>[
          _NavItemData(Icons.home_outlined, Icons.home, 'ホーム', badge: homeBadge),
          const _NavItemData(Icons.search_outlined, Icons.search, 'さがす'),
          const _NavItemData(Icons.calendar_today_outlined, Icons.calendar_today, 'マイ大会'),
          _NavItemData(Icons.chat_bubble_outline, Icons.chat_bubble, 'チャット', badge: unreadCount),
          const _NavItemData(Icons.person_outline, Icons.person, 'マイページ'),
        ];

        // セーフエリア（ホームインジケータ領域）の余白を一部だけ残して下に詰める
        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom * 0.75),
          child: ValueListenableBuilder<bool>(
            valueListenable: widget.collapsed,
            builder: (context, isCollapsed, _) {
              final n = items.length;
              // 比率ベース配置: 縮小（幅変化）に追従しつつ、タブ切替時だけスライド。
              // なぞり中は指の位置に追従する
              final alignX = _dragging
                  ? _alignForFrac(_dragFrac, n)
                  : n <= 1
                      ? 0.0
                      : (widget.currentIndex / (n - 1)) * 2 - 1;
              return AnimatedPadding(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                // 縮小時は左右に絞って小さく見せる
                padding: EdgeInsets.fromLTRB(
                  isCollapsed ? 64 : 16, 4, isCollapsed ? 64 : 16, 6),
                child: LayoutBuilder(builder: (context, box) {
                  final width = box.maxWidth;
                  return GestureDetector(
                    // タップは各タブ（子）が処理。横ドラッグだけここで拾い、
                    // 泡（カプセル）を指に追従させる
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (d) =>
                        _onDragStart(d.localPosition.dx, width, n),
                    onHorizontalDragUpdate: (d) =>
                        _onDragUpdate(d.localPosition.dx, width, n),
                    onHorizontalDragEnd: (_) => _onDragEnd(n),
                    onHorizontalDragCancel: _onDragCancel,
                    child: Stack(
                  // 移動中に膨らむ選択カプセルをクリップしない
                  clipBehavior: Clip.none,
                  children: [
                    // すりガラスのバー本体（背景のみ・タブは最前面のRowが描く）
                    DecoratedBox(
                      decoration: BoxDecoration(
                        // 高さ以上の角丸を指定して常に完全なカプセル形にする
                        borderRadius: BorderRadius.circular(33),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.14),
                            blurRadius: 24,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      // すりガラス（屈折）: 後ろのコンテンツをぼかして透かす
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(33),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                            height: isCollapsed ? 52 : 66,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(33),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.55),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // タブ（アイコン＋ラベル）はガラスの下に置く。
                    // 移動中の泡が上を通るとアイコン自体が拡大・歪んで見える
                    // （iOS 26 と同じ「ガラス越しにアイコンの色が滲む」効果）
                    Positioned.fill(
                      // 泡が乗っているタブだけネイビーに点灯（通過中も追従）
                      child: AnimatedBuilder(
                        animation: _moveCtrl,
                        builder: (context, _) {
                          final bubbleTab = _bubbleTab(n);
                          return Row(
                            children: [
                              for (var i = 0; i < items.length; i++)
                                Expanded(
                                  child: _NavItem(
                                    data: items[i],
                                    selected: i == bubbleTab,
                                    collapsed: isCollapsed,
                                    onTap: () =>
                                        widget.onDestinationSelected(i),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    // 選択カプセル（最前面。タップは下のタブに通す）
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedAlign(
                        // なぞり中は指にピタッと追従。通常は勢い余って
                        // 少し行き過ぎて戻る（液体の慣性）
                        duration: Duration(milliseconds: _dragging ? 60 : 300),
                        curve:
                            _dragging ? Curves.linear : Curves.easeOutBack,
                        alignment: Alignment(alignX, 0),
                        child: FractionallySizedBox(
                          widthFactor: 1 / n,
                          heightFactor: 1,
                          child: Padding(
                            // 横は目一杯近くまで広げて横長のピルにする
                            padding: EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: isCollapsed ? 6 : 8),
                            child: AnimatedBuilder(
                              // タブ切替で _moveCtrl が0→1を再生。前半は泡
                              // （ほぼ真円）に膨らんでガラス化し、着地後は
                              // 減衰振動でぷるぷる震えながら元の薄いピルに戻る
                              animation: Listenable.merge(
                                  [_moveCtrl, _glassCtrl]),
                              builder: (context, _) {
                                final t = _moveCtrl.value;
                                // 前半55%で膨らんで戻る山なりカーブ
                                final pulse = math.sin(
                                    math.pi * math.min(t / 0.55, 1.0));
                                // 着地後のジェリー振動（減衰するサイン波）
                                final wobble = math.sin(math.pi * 6 * t) *
                                    math.exp(-4 * t);
                                // なぞり中のガラス化（_glassCtrl）と
                                // タブ切替パルスの強い方を採用
                                final glass =
                                    math.max(pulse, _glassCtrl.value);
                                // 縦を大きく伸ばして移動中はほぼ真円の
                                // 泡にする。wobble は縦横逆位相＝体積が
                                // 保存されたような「ぷるぷる」
                                return Transform.scale(
                                  scaleX:
                                      1 + 0.55 * glass + 0.06 * wobble,
                                  scaleY:
                                      1 + 0.90 * glass - 0.06 * wobble,
                                  child: _LiquidCapsule(glass: glass),
                                );
                              },
                            ),
                          ),
                        ),
                        ),
                      ),
                    ),
                  ],
                    ),
                  );
                }),
              );
            },
          ),
        );
      },
    );
          },
        );
      },
    );
  }
}

/// 選択カプセル。色を付けない「透明なガラス」— 静止時はごく薄いニュートラルの
/// ピル、タブ間を移動する間だけ「液体ガラス」になる（iOS 26 の挙動の近似）:
/// RawMagnifier で下のコンテンツ（アイコン）を本当に屈折拡大し、縁の白い光・
/// 上面の照り・足元の影をまとって膨らみながら滑り、着地すると戻る。色は付けない。
/// 選択の主張はカプセルの色ではなくアイコン（ネイビー）が担う。
/// RawMagnifier は BackdropFilter の行列変換なのでシェーダー不要＝Webでも動く。
class _LiquidCapsule extends StatelessWidget {
  const _LiquidCapsule({required this.glass});

  /// 0 = 静止（透明なガラスのピル）〜 1 = 移動中のピーク（ガラスの水滴）
  final double glass;

  @override
  Widget build(BuildContext context) {
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        // 静止時: 輪郭が分かる程度のごく薄いグレー。
        // 移動中はフェードアウトして完全に無色のガラスにする
        // （グレーを残すと泡全体が灰色がかって見える）
        color: Colors.black.withValues(alpha: 0.06 * (1 - glass)),
        borderRadius: BorderRadius.circular(25),
      ),
      // 上面の白い反射（ガラスの照り）— ごく控えめ。強くすると霧の玉になる
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.18 * glass),
              Colors.white.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.5],
          ),
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        // 高さの半分以上の角丸で常に完全なカプセル形
        borderRadius: BorderRadius.circular(26),
        // 移動中だけ縁が白く光る（色は付けない・静止時は透明）
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.90 * glass),
            Colors.white.withValues(alpha: 0.25 * glass),
            Colors.white.withValues(alpha: 0.12 * glass),
            Colors.white.withValues(alpha: 0.28 * glass),
            Colors.white.withValues(alpha: 0.70 * glass),
          ],
          stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
        ),
        // 影は付けない: 半透明の泡は影が中身から透けて全体が
        // 灰色がかって見えるため（輪郭は縁の白いハイライトが担う）
      ),
      child: Padding(
        // 縁の線の太さ（グラデーションが見える幅）
        padding: const EdgeInsets.all(1.4),
        // 静止時はレンズ類を一切組み込まない（コスト削減＋濁り防止）
        child: glass < 0.01
            ? fill
            : LayoutBuilder(builder: (context, c) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(25),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 本物のレンズ: 泡の下のコンテンツ（アイコン）を屈折拡大する
                      // （RawMagnifier = BackdropFilter の行列変換。シェーダー不要）
                      RawMagnifier(
                        size: Size(c.maxWidth, c.maxHeight),
                        magnificationScale: 1 + 0.35 * glass,
                        decoration: const MagnifierDecoration(
                          shape: StadiumBorder(),
                        ),
                      ),
                      // ごくわずかな曇りだけ乗せる。強いぼかしは拡大した
                      // アイコンを消して「霧の玉」になるので厳禁
                      BackdropFilter(
                        filter: ImageFilter.blur(
                            sigmaX: 1.5 * glass, sigmaY: 1.5 * glass),
                        child: fill,
                      ),
                    ],
                  ),
                );
              }),
      ),
    );
  }
}

/// 浮島型ボトムナビのタブ定義
class _NavItemData {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int badge;
  const _NavItemData(this.icon, this.activeIcon, this.label, {this.badge = 0});
}

/// 1タブ分。選択時は角丸カプセルで強調する。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.data,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final _NavItemData data;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 選択中はブランドネイビーで主張、非選択は濃いグレー
    final color = selected ? AppTheme.primaryColor : Colors.black87;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        margin: EdgeInsets.symmetric(horizontal: 5, vertical: collapsed ? 6 : 9),
        // 選択カプセルはスライドする背面側（_LiquidCapsule）が描くためここは透明
        decoration: const BoxDecoration(),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _icon(color),
            // 縮小時はラベルを畳んでアイコンだけにする
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: collapsed
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          data.label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.0,
                            color: color,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
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

  Widget _icon(Color color) {
    final iconWidget = Icon(selected ? data.activeIcon : data.icon, size: 25, color: color);
    if (data.badge > 0) {
      return Badge(
        label: Text('${data.badge}', style: const TextStyle(fontSize: 10, color: Colors.white)),
        backgroundColor: AppTheme.error,
        child: iconWidget,
      );
    }
    return iconWidget;
  }
}
