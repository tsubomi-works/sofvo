# 浮島型すりガラス・ボトムナビ（Floating Glass Bottom Nav）

Sofvo で実装した「Instagram 風・浮島型すりガラス・スクロールで縮むボトムナビ」の再利用メモ。
別アプリにそのまま持っていけるよう、**汎用版コード**・**実装の勘所（ハマりどころ）**・**別アプリに渡すプロンプト**をまとめる。

実体（Sofvo 内）: `lib/screens/home/main_tab_screen.dart`

> **2026-09-25 更新**: バー本体（すりガラスの浮島）は自作のまま。**移動中の泡だけ**、ネイティブ（iOS/Android）では
> pub パッケージ **`liquid_glass_widgets`** の `AdaptiveGlass`（ガラスシェーダー）で描くようにした（iOS 26 と同じく縁の屈折・色収差・光沢が出る）。
> Web は従来の `RawMagnifier` 近似のまま。泡は押した瞬間にガラス化し、形はバーから上下にはみ出す横長（幅≒1.5タブ）。
> 以下の汎用版コードはパッケージなしで動く近似版。

---

## 仕様（デザインの狙い）

- **浮島型（フローティング・ピル）**: 画面下に浮いた角丸バー（左右・下に余白＋影）
- **すりガラス（屈折）**: バー越しに後ろのコンテンツがぼけて透ける（`BackdropFilter` + 半透明白）
- **スクロールで縮む**: 下スクロールでラベルを畳んでアイコンだけ＋高さ/横幅を縮小、上スクロールで戻す
- **選択タブをカプセル強調**＋**未読バッジ**対応
- **コンテンツがバー後ろまで回り込む**（透ける演出に必須）

現在の主要パラメータ（好みで調整）:
| 項目 | 値 |
|---|---|
| 角丸 | 33（高さの半分以上を指定して常に完全なカプセル形） |
| 高さ | 通常 66 / 縮小 52 |
| 左右余白 | 通常 16 / 縮小 64（縮むと左右に絞る） |
| 下余白 | 8（`SafeArea(top:false)` の内側） |
| すりガラス透過 | `Colors.white.withValues(alpha: 0.85)`（低くしすぎると輪郭がぼやけて平坦に見える） |
| ぼかし | `ImageFilter.blur(20, 20)` |
| 影 | `black 0.14 / blur 24 / offset(0,6)` |
| 選択カプセル | Liquid Glass 風の水滴レンズ（下記参照）。汎用版コードは簡易版（ブランド色 alpha 0.10 / 角丸 22） |
| アニメ | 200〜220ms / easeOut（カプセルのスライドは 260ms easeOutCubic） |

### 選択カプセルの Liquid Glass 化（Sofvo 実体のみ・2026/07 追加）

iOS 26 の Liquid Glass の**本来の挙動**に合わせる: **静止時はただの薄いカプセル**で、
**タブ間を移動している間だけ**水滴ガラスに変化する（常時レンズ表示は白バーでは濁った塊に見えて失敗だった）。
本物の屈折歪みはフラグメントシェーダーが必要（Impeller 必須＝Web 非対応）なため使わず、全プラットフォームで動く近似で構成:

- **静止時**: バー内に収まる横長ピル。カプセルは**無色の透明ガラス**（黒 alpha 0.06 のみ）で、選択の主張は**アイコン＋ラベルのネイビー**（`AppTheme.primaryColor`）が担う。`BackdropFilter` なし（コスト削減＋濁り防止）
- **移動中だけガラス化**: `TweenAnimationBuilder`（`key: ValueKey(currentIndex)` で切替ごとに 0→1 再生）の `s = sin(πt)` を強度にして、
  - **`RawMagnifier` で下のコンテンツ（アイコン）を本当に屈折拡大**（`magnificationScale: 1 + 0.35 × s`）。BackdropFilter の行列変換なのでシェーダー不要＝Web でも動く
  - 縁の白いハイライト＋上面の白い反射（照り・控えめ）（alpha を `× s`）。**色は付けない**（虹色・ネイビーは不採用）。**影も付けない**（半透明の泡は影が中身から透けて全体が灰色がかるため）。静止時のグレー下地（黒6%）も移動中は `× (1 - s)` でフェードアウトし、泡は完全に無色
  - 曇りは `BackdropFilter.blur(1.5 × s)` のごくわずかだけ。**強いぼかしや濃い白みは拡大したアイコンを消して「霧の玉」になるので厳禁**（下のアイコンが透けて見えるのがレンズの命）
  - **移動中はほぼ真円の泡に膨らむ**: `scaleX +55% / scaleY +90%`（横長ピル→直径約95pxの球体。バーの上下に大きく飛び出す。外側 `Stack(clipBehavior: Clip.none)` でクリップしない）
  - **着地後は減衰振動でぷるぷる**: `wobble = sin(6πt) × e^(-4t)` を縦横逆位相で加算（体積保存風のジェリー）。アニメ全体は620ms、前半55%が膨らみ・残りが振動
  - **位置は easeOutBack** で勢い余って少し行き過ぎて戻る（液体の慣性）
  - 着地して振動が収まると元の薄いピルに戻る
  - **泡が乗っているタブが点灯**: 移動アニメは `AnimationController`（`_moveCtrl`）で持ち、泡の現在位置（easeOutBack を同じ時間比で再現）から「いま泡の下にあるタブ」を毎フレーム算出。そのタブのアイコン＋ラベルだけネイビー＆filledに点灯し、通過すると消灯する。なぞり中は指の下のタブ（`_dragHover`）が点灯
