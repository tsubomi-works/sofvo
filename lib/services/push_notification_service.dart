import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../screens/chat/chat_screen.dart';
import '../screens/profile/user_profile_screen.dart';
import '../screens/tournament/tournament_detail_screen.dart';

class PushNotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final _firestore = FirebaseFirestore.instance;

  /// iOS ネイティブバッジ操作用 MethodChannel
  static const MethodChannel _badgeChannel = MethodChannel('com.sofvo.app/badge');

  /// iOS アプリアイコンのバッジを指定値に設定（iOS のみ）
  static Future<void> _setNativeBadge(int count) async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      if (count <= 0) {
        await _badgeChannel.invokeMethod('clearBadge');
      } else {
        await _badgeChannel.invokeMethod('setBadge', {'count': count});
      }
    } catch (e) {
      debugPrint('Failed to set native badge: $e');
    }
  }

  /// グローバルナビゲーターキー（main.dartで設定）
  static GlobalKey<NavigatorState>? navigatorKey;

  /// グローバルScaffoldMessengerキー
  static GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  /// 重複初期化を防止
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        // トークン保存（失敗しても他の初期化は続行）
        _saveTokenWithRetry();

        // 全ユーザー向けお知らせ通知トピックを購読
        await _messaging.subscribeToTopic('all_users');

        // OS別のお知らせ配信用トピックを購読（iOS/Android のみ）
        if (!kIsWeb) {
          if (defaultTargetPlatform == TargetPlatform.iOS) {
            await _messaging.subscribeToTopic('ios_users');
          } else if (defaultTargetPlatform == TargetPlatform.android) {
            await _messaging.subscribeToTopic('android_users');
          }
        }

        // iOS: フォアグラウンド表示オプション
        await _messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );

        _messaging.onTokenRefresh.listen((token) => _saveTokenToFirestore(token));

        // フォアグラウンドメッセージ → バナー表示
        FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

        // バックグラウンドからのタップ → 画面遷移
        FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageTap);

        // アプリ終了状態からの起動
        final initialMessage = await _messaging.getInitialMessage();
        if (initialMessage != null) {
          _handleMessageTap(initialMessage);
        }

        _initialized = true;

        // 起動時に iOS バッジを実際の未読数と同期する
        // （バックグラウンドで届いたプッシュで進んだバッジ値や、
        //   逆に未読が残っているのに 0 になっているケースを補正）
        await updateBadgeCount();
      }
    } catch (e) {
      debugPrint('Push notification initialization failed: $e');
    }
  }

  /// Web Push用VAPIDキー（Firebase Console → Cloud Messaging → Web構成で生成）
  static String? vapidKey;

  /// トークン保存（リトライ付き）
  /// iOS ではAPNsトークンが届くまで getToken() が null を返すため、
  /// リトライで確実にトークンを取得・保存する
  static Future<void> _saveTokenWithRetry() async {
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        // iOS: APNsトークンが届くまで待機
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          final apnsToken = await _messaging.getAPNSToken();
          if (apnsToken == null) {
            debugPrint('FCM: APNs token not ready, retry ${attempt + 1}/5');
            await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
            continue;
          }
        }

        final token = kIsWeb
            ? await _messaging.getToken(vapidKey: vapidKey)
            : await _messaging.getToken();

        if (token == null) {
          debugPrint('FCM: token is null, retry ${attempt + 1}/5');
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
          continue;
        }

        await _saveTokenToFirestore(token);
        debugPrint('FCM: token saved successfully');
        return;
      } catch (e) {
        debugPrint('FCM: save token failed (attempt ${attempt + 1}/5): $e');
        if (attempt < 4) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
    }
    debugPrint('FCM: failed to save token after 5 attempts');
  }

  static Future<void> _saveTokenToFirestore(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      debugPrint('FCM: uid is null, cannot save token');
      return;
    }

    // 複数デバイス対応: fcmTokens配列にトークンを追加（重複防止）
    // 旧フィールド(fcmToken)も互換性のため更新
    await _firestore
        .collection('users').doc(uid)
        .collection('private').doc('info')
        .set({
      'fcmToken': token,
      'fcmTokens': FieldValue.arrayUnion([token]),
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    debugPrint('FCM: token written to Firestore for uid=$uid');
  }

  /// フォアグラウンドでの通知 → SnackBarバナーで表示
  static void _handleForegroundMessage(RemoteMessage message) {
    // フォアグラウンド受信時、iOS は自動でバッジを更新しないため
    // Firestore の最新状態から再計算してネイティブバッジを同期する。
    // （これを呼ばないと「アプリ内では未読3、iOSバッジは1」のような
    //   ズレが発生する）
    updateBadgeCount();

    final notification = message.notification;
    if (notification == null) return;

    final messengerState = scaffoldMessengerKey?.currentState;
    if (messengerState != null) {
      messengerState.showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (notification.title != null)
                Text(notification.title!,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              if (notification.body != null)
                Text(notification.body!,
                    style: const TextStyle(fontSize: 13, color: Colors.white70)),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          backgroundColor: const Color(0xFF1B3A5C),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '見る',
            textColor: const Color(0xFFC4A962),
            onPressed: () => _navigateByData(message.data),
          ),
        ),
      );
    }
  }

  /// 通知タップ → 画面遷移
  static void _handleMessageTap(RemoteMessage message) {
    _navigateByData(message.data);
  }

  /// データに基づいて遷移
  static void _navigateByData(Map<String, dynamic> data) {
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return;

    final type = data['type'] as String?;
    final targetId = data['targetId'] as String?;

    if (type == null) return;

    switch (type) {
      case 'chat':
        if (targetId != null) _navigateToChat(navigator, targetId);
        break;
      case 'follow':
        if (targetId != null) {
          navigator.push(MaterialPageRoute(
            builder: (_) => UserProfileScreen(userId: targetId),
          ));
        }
        break;
      case 'like':
      case 'comment':
        // 投稿への遷移（将来実装）
        break;
      case 'tournament_announcement':
      case 'tournament_end':
      case 'waitlist_available':
      case 'deadline_approaching':
      case 'tournament_created':
      case 'slots_low':
      // 大会エントリーの招待・成立・辞退・取り消し → 大会詳細（招待カードで承認/辞退できる）
      case 'entry_invite':
      case 'entry_confirmed':
      case 'entry_declined':
      case 'entry_canceled':
        final tournamentId = data['tournamentId'] as String? ?? targetId;
        if (tournamentId != null) _navigateToTournament(navigator, tournamentId);
        break;
      case 'team_join':
      case 'team_leave':
        // チーム画面への遷移（将来実装）
        break;
      case 'notice':
        // リンク付きのお知らせはブラウザで開く
        final link = data['link'] as String?;
        if (link != null && link.isNotEmpty) {
          final uri = Uri.tryParse(link);
          if (uri != null) {
            launchUrl(uri, mode: LaunchMode.externalApplication).catchError((e) {
              debugPrint('Failed to open notice link: $e');
              return false;
            });
          }
        }
        break;
      case 'official':
        // 公式通知はタップ時に特別遷移なし（通知一覧を開く）
        break;
      default:
        debugPrint('Unknown notification type: $type');
    }
  }

  /// 大会詳細に遷移
  static Future<void> _navigateToTournament(NavigatorState navigator, String tournamentId) async {
    try {
      final doc = await _firestore.collection('tournaments').doc(tournamentId).get();
      if (!doc.exists) return;
      final data = doc.data()!;
      data['id'] = doc.id;
      navigator.push(MaterialPageRoute(
        builder: (_) => TournamentDetailScreen(tournament: data),
      ));
    } catch (e) {
      debugPrint('Failed to navigate to tournament: $e');
    }
  }

  /// チャット画面に遷移（chatIdからメタ情報を取得）
  static Future<void> _navigateToChat(NavigatorState navigator, String chatId) async {
    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) return;

      final chatData = chatDoc.data() ?? {};
      final chatType = (chatData['type'] as String?) ?? 'dm';
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

      String chatTitle;
      String? otherUserId;

      if (chatType == 'dm') {
        final memberNames = chatData['memberNames'] as Map<String, dynamic>? ?? {};
        final otherEntry = memberNames.entries.firstWhere(
          (e) => e.key != uid,
          orElse: () => const MapEntry('', 'ユーザー'),
        );
        chatTitle = otherEntry.value as String;
        otherUserId = otherEntry.key.isNotEmpty ? otherEntry.key : null;
      } else {
        chatTitle = (chatData['name'] as String?) ?? 'グループ';
      }

      navigator.push(MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatId: chatId,
          chatTitle: chatTitle,
          chatType: chatType,
          otherUserId: otherUserId,
        ),
      ));
    } catch (e) {
      debugPrint('Failed to navigate to chat: $e');
    }
  }

  /// 未読数を再計算してアプリアイコンバッジとFirestoreを更新
  static Future<void> updateBadgeCount() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      int totalUnread = 0;

      // チャット未読数
      final chats = await _firestore
          .collection('chats')
          .where('members', arrayContains: uid)
          .get();
      for (final doc in chats.docs) {
        final data = doc.data();
        final unreadMap = data['unreadCount'] as Map<String, dynamic>?;
        final cnt = unreadMap?[uid];
        if (cnt is num && cnt > 0) totalUnread += cnt.toInt();
      }

      // 通知未読数
      final notifications = await _firestore
          .collection('users').doc(uid)
          .collection('notifications')
          .where('read', isEqualTo: false)
          .count()
          .get();
      totalUnread += notifications.count ?? 0;

      // Firestore の badgeCount を更新
      await _firestore
          .collection('users').doc(uid)
          .collection('private').doc('info')
          .set({'badgeCount': totalUnread}, SetOptions(merge: true));

      // iOS アプリアイコンのバッジも即時反映
      await _setNativeBadge(totalUnread);
    } catch (e) {
      debugPrint('Failed to update badge count: $e');
    }
  }

  static Future<void> removeToken() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // 現在のデバイスのトークンのみ削除（他デバイスには影響しない）
    try {
      final token = await _messaging.getToken();
      final updates = <String, dynamic>{
        'badgeCount': 0,
      };
      if (token != null) {
        updates['fcmTokens'] = FieldValue.arrayRemove([token]);
      }
      // fcmToken(単一)は最後に登録したデバイスのものなので削除
      updates['fcmToken'] = FieldValue.delete();
      await _firestore
          .collection('users').doc(uid)
          .collection('private').doc('info')
          .set(updates, SetOptions(merge: true));
    } catch (_) {
      // フォールバック: 全トークン削除
      await _firestore
          .collection('users').doc(uid)
          .collection('private').doc('info')
          .set({
        'fcmToken': FieldValue.delete(),
        'fcmTokens': FieldValue.delete(),
        'badgeCount': 0,
      }, SetOptions(merge: true));
    }
  }
}
