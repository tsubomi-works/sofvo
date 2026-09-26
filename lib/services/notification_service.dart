import 'package:cloud_firestore/cloud_firestore.dart';

class NotificationService {
  static final _firestore = FirebaseFirestore.instance;

  /// 通知（ベルアイコン）に表示する対人アクション系タイプ
  static const actionTypes = ['like', 'comment', 'follow', 'team_join', 'team_leave', 'team_join_request', 'team_join_approved', 'entry_invite', 'entry_confirmed', 'entry_declined', 'entry_canceled'];

  /// お知らせタブに表示する大会・システム系タイプ
  /// （entry_invite はベルアイコンにも出るが、削除しても見失わないよう
  /// 「あなた宛」タブにも残す）
  static const announcementTypes = [
    'tournament_announcement',
    'tournament_end',
    'waitlist_available',
    'points_earned',
    'tournament_created',
    'deadline_approaching',
    'slots_low',
    'official',
    'entry_invite',
  ];

  static Future<void> sendLikeNotification({
    required String postOwnerId,
    required String senderId,
    required String senderName,
    String senderAvatar = '',
    required String postId,
  }) async {
    if (postOwnerId == senderId) return;
    await _firestore
        .collection('users')
        .doc(postOwnerId)
        .collection('notifications')
        .add({
      'type': 'like',
      'senderId': senderId,
      'senderName': senderName,
      'senderAvatar': senderAvatar,
      'message': 'があなたの投稿にいいねしました',
      'postId': postId,
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> sendCommentNotification({
    required String postOwnerId,
    required String senderId,
    required String senderName,
    String senderAvatar = '',
    required String postId,
    required String commentText,
  }) async {
    if (postOwnerId == senderId) return;
    final preview = commentText.length > 30
        ? '${commentText.substring(0, 30)}...'
        : commentText;
    await _firestore
        .collection('users')
        .doc(postOwnerId)
        .collection('notifications')
        .add({
      'type': 'comment',
      'senderId': senderId,
      'senderName': senderName,
      'senderAvatar': senderAvatar,
      'message': 'がコメントしました: $preview',
      'postId': postId,
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> sendFollowNotification({
    required String targetUserId,
    required String senderId,
    required String senderName,
    String senderAvatar = '',
  }) async {
    await _firestore
        .collection('users')
        .doc(targetUserId)
        .collection('notifications')
        .add({
      'type': 'follow',
      'senderId': senderId,
      'senderName': senderName,
      'senderAvatar': senderAvatar,
      'message': 'があなたをフォローしました',
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// 大会終了時に全参加者へ通知 + タイムラインに自動投稿
  static Future<void> sendTournamentEndNotification({
    required String tournamentId,
    required String tournamentName,
    required String tournamentDate,
    required String organizerId,
    required String organizerName,
  }) async {
    // 参加チーム一覧を取得
    final entries = await _firestore
        .collection('tournaments').doc(tournamentId)
        .collection('entries').get();

    // 全参加者のUIDを収集（重複除外）
    final participantUids = <String>{};
    for (final doc in entries.docs) {
      final data = doc.data();
      final memberUids = data['memberUids'];
      if (memberUids is List) {
        for (final uid in memberUids) {
          if (uid is String && uid.isNotEmpty) participantUids.add(uid);
        }
      }
      final enteredBy = data['enteredBy'] as String?;
      if (enteredBy != null && enteredBy.isNotEmpty) participantUids.add(enteredBy);
    }

    // entriesからチームID→チーム名の変換マップを構築
    final teamIdToName = <String, String>{};
    for (final doc in entries.docs) {
      final data = doc.data();
      final teamId = data['teamId'] as String? ?? doc.id;
      final teamName = data['teamName'] as String? ?? '';
      if (teamId.isNotEmpty && teamName.isNotEmpty) {
        teamIdToName[teamId] = teamName;
      }
      // doc IDでもマッピング（teamId != doc.idの場合に備えて）
      if (doc.id != teamId && teamName.isNotEmpty) {
        teamIdToName[doc.id] = teamName;
      }
    }

    // 優勝チーム情報を取得（bracketの決勝から）
    String winnerTeamName = '';
    try {
      final brackets = await _firestore
          .collection('tournaments').doc(tournamentId)
          .collection('brackets').get();
      // bracketNumberが小さい順（上位リーグ優先）
      final sortedBrackets = brackets.docs.toList()
        ..sort((a, b) {
          final aNum = (a.data()['bracketNumber'] as int?) ?? 99;
          final bNum = (b.data()['bracketNumber'] as int?) ?? 99;
          return aNum.compareTo(bNum);
        });
      for (final bracketDoc in sortedBrackets) {
        if (winnerTeamName.isNotEmpty) break;
        final matches = await bracketDoc.reference
            .collection('matches').where('status', isEqualTo: 'completed').get();
        // 決勝マッチを探す（final, final_1st のいずれか）
        final finalMatch = matches.docs.where((m) {
          final round = (m.data())['round'] as String? ?? '';
          return round == 'final' || round == 'final_1st';
        }).firstOrNull;
        if (finalMatch != null) {
          final matchData = finalMatch.data();
          final result = matchData['result'] as Map<String, dynamic>?;
          if (result != null && result['winner'] != null) {
            final winnerId = result['winner'] as String? ?? '';
            // winnerIdからチーム名を解決（entriesマップ優先）
            if (teamIdToName.containsKey(winnerId)) {
              winnerTeamName = teamIdToName[winnerId]!;
            } else if (winnerId == matchData['teamAId']) {
              winnerTeamName = matchData['teamAName'] as String? ?? '';
            } else if (winnerId == matchData['teamBId']) {
              winnerTeamName = matchData['teamBName'] as String? ?? '';
            }
            // チーム名がまだIDの場合、matchのteamName→entriesで再解決
            if (winnerTeamName.isNotEmpty && teamIdToName.containsKey(winnerTeamName)) {
              winnerTeamName = teamIdToName[winnerTeamName]!;
            }
          }
        }
      }
    } catch (e) {
      // 優勝チーム取得失敗時は汎用メッセージにフォールバック
    }

    final resultMessage = winnerTeamName.isNotEmpty
        ? '「$tournamentName」が終了しました！優勝: $winnerTeamName'
        : '「$tournamentName」が終了しました！結果を確認しましょう';

    // 主催者のアバターを取得
    final userDoc = await _firestore.collection('users').doc(organizerId).get();
    final avatarUrl = (userDoc.data()?['avatarUrl'] ?? '') as String;

    // 全参加者に通知を送信
    final batch = _firestore.batch();
    for (final uid in participantUids) {
      final notifRef = _firestore
          .collection('users').doc(uid)
          .collection('notifications').doc();
      batch.set(notifRef, {
        'type': 'tournament_end',
        'senderId': organizerId,
        'senderName': organizerName,
        'senderAvatar': avatarUrl,
        'message': resultMessage,
        'tournamentId': tournamentId,
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();

    // タイムラインに自動投稿（主催者名義）
    final postText = winnerTeamName.isNotEmpty
        ? '🏆「$tournamentName」($tournamentDate) が終了しました！\n\n優勝: $winnerTeamName\n\nご参加ありがとうございました！'
        : '「$tournamentName」($tournamentDate) が終了しました！\n\nご参加ありがとうございました！';

    await _firestore.collection('posts').add({
      'userId': organizerId,
      'userNickname': organizerName,
      'userAvatarUrl': avatarUrl,
      'text': postText,
      'images': <String>[],
      'likesCount': 0,
      'commentsCount': 0,
      'autoGenerated': true,
      'tournamentId': tournamentId,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// 大会お知らせ通知（主催者→全参加者）
  static Future<void> sendTournamentAnnouncement({
    required String tournamentId,
    required String tournamentName,
    required String senderId,
    required String senderName,
    required String message,
  }) async {
    final entries = await _firestore
        .collection('tournaments').doc(tournamentId)
        .collection('entries').get();

    final participantUids = <String>{};
    for (final doc in entries.docs) {
      final data = doc.data();
      final memberUids = data['memberUids'];
      if (memberUids is List) {
        for (final uid in memberUids) {
          if (uid is String && uid.isNotEmpty) participantUids.add(uid);
        }
      }
      final enteredBy = data['enteredBy'] as String?;
      if (enteredBy != null && enteredBy.isNotEmpty) participantUids.add(enteredBy);
    }

    // 送信者のアバターを取得
    final senderDoc = await _firestore.collection('users').doc(senderId).get();
    final senderAvatar = (senderDoc.data()?['avatarUrl'] ?? '') as String;

    final preview = message.length > 40 ? '${message.substring(0, 40)}...' : message;
    final batch = _firestore.batch();
    for (final uid in participantUids) {
      if (uid == senderId) continue;
      final notifRef = _firestore
          .collection('users').doc(uid)
          .collection('notifications').doc();
      batch.set(notifRef, {
        'type': 'tournament_announcement',
        'senderId': senderId,
        'senderName': senderName,
        'senderAvatar': senderAvatar,
        'message': '[$tournamentName] $preview',
        'tournamentId': tournamentId,
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  /// キャンセル待ち通知（空きが出た場合）
  static Future<void> sendWaitlistNotification({
    required String targetUserId,
    required String tournamentId,
    required String tournamentName,
  }) async {
    await _firestore
        .collection('users')
        .doc(targetUserId)
        .collection('notifications')
        .add({
      'type': 'waitlist_available',
      'senderId': 'system',
      'senderName': 'システム',
      'senderAvatar': '',
      'message': '「$tournamentName」に空きが出ました！エントリーしましょう',
      'tournamentId': tournamentId,
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// チームメンバー加入通知
  static Future<void> sendTeamJoinNotification({
    required String teamId,
    required String teamName,
    required String joinedUserId,
    required String joinedUserName,
    required List<String> memberUids,
  }) async {
    final batch = _firestore.batch();
    for (final uid in memberUids) {
      if (uid == joinedUserId) continue;
      final notifRef = _firestore
          .collection('users').doc(uid)
          .collection('notifications').doc();
      batch.set(notifRef, {
        'type': 'team_join',
        'senderId': joinedUserId,
        'senderName': joinedUserName,
        'senderAvatar': '',
        'message': 'が「$teamName」に参加しました',
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  /// チームメンバー退出通知
  static Future<void> sendTeamLeaveNotification({
    required String teamId,
    required String teamName,
    required String leftUserId,
    required String leftUserName,
    required List<String> memberUids,
  }) async {
    final batch = _firestore.batch();
    for (final uid in memberUids) {
      if (uid == leftUserId) continue;
      final notifRef = _firestore
          .collection('users').doc(uid)
          .collection('notifications').doc();
      batch.set(notifRef, {
        'type': 'team_leave',
        'senderId': leftUserId,
        'senderName': leftUserName,
        'senderAvatar': '',
        'message': 'が「$teamName」から脱退しました',
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  /// 通知（ベルアイコン）の未読数 — 対人アクションのみ
  static Stream<int> unreadCountStream(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .where('read', isEqualTo: false)
        .where('type', whereIn: actionTypes)
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  /// お知らせタブの未読数 — 大会・システム系のみ
  static Stream<int> unreadAnnouncementCountStream(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .where('read', isEqualTo: false)
        .where('type', whereIn: announcementTypes)
        .snapshots()
        .map((snap) => snap.docs.length);
  }
}
