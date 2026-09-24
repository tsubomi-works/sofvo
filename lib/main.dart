// Sofvo v1.1
import 'dart:async';
import 'dart:io' show Platform;
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/bookmark_notification_service.dart';
import 'services/push_notification_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'config/app_theme.dart';
import 'services/auth_service.dart';
import 'services/follow_service.dart';
import 'services/notification_service.dart';
import 'services/invite_service.dart';
import 'services/update_check_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/register_screen.dart';
import 'screens/profile/profile_setup_screen.dart';
import 'screens/home/main_tab_screen.dart';
import 'screens/tournament/tournament_detail_screen.dart';
import 'services/in_app_browser.dart';
import 'utils/tournament_checkin_link.dart';
import 'utils/in_app_link.dart';
import 'demo/demo_service.dart';
import 'demo/demo_overlay.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// 認証状態の変化を一時的に無視するフラグ
/// （未登録アカウントのチェック中に画面がちらつくのを防止）
bool suppressAuthStateChange = false;

/// 招待リンクで渡された大会ID（?t=xxx）
String? pendingTournamentId;

/// セルフチェックイン用の大会ID（?checkin=xxx）
String? pendingCheckInTournamentId;

/// 友達紹介リンクで渡された紹介者UID（?ref=xxx）
String? pendingReferrerUserId;

/// 招待コード（?code=XXXXXX）。友達紹介・チーム招待・大会招待の共通コード。
/// クリップボードに頼らず、登録後に redeemInvite で相互フォロー＋チーム参加を確定する。
String? pendingInviteCode;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (kIsWeb) {
    // LINEなどのアプリ内ブラウザではセッション永続化を無効にして
    // 他のユーザーにセッションが漏洩するのを防ぐ
    final persistFuture = FirebaseAuth.instance.setPersistence(
      isInAppBrowser() ? Persistence.SESSION : Persistence.LOCAL,
    );
    // getRedirectResult は非同期で実行（ブロックしない）
    // リダイレクト後のログイン状態は authStateChanges リスナーが拾う
    FirebaseAuth.instance.getRedirectResult().catchError((e) {
      debugPrint('getRedirectResult error: $e');
    });
    await persistFuture;

    // URLパラメータ or パスから招待リンクの大会IDを取得
    final uri = Uri.base;
    pendingTournamentId = uri.queryParameters['t'];
    pendingReferrerUserId = uri.queryParameters['ref'];
    pendingInviteCode = uri.queryParameters['code'];
    final checkinId = parseCheckInTournamentIdFromDeepLinkUri(uri);
    if (checkinId != null && checkinId.isNotEmpty) {
      pendingCheckInTournamentId = checkinId;
    }
    if (pendingTournamentId == null && uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'tournament') {
      pendingTournamentId = uri.pathSegments[1];
    }
    // ログイン不要の体験デモ（/demo または ?demo=1）
    DemoService.detectFromUri(uri);
  }

  // Firestore 設定（Web は SDK 12.x の Watch 不整合対策で long polling 検出を有効化）
  if (kIsWeb) {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
      webExperimentalAutoDetectLongPolling: true,
    );
  } else {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: 100 * 1024 * 1024, // 100MB上限
    );
  }

  // プッシュ通知にグローバルキーを設定
  PushNotificationService.navigatorKey = navigatorKey;
  PushNotificationService.scaffoldMessengerKey = scaffoldMessengerKey;

  runApp(const SofvoApp());
}