- **描画順**: バー背景 → タブ（アイコン＋ラベル）→ カプセル（最前面・`IgnorePointer` でタップは下に通す）。**アイコンをガラスの下に置く**ことで、移動中の泡が上を通るとアイコン自体が拡大・歪み・ぼけて見える（iOS 26 の「ガラス越しにアイコンの色が滲む」効果の核）。静止時のカプセルはほぼ透明なのでアイコンの見えには影響しない
- **指なぞりで泡が追従**: バーを横ドラッグすると泡（カプセル）がガラス化したまま指に追従し、離すと最寄りのタブに吸着して選択される。
  - バー全体を `GestureDetector(behavior: translucent)` で包み `onHorizontalDrag*` を拾う（タップは各タブの子が処理するので共存できる）
  - なぞり中は `AnimatedAlign` を 60ms/linear にしてピタッと追従、通常時は 260ms/easeOutCubic
  - ガラス化は `AnimationController`（180ms）でフェードイン/アウトし、タブ切替パルスと `max()` で合成
  - タブ境界を跨ぐたびに `HapticFeedback.selectionClick()`
  - ドラッグキャンセル時はタブを切り替えず泡だけ元に戻す

実装は `lib/screens/home/main_tab_screen.dart` の `_BottomNavState`（ドラッグ）と `_LiquidCapsule`（`glass` パラメータ）を参照。

---

## ⚠️ ハマりどころ（これを外すと「背景が残る／重なる」）

このナビは「バーの見た目」だけでは完成しない。**周辺レイアウト**とセットで効く。

1. **`Scaffold(extendBody: true)`**
   本文をバーの後ろまで広げる。これが無いと後ろにコンテンツが回り込まず、ガラスが効かない。

2. **各タブ画面の `body: SafeArea(bottom: false, ...)`**
   `SafeArea` の下端インセットがあると、コンテンツがバー手前で止まり「バー後ろが空白／別背景」になる。
   `bottom: false` で**コンテンツをバー後ろまで伸ばす**のが「透ける」最大のキモ。
   （`CustomScrollView` 中心の画面は元々 SafeArea で囲っていないことが多く、そのままで OK）

3. **各スクロール（ListView 等）の下パディング ≒ バー高さ + 余白（例: 92 + safe area）**
   コンテンツはバー後ろを流れるので、**最下部の項目や FAB がバーに隠れない**よう下に「逃がし」を入れる。
   例: `padding: EdgeInsets.only(bottom: 92 + MediaQuery.of(context).padding.bottom)`

4. **FAB は持ち上げる**
   画面に `FloatingActionButton` がある場合、浮島バーと重なる。`Padding(child: FAB)` で上げる。
   ただしバー自体が**セーフエリア分（`padding.bottom * 0.75`）だけ上に浮く**ため、固定値 `76` だけだと
   ホームインジケータのある端末（iPhone 等）で隙間が消えて接触する。同じ量を足して追従させること:
   `Padding(padding: EdgeInsets.only(bottom: 76 + MediaQuery.of(context).padding.bottom * 0.75), child: FAB)`

5. **ページ背景は白（バー後ろに「帯」を作らない）**
   ページ背景がグレーだと、半透明バー越しにグレーが見える。白背景＋白系ガラスにすると馴染む。

6. **スクロール検知は最上位で**
   `NotificationListener<UserScrollNotification>` で body 全体を包み、`ScrollDirection.reverse/forward` で縮小フラグを切り替える。`ValueNotifier<bool>` にして `ValueListenableBuilder` でバーだけ再描画（リスト全体を rebuild しない）。

7. **Flutter Web は CanvasKit/Impeller 前提**（`BackdropFilter` が効く）。デプロイ後はキャッシュ（Service Worker）が強いので**シークレットタブ**で確認。

---

## 汎用版コード（Firebase・独自テーマ非依存・コピペ可）

`floating_glass_nav.dart` として配置すれば単体で動く。色・タブはコンストラクタで差し替え。

