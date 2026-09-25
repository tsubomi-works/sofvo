import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../config/app_theme.dart';
import '../../services/notification_service.dart';
import '../../services/push_notification_service.dart';
import '../profile/user_profile_screen.dart';
import '../team/team_management_screen.dart';

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  // アカウント切り替え後も必ず最新のログインユーザーを参照する（State生成時の
  // 1回だけ評価される field だと、切り替え前のuidを掴んだままになる恐れがある）
  User? get _currentUser => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _markAllAsRead();
  }

  Future<void> _markAllAsRead() async {
    if (_currentUser == null) return;
    final unread = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .collection('notifications')
        .where('read', isEqualTo: false)
        .where('type', whereIn: NotificationService.actionTypes)
        .get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in unread.docs) {
      batch.update(doc.reference, {'read': true});
    }
    await batch.commit();
    PushNotificationService.updateBadgeCount();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUser == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('通知')),
        body: const Center(child: Text('ログインしてください')),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('通知'),
        actions: [
          TextButton(
            onPressed: _deleteAllNotifications,
            child: const Text('すべて削除',
                style: TextStyle(fontSize: 13, color: AppTheme.error)),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUser!.uid)
            .collection('notifications')
            .where('type', whereIn: NotificationService.actionTypes)
            .orderBy('createdAt', descending: true)
            .limit(50)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('読み込みに失敗しました', style: TextStyle(color: AppTheme.textSecondary)));
          }
          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(
                    color: AppTheme.primaryColor));
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_none,
                      size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  Text('通知はありません',
                      style: TextStyle(
                          fontSize: 16, color: AppTheme.textSecondary)),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + MediaQuery.of(context).padding.bottom),
            itemCount: docs.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: Colors.grey[100]),
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              return _buildNotificationItem(data, docs[index].id);
            },
          );
        },
      ),
    );
  }

  Future<void> _onNotificationTap(Map<String, dynamic> data) async {
    final type = data['type'] ?? '';
    final senderId = data['senderId'] as String?;

    // 大会エントリーの招待 → 承認 / 辞退ダイアログ
    if (type == 'entry_invite') {
      await _showEntryInviteDialog(data);
      return;
    }

    // フォロー通知 → ユーザープロフィールへ遷移
    if (type == 'follow' && senderId != null && senderId.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UserProfileScreen(userId: senderId),
        ),
      );
      return;
    }

    // チーム参加リクエスト → チーム管理画面へ（承認/却下はそこで行う）
    if (type == 'team_join_request') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const TeamManagementScreen(),
        ),
      );
      return;
    }
  }

  Future<void> _showEntryInviteDialog(Map<String, dynamic> data) async {
    final tournamentId = (data['tournamentId'] ?? '').toString();
    final draftId = (data['draftId'] ?? '').toString();
    final teamName = (data['teamName'] ?? '').toString();
    final tournamentName = (data['tournamentName'] ?? '').toString();
    final senderName = (data['senderName'] ?? '').toString();
    if (tournamentId.isEmpty || draftId.isEmpty) return;

    final approve = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('大会エントリーへの招待', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$senderName さんから、大会「$tournamentName」のチーム「$teamName」に招待されています。'),
            const SizedBox(height: 10),
            const Text('参加を承認しますか？ 全員の承認でエントリーが成立します。',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            const Text('エントリーが成立すると、大会の告知が届くように主催者を自動でフォローします。',
                style: TextStyle(fontSize: 12, color: AppTheme.textHint)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('辞退する', style: TextStyle(color: AppTheme.error))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('承認する', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (approve == null) return;

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('respondEntryInvite');
      final res = await callable.call({'tournamentId': tournamentId, 'draftId': draftId, 'approve': approve});
      final finalized = (res.data as Map)['finalized'] == true;
      final memberAdd = (res.data as Map)['memberAdd'] == true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(!approve
            ? '招待を辞退しました'
            : memberAdd
                ? 'チームに参加しました！'
                : finalized
                    ? 'エントリーが成立しました！'
                    : '承認しました。他のメンバーの承認を待っています'),
        backgroundColor: approve ? AppTheme.success : AppTheme.textSecondary,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('処理に失敗しました。招待が取り消された可能性があります'), backgroundColor: AppTheme.error));
    }
  }

  Widget _buildNotificationItem(Map<String, dynamic> data, String docId) {
    final type = data['type'] ?? '';
    final senderId = data['senderId'] as String? ?? '';
    final senderName = data['senderName'] ?? '不明';
    final senderAvatar = data['senderAvatar'] ?? '';
    final message = data['message'] ?? '';
    final bool isRead = data['read'] ?? true;
    final createdAt = data['createdAt'] as Timestamp?;

    IconData icon;
    Color iconColor;

    switch (type) {
      case 'like':
        icon = Icons.favorite;
        iconColor = Colors.red;
        break;
      case 'comment':
        icon = Icons.chat_bubble;
        iconColor = AppTheme.primaryColor;
        break;
      case 'follow':
        icon = Icons.person_add;
        iconColor = AppTheme.accentColor;
        break;
      case 'entry_invite':
        icon = Icons.how_to_reg;
        iconColor = AppTheme.primaryColor;
        break;
      case 'entry_confirmed':
        icon = Icons.check_circle;
        iconColor = AppTheme.success;
        break;
      case 'entry_canceled':
        icon = Icons.event_busy;
        iconColor = AppTheme.textSecondary;
        break;
      case 'entry_declined':
      case 'team_join_request':
        icon = Icons.group_add;
        iconColor = AppTheme.accentColor;
        break;
      case 'team_join_approved':
        icon = Icons.verified;
        iconColor = AppTheme.success;
        break;
      default:
        icon = Icons.notifications;
        iconColor = AppTheme.textSecondary;
    }

    return Dismissible(
      key: Key(docId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppTheme.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) {
        FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUser!.uid)
            .collection('notifications')
            .doc(docId)
            .delete();
      },
      child: Container(
        color: isRead
            ? Colors.transparent
            : AppTheme.primaryColor.withValues(alpha: 0.04),
        child: ListTile(
          onTap: () => _onNotificationTap(data),
          leading: Stack(
            children: [
              senderAvatar.isNotEmpty
                  ? CircleAvatar(
                      radius: 22,
                      backgroundImage: NetworkImage(senderAvatar),
                    )
                  : CircleAvatar(
                      radius: 22,
                      backgroundColor:
                          AppTheme.primaryColor.withValues(alpha: 0.12),
                      child: Text(
                        senderName.isNotEmpty ? senderName[0] : '?',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryColor),
                      ),
                    ),
              Positioned(
                bottom: -2,
                right: -2,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 14, color: iconColor),
                ),
              ),
            ],
          ),
          title: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                        fontSize: 14, color: AppTheme.textPrimary),
                    children: [
                      TextSpan(
                        text: senderName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      TextSpan(text: ' $message'),
                    ],
                  ),
                ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _formatTime(createdAt),
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
      ),
    );
  }

  String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final now = DateTime.now();
    final date = timestamp.toDate();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'たった今';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 7) return '${diff.inDays}日前';
    return '${date.month}/${date.day}';
  }

  Future<void> _deleteAllNotifications() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('通知をすべて削除',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text('すべての通知を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('キャンセル',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final docs = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .collection('notifications')
          .get();
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in docs.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
  }
}