class SofvoApp extends StatelessWidget {
  const SofvoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ja', 'JP')],
      locale: const Locale('ja', 'JP'),
      title: 'Sofvo',
      theme: AppTheme.lightTheme,
      themeMode: ThemeMode.light,
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
      builder: (context, child) {
        // デモモードのみ、画面全体にガイド/自動入力オーバーレイを重ねる
        if (DemoService.isDemoLaunch && child != null) {
          return DemoOverlay(child: child);
        }
        return child ?? const SizedBox.shrink();
      },
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  bool _navigatedToTournament = false;
  bool _processedReferral = false;
  bool _processedInviteCode = false;
  // 現在の認証ユーザー（StreamBuilderを使わず手動で管理）
  User? _currentUser;
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<Uri>? _appLinksSubscription;
  bool _isInitialLoading = true;
  bool _showSplash = true;
  bool _updateChecked = false;
  // デモモード起動（匿名サインイン + デモ大会 seed）
  bool _demoBootstrapped = false;
  bool _demoBootstrapping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUser = FirebaseAuth.instance.currentUser;
    // 永続化された認証状態がある場合は初期ロード完了
    if (_currentUser != null) {
      _isInitialLoading = false;
    }
    // ストリームで認証状態の変化を監視
    // FollowService の初期化
    if (_currentUser != null) {
      FollowService.instance.startListening(_currentUser!.uid);
    }
    _authSubscription = AuthService().authStateChanges.listen((user) {
      if (mounted && !suppressAuthStateChange) {
        setState(() {
          _currentUser = user;
          _isInitialLoading = false;
        });
      }
      // FollowService の認証同期
      if (user != null) {
        FollowService.instance.startListening(user.uid);
      } else {
        FollowService.instance.stopListening();
      }
    });
    if (!kIsWeb) {
      unawaited(_initAppLinks());
      unawaited(_checkDeferredReferral());
    }
  }

  /// App Links / Universal Links / カスタムスキーム（`sofvo://checkin/…`、https `…/app?checkin=…`、
  /// 友達紹介 `…/invite?ref=…` / `sofvo://invite?ref=…`）
  Future<void> _initAppLinks() async {
    try {
      final appLinks = AppLinks();
      final initial = await appLinks.getInitialLink();
      if (initial != null) {
        _applyDeepLink(initial);
      }
      _appLinksSubscription = appLinks.uriLinkStream.listen(
        _applyDeepLink,
        onError: (Object e) => debugPrint('app_links stream: $e'),
      );
    } catch (e) {
      debugPrint('app_links init: $e');
    }
  }

  /// 新規インストール時の紹介コード引き継ぎ（Android のみ）
  /// Android: Play Install Referrer API（MethodChannel）
  /// iOS: クリップボード経由は廃止。新規インストールは登録画面での招待コード入力で確実に成立させる。
  Future<void> _checkDeferredReferral() async {
    if (kIsWeb) return;
    // 既にディープリンクで ref が取得済みの場合はスキップ
    if (pendingReferrerUserId != null) return;

    try {
      if (Platform.isAndroid) {
        const channel = MethodChannel('com.sofvo.app/install_referrer');
        final referrer = await channel.invokeMethod<String?>('getInstallReferrer');
        if (referrer != null && referrer.isNotEmpty) {
          // referrer は "ref=USERID" 形式
          final uri = Uri(query: referrer);
          final ref = uri.queryParameters['ref'];
          if (ref != null && ref.isNotEmpty) {
            pendingReferrerUserId = ref;
            if (mounted) setState(() {});
          }
        }
      }
      // iOS のクリップボード経由の ref 取得は廃止。
      // Smart App Banner・ペースト権限・LINE内ブラウザ・上書きで取りこぼしが多く
      // 信頼できないため、新規インストール経路は「招待コード入力」に一本化した
      // （登録完了画面でコードを入力 → redeemInvite で確実に成立）。
    } catch (e) {
      debugPrint('deferred referral check: $e');
    }
  }

  void _applyDeepLink(Uri uri) {
    if (kIsWeb) return;
    var changed = false;

    // 友達紹介リンク（?ref=xxx）→ Web版と同じ相互フォロー処理に乗せる
    final ref = uri.queryParameters['ref'];
    if (ref != null && ref.isNotEmpty) {
      pendingReferrerUserId = ref;
      _processedReferral = false;
      changed = true;
    }

    // 招待コード（?code=XXXXXX）→ 登録後に redeemInvite で確定する
    final code = uri.queryParameters['code'];
    if (code != null && code.isNotEmpty) {
      pendingInviteCode = code;
      _processedInviteCode = false;
      changed = true;
    }

    final tid = parseCheckInTournamentIdFromDeepLinkUri(uri);
    if (tid != null && tid.isNotEmpty) {
      pendingCheckInTournamentId = tid;
      changed = true;
    } else {
      // 大会共有リンク（?t=xxx / /tournament/xxx）→ 大会詳細へ
      final shareTid = parseSofvoTournamentIdFromUri(uri);
      if (shareTid != null && shareTid.isNotEmpty) {
        pendingTournamentId = shareTid;
        _navigatedToTournament = false;
        changed = true;
      }
    }

    if (changed && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _appLinksSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // アプリがフォアグラウンドに戻ったタイミングで未読数を再計算し
    // iOS アプリアイコンのバッジを実際の未読数と同期させる。
    // （バックグラウンドで FCM が来てもバッジが更新されないケースや、
    //   iOS 側の applicationDidBecomeActive が触らないケースの保険）
    if (state == AppLifecycleState.resumed && _currentUser != null) {
      PushNotificationService.updateBadgeCount();
    }
    super.didChangeAppLifecycleState(state);
  }

  /// ログイン/登録成功時に即座に画面を切り替える
  void _onAuthSuccess() {
    if (mounted) {
      final user = FirebaseAuth.instance.currentUser;
      // currentUserがnullの場合は_currentUserを更新しない。
      // suppressAuthStateChange解除直後にcurrentUserがnullの場合、
      // stream listenerが正しいユーザーを後から設定するのを待つ。
      if (user != null) {
        setState(() {
          _currentUser = user;
        });
      }
      // ログインメッセージを表示
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: const Text('ログインしました'),
            backgroundColor: const Color(0xFF2E7D32),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            duration: const Duration(seconds: 2),
          ),
        );
      });
    }
  }


  /// 招待リンクの大会へ自動遷移
  Future<void> _navigateToInvitedTournament() async {
    if (_navigatedToTournament || pendingTournamentId == null) return;
    _navigatedToTournament = true;
    final tid = pendingTournamentId!;
    pendingTournamentId = null; // 一度だけ処理

    try {
      final doc = await FirebaseFirestore.instance.collection('tournaments').doc(tid).get();
      if (!doc.exists || !mounted) return;
      final data = doc.data()!;
      data['id'] = doc.id;

      // デモ大会は対戦表タブに直接着地させる（最初の操作＝対戦表生成を分かりやすく）
      final demoInitialTab = data['isDemo'] == true ? 'matches' : null;

      // 次フレームでpush（buildの最中にnavigateしないように）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => TournamentDetailScreen(
              tournament: data,
              initialTab: demoInitialTab,
            ),
          ),
        );
      });
    } catch (e) {
      debugPrint('招待リンクの大会遷移に失敗: $e');
    }
  }

  /// セルフチェックイン用の自動遷移
  Future<void> _handlePendingCheckIn() async {
    if (pendingCheckInTournamentId == null) return;
    final tid = pendingCheckInTournamentId!;
    pendingCheckInTournamentId = null;

    try {
      final doc = await FirebaseFirestore.instance.collection('tournaments').doc(tid).get();
      if (!doc.exists || !mounted) return;
      final data = doc.data()!;
      data['id'] = doc.id;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournament: data, autoCheckIn: true)),
        );
      });
    } catch (e) {
      debugPrint('セルフチェックイン遷移に失敗: $e');
    }
  }

  /// 既存ユーザーが紹介リンクを開いた場合の相互フォロー処理
  Future<void> _handlePendingReferral(String myUid) async {
    if (_processedReferral || pendingReferrerUserId == null) return;
    if (pendingReferrerUserId == myUid) {
      pendingReferrerUserId = null;
      return;
    }
    _processedReferral = true;
    final referrerUid = pendingReferrerUserId!;
    pendingReferrerUserId = null;

    try {
      final firestore = FirebaseFirestore.instance;
      final myRef = firestore.collection('users').doc(myUid);
      final referrerRef = firestore.collection('users').doc(referrerUid);

      // 紹介者が存在するか確認
      final referrerDoc = await referrerRef.get();
      if (!referrerDoc.exists) return;
      final referrerData = referrerDoc.data() ?? {};
      final referrerName = (referrerData['nickname'] ?? '名前なし').toString();

      // 既にフォロー済みかチェック
      final existingFollow = await myRef.collection('following').doc(referrerUid).get();
      if (existingFollow.exists) {
        // 既にフォロー済み → スナックバーで通知
        WidgetsBinding.instance.addPostFrameCallback((_) {
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text('$referrerNameさんは既にフォロー済みです'),
              backgroundColor: const Color(0xFF1565C0),
            ),
          );
        });
        return;
      }

      // 自分の情報を取得
      final myDoc = await myRef.get();
      final myData = myDoc.data() ?? {};
      final myNickname = (myData['nickname'] ?? '名前なし').toString();

      // 新規ユーザー → 紹介者 をフォロー
      await myRef.collection('following').doc(referrerUid).set({
        'nickname': referrerName,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await referrerRef.collection('followers').doc(myUid).set({
        'createdAt': FieldValue.serverTimestamp(),
      });

      // 紹介者 → 新規ユーザー をフォロー（既にフォロー済みでなければ）
      // カウント更新はCloud Functionが自動処理
      final reverseFollow = await referrerRef.collection('following').doc(myUid).get();
      if (!reverseFollow.exists) {
        await referrerRef.collection('following').doc(myUid).set({
          'nickname': myNickname,
          'createdAt': FieldValue.serverTimestamp(),
        });
        await myRef.collection('followers').doc(referrerUid).set({
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      // 紹介者に通知
      NotificationService.sendFollowNotification(
        targetUserId: referrerUid,
        senderId: myUid,
        senderName: myNickname,
        senderAvatar: myData['avatarUrl'] ?? '',
      );

      // スナックバーで通知
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('$referrerNameさんと友達になりました！'),
            backgroundColor: const Color(0xFF2E7D32),
          ),
        );
      });
    } catch (e) {
      debugPrint('紹介リンクの相互フォロー処理に失敗: $e');
    }
  }

  /// 招待コード（?code=）の引き換え。redeemInvite が相互フォロー＋チーム参加を確定し、
  /// 大会招待なら該当大会へ誘導する。新規ユーザーは ProfileSetupScreen 側でも入力できる
  /// ため、そちらで処理済みなら pendingInviteCode は null になっている。
  Future<void> _handlePendingInviteCode() async {
    if (_processedInviteCode || pendingInviteCode == null) return;
    _processedInviteCode = true;
    final code = pendingInviteCode!;
    pendingInviteCode = null;

    try {
      final result = await InviteService.redeemInvite(code);
      if (!mounted) return;

      final referrerName = result['referrerName'] as String?;
      final teamName = result['teamName'] as String?;
      final tournamentId = result['tournamentId'] as String?;
      final requestedTeam = result['requestedTeam'] == true;
      final joinedTeam = result['joinedTeam'] == true;

      final messages = <String>[];
      if (referrerName != null && referrerName.isNotEmpty) {
        messages.add('$referrerNameさんと友達になりました');
      }
      if (teamName != null && teamName.isNotEmpty) {
        if (requestedTeam) {
          messages.add('チーム「$teamName」に参加リクエストを送りました（承認待ち）');
        } else if (joinedTeam) {
          messages.add('チーム「$teamName」に参加しました');
        }
      }
      if (messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text('${messages.join(' / ')}！'),
              backgroundColor: const Color(0xFF2E7D32),
            ),
          );
        });
      }

      // 大会招待なら該当大会へ誘導
      if (tournamentId != null && tournamentId.isNotEmpty) {
        pendingTournamentId = tournamentId;
        _navigatedToTournament = false;
        _navigateToInvitedTournament();
      }
    } catch (e) {
      debugPrint('招待コードの引き換えに失敗: $e');
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          scaffoldMessengerKey.currentState?.showSnackBar(
            const SnackBar(
              content: Text('招待コードの引き換えに失敗しました'),
              backgroundColor: Color(0xFFC62828),
            ),
          );
        });
      }
    }
  }

  /// アプリ更新チェック
  Future<void> _checkForUpdate() async {
    if (_updateChecked) return;
    _updateChecked = true;

    final result = await UpdateCheckService.check();
    if (result.status == UpdateStatus.none || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showUpdateDialog(result);
    });
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    final isForce = result.status == UpdateStatus.force;

    showDialog(
      context: context,
      barrierDismissible: !isForce,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (ctx) => PopScope(
        canPop: !isForce,
        child: Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B3A5C).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.system_update, size: 32, color: Color(0xFF1B3A5C)),
                ),
                const SizedBox(height: 20),
                Text(
                  isForce ? 'アップデートが必要です' : '新しいバージョンがあります',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A)),
                ),
                const SizedBox(height: 12),
                Text(
                  result.updateMessage ??
                      (isForce
                          ? 'アプリを最新バージョン（${result.latestVersion}）にアップデートしてください。'
                          : '最新バージョン（${result.latestVersion}）が利用可能です。\nアップデートしますか？'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Color(0xFF6B6B6B), height: 1.6),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => _openStore(),
                    child: const Text('アップデート'),
                  ),
                ),
                if (!isForce) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('あとで', style: TextStyle(color: Color(0xFF6B6B6B))),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openStore() {
    final uri = Uri.parse(
      Theme.of(context).platform == TargetPlatform.iOS
          ? 'https://apps.apple.com/app/sofvo/id6760548582'
          : 'https://play.google.com/store/apps/details?id=com.sofvo.app',
    );
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    // デモモード: 匿名サインイン + デモ大会 seed が完了するまでローディング表示。
    // 完了後は pendingTournamentId が設定され、通常フロー（プロフィール設定は
    // デモユーザードキュメントで自動スキップ）→ デモ大会詳細へ自動遷移する。
    if (DemoService.isDemoLaunch && !_demoBootstrapped) {
      if (!_demoBootstrapping) {
        _demoBootstrapping = true;
        DemoService.startDemo().then((tid) {
          if (!mounted) return;
          pendingTournamentId = tid;
          setState(() => _demoBootstrapped = true);
        }).catchError((Object e) {
          debugPrint('デモ起動に失敗: $e');
          if (mounted) setState(() => _demoBootstrapped = true);
        });
      }
      return const _DemoLoadingScreen();
    }

    // 初期ロード中（ストリームの最初のイベント待ち）
    if (_isInitialLoading && _currentUser == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF1B3A5C),
        body: SizedBox.shrink(),
      );
    }

    // アプリ起動時のスプラッシュ画面（ログイン済みネイティブアプリのみ）
    if (_showSplash && !kIsWeb && _currentUser != null) {
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _showSplash = false);
      });
      return const _SplashScreen();
    }

    // 未ログイン
    if (_currentUser == null) {
      _navigatedToTournament = false;
      _processedReferral = false;
      _processedInviteCode = false;
      if (pendingReferrerUserId != null) {
        return RegisterScreen(
          onAuthSuccess: _onAuthSuccess,
          onSwitchToLogin: () {
            setState(() {
              pendingReferrerUserId = null;
            });
          },
        );
      }
      return LoginScreen(onAuthSuccess: _onAuthSuccess);
    }

    // ログイン済み → プロフィール確認（リアルタイム監視）
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .snapshots(),
      builder: (context, userSnapshot) {
        if (userSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFFF5F5F8),
            body: SizedBox.shrink(),
          );
        }
        if (!userSnapshot.hasData ||
            !userSnapshot.data!.exists ||
            userSnapshot.data!.get('profileCompleted') != true) {
          // 新規ユーザー: プロフィール未設定 → 直接プロフィール設定へ
          return const ProfileSetupScreen();
        }
        // 通知系は初回描画後に遅延実行（起動速度を優先）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          BookmarkNotificationService.checkAndNotify(_currentUser!.uid);
          PushNotificationService.initialize();
          // 既存ユーザーも公式アカウントを一度だけ自動フォロー（ホームを空にしない）
          FollowService.instance.ensureOfficialFollow(myUid: _currentUser!.uid);
        });

        // アプリ更新チェック
        _checkForUpdate();

        // 招待リンクがあれば大会詳細へ自動遷移
        if (pendingTournamentId != null) {
          _navigateToInvitedTournament();
        }
        // セルフチェックインリンク
        if (pendingCheckInTournamentId != null) {
          _handlePendingCheckIn();
        }
        // 紹介リンク（既存ユーザー向け）
        if (pendingReferrerUserId != null) {
          _handlePendingReferral(_currentUser!.uid);
        }
        // 招待コード（友達紹介・チーム招待・大会招待の共通コード）
        if (pendingInviteCode != null) {
          _handlePendingInviteCode();
        }

        return const MainTabScreen();
      },
    );
  }
}

/// デモ準備中のローディング画面
class _DemoLoadingScreen extends StatelessWidget {
  const _DemoLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B3A5C),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(
              text: const TextSpan(
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
                children: [
                  TextSpan(text: 'Sof', style: TextStyle(color: Colors.white)),
                  TextSpan(text: 'vo', style: TextStyle(color: Color(0xFFBFA258))),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'デモを準備中…',
              style: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 1),
            ),
          ],
        ),
      ),
    );
  }
}

/// アプリ起動時のスプラッシュ画面
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B3A5C),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(
              text: const TextSpan(
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
                children: [
                  TextSpan(
                    text: 'Sof',
                    style: TextStyle(color: Colors.white),
                  ),
                  TextSpan(
                    text: 'vo',
                    style: TextStyle(color: Color(0xFFBFA258)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'ソフトバレーを、もっと楽しく。',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