```dart
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// 1タブの定義
class GlassNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int badge; // 0 ならバッジ非表示
  const GlassNavItem({
    required this.icon,
    IconData? activeIcon,
    required this.label,
    this.badge = 0,
  }) : activeIcon = activeIcon ?? icon;
}

/// 浮島型すりガラス・ボトムナビを備えた Scaffold ラッパー。
/// - extendBody / スクロール縮小 / すりガラス をまとめて提供。
/// - 各タブ画面側で「body は SafeArea(bottom:false)」「リストの下パディング」「FABの持ち上げ」を忘れずに。
class GlassNavScaffold extends StatefulWidget {
  final List<GlassNavItem> items;
  final List<Widget> pages;          // items と同数
  final Color selectedColor;         // 選択アイコン/ラベル色（ブランド色）
  final Color unselectedColor;       // 非選択色
  final Color badgeColor;
  final int initialIndex;

  const GlassNavScaffold({
    super.key,
    required this.items,
    required this.pages,
    this.selectedColor = const Color(0xFF1B3A5C),
    this.unselectedColor = const Color(0xFF8A94A6),
    this.badgeColor = const Color(0xFFE5484D),
    this.initialIndex = 0,
  });

  @override
  State<GlassNavScaffold> createState() => _GlassNavScaffoldState();
}

class _GlassNavScaffoldState extends State<GlassNavScaffold> {
  late int _index = widget.initialIndex;
  final ValueNotifier<bool> _collapsed = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _collapsed.dispose();
    super.dispose();
  }

  bool _onScroll(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.direction == ScrollDirection.reverse) {
      _collapsed.value = true;   // 下スクロール → 縮める
    } else if (n.direction == ScrollDirection.forward) {
      _collapsed.value = false;  // 上スクロール → 戻す
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true, // ★ 本文をバー後ろまで広げる
      body: NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: IndexedStack(index: _index, children: widget.pages),
      ),
      bottomNavigationBar: _GlassBar(
        items: widget.items,
        currentIndex: _index,
        collapsed: _collapsed,
        selectedColor: widget.selectedColor,
        unselectedColor: widget.unselectedColor,
        badgeColor: widget.badgeColor,
        onTap: (i) {
          _collapsed.value = false; // タブ切替時は展開
          setState(() => _index = i);
        },
      ),
    );
  }
}

class _GlassBar extends StatelessWidget {
  final List<GlassNavItem> items;
  final int currentIndex;
  final ValueListenable<bool> collapsed;
  final ValueChanged<int> onTap;
  final Color selectedColor, unselectedColor, badgeColor;
  const _GlassBar({
    required this.items,
    required this.currentIndex,
    required this.collapsed,
    required this.onTap,
    required this.selectedColor,
    required this.unselectedColor,
    required this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ValueListenableBuilder<bool>(
        valueListenable: collapsed,
        builder: (context, isCollapsed, _) {
          final bar = Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _GlassNavTile(
                    data: items[i],
                    selected: i == currentIndex,
                    collapsed: isCollapsed,
                    selectedColor: selectedColor,
                    unselectedColor: unselectedColor,
                    badgeColor: badgeColor,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          );
          return AnimatedPadding(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            padding: EdgeInsets.fromLTRB(
                isCollapsed ? 64 : 16, 4, isCollapsed ? 64 : 16, 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(33),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 24,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(33),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    height: isCollapsed ? 52 : 66,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85), // 透過：小さいほど透ける（下げすぎると平坦に見える）
                      borderRadius: BorderRadius.circular(33),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.55), width: 1),
                    ),
                    child: bar,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GlassNavTile extends StatelessWidget {
  final GlassNavItem data;
  final bool selected, collapsed;
  final VoidCallback onTap;
  final Color selectedColor, unselectedColor, badgeColor;
  const _GlassNavTile({
    required this.data,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    required this.selectedColor,
    required this.unselectedColor,
    required this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        margin: EdgeInsets.symmetric(horizontal: 5, vertical: collapsed ? 6 : 9),
        decoration: BoxDecoration(
          color: selected ? selectedColor.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _icon(color),
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
    final w = Icon(selected ? data.activeIcon : data.icon, size: 25, color: color);
    if (data.badge > 0) {
      return Badge(
        backgroundColor: badgeColor,
        label: Text('${data.badge}',
            style: const TextStyle(fontSize: 10, color: Colors.white)),
        child: w,
      );
    }
    return w;
  }
}
```

### 使い方（各タブ画面側で必須の3点）

```dart
GlassNavScaffold(
  items: const [
    GlassNavItem(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'ホーム'),
    GlassNavItem(icon: Icons.search, label: 'さがす'),
    GlassNavItem(icon: Icons.chat_bubble_outline, activeIcon: Icons.chat_bubble, label: 'チャット', badge: 3),
    GlassNavItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'マイページ'),
  ],
  pages: [HomePage(), SearchPage(), ChatPage(), MyPage()],
);

// 各ページ側で：
// 1) body: SafeArea(bottom: false, child: ...)
// 2) ListView( padding: EdgeInsets.only(bottom: 92 + MediaQuery.of(context).padding.bottom) )
// 3) FAB は Padding(padding: EdgeInsets.only(bottom: 76 + MediaQuery.of(context).padding.bottom * 0.75), child: FloatingActionButton(...))
// 4) ページ背景は白（Scaffold(backgroundColor: Colors.white)）
```

---

## 別アプリに渡すプロンプト（コピペ用）

> Flutter アプリのボトムナビを「Instagram 風の浮島型すりガラス・ナビ」にしてください。要件：
>
> 1. **浮島型**：画面下に浮いた完全カプセル形（角丸は高さの半分以上、例: 33）のバー。左右16・下8の余白＋柔らかい影（black 0.14 / blur 24 / offset(0,6)）で浮かせる。
> 2. **すりガラス（屈折）**：`BackdropFilter`(`ImageFilter.blur(20,20)`) ＋ 半透明白(`Colors.white` alpha 0.85) ＋ 白の細枠。バー越しに後ろのコンテンツがうっすらぼけて透けること（透過を強くしすぎると輪郭がぼやけて平坦に見えるので注意）。
> 3. **スクロールで縮む**：最上位を `NotificationListener<UserScrollNotification>` で包み、下スクロール(`ScrollDirection.reverse`)でラベルを畳んでアイコンのみ・高さ66→52・左右余白16→64に縮小、上スクロールで復帰。`ValueNotifier<bool>`＋`ValueListenableBuilder` でバーだけ再描画。アニメは200〜220ms easeOut。
> 4. **選択タブ**：ブランド色 alpha0.10 の角丸カプセルで強調。アイコンは outlined/filled を切替。**未読バッジ**対応。
> 5. **重要なレイアウト要件（これが無いと崩れる）**：
>    - 親 `Scaffold(extendBody: true)`
>    - 各タブ画面の `body` は `SafeArea(bottom: false, ...)`（コンテンツをバー後ろまで伸ばす）
>    - 各スクロールの下パディングを `92 + MediaQuery.padding.bottom` 程度にして最下部の項目やボタンがバーに隠れないようにする
>    - `FloatingActionButton` は下に `76 + MediaQuery.padding.bottom * 0.75` 持ち上げてバーと重ならないようにする（固定76だけだとホームインジケータのある端末で接触する）
>    - ページ背景は白にして、半透明バー越しにグレーの帯が出ないようにする
> 6. プラットフォームは Android / iOS / Web で同じ見た目にすること（Web は CanvasKit で `BackdropFilter` を有効化）。
>
> 上記を満たす再利用可能なウィジェット（`GlassNavScaffold` と `GlassNavItem`）として実装し、色・タブ・バッジはコンストラクタで差し替えられるようにしてください。

---

## 調整チートシート

| やりたいこと | 変える場所 |
|---|---|
| もっと透ける | `color: Colors.white.withValues(alpha: 0.85)` の数値を下げる（下げすぎると平坦に見える） |
| ぼかしを強く/弱く | `ImageFilter.blur(20, 20)` の数値 |
| バーを下げる/上げる | `AnimatedPadding` の下余白（現 8） |
| 角をもっと丸く | `BorderRadius.circular(33)`（高さの半分以上なら完全カプセル） |
| 縮みを強く | 縮小時の `height`(52) と左右 `64` |
| 影を消す | `boxShadow` を削除（白背景なら枠線だけでも可） |
| 常にラベル表示 | `_GlassNavTile` の `collapsed` 分岐を無効化 |
| 静止時カプセルの濃さ | Sofvo実体: `_LiquidCapsule` の黒 alpha 0.06（無色ガラス） |
| 選択アイコンの色 | Sofvo実体: `_NavItem` の `AppTheme.primaryColor`（ネイビー） |
| 移動中レンズの拡大率 | Sofvo実体: `_LiquidCapsule` の `magnificationScale: 1 + 0.35 * glass` |
| 移動中ガラスの曇り | Sofvo実体: `_LiquidCapsule` の `blur(1.5 × glass)`（上げすぎ厳禁） |
| 移動中の泡の丸さ・大きさ | Sofvo実体: `scaleX: 1 + 0.55 * glass` / `scaleY: 1 + 0.90 * glass`（縦横比≒1で真円） |
| ぷるぷるの強さ・減衰 | Sofvo実体: `0.06 * wobble`（振幅）・`sin(6πt) × e^(-4t)`（周波数・減衰） |
</content>
</invoke>
