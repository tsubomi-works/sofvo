import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../config/app_theme.dart';
import '../../services/follow_service.dart';
import '../../widgets/official_badge.dart';
import '../chat/chat_screen.dart';
import '../profile/my_page_screen.dart';

/// ユーザー詳細画面（管理者用）
class AdminUserDetailScreen extends StatefulWidget {
  final String userId;

  const AdminUserDetailScreen({super.key, required this.userId});

  @override
  State<AdminUserDetailScreen> createState() => _AdminUserDetailScreenState();
}

class _AdminUserDetailScreenState extends State<AdminUserDetailScreen> {
  final _firestore = FirebaseFirestore.instance;
  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  bool _loadingAction = false;

  @override
  void initState() {
    super.initState();
    FollowService.instance.addListener(_onFollowChanged);
  }

  @override
  void dispose() {
    FollowService.instance.removeListener(_onFollowChanged);
    super.dispose();
  }

  void _onFollowChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleFollow(String nickname) async {
    setState(() => _loadingAction = true);
    try {
      final myDoc = await _firestore.collection('users').doc(_currentUid).get();
      final myNickname = (myDoc.data()?['nickname'] as String?) ?? '管理者';
      await FollowService.instance.toggleFollow(
        targetUid: widget.userId,
        targetNickname: nickname,
        myNickname: myNickname,
      );
    } finally {
      if (mounted) setState(() => _loadingAction = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('ユーザー詳細',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _firestore.collection('users').doc(widget.userId).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: AppTheme.primaryColor));
          }
          if (!snapshot.data!.exists) {
            return const Center(child: Text('ユーザーが見つかりません'));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildUserHeader(data),
              const SizedBox(height: 16),
              _buildAccountInfo(data),
              const SizedBox(height: 16),
              _buildActivityStats(data),
              const SizedBox(height: 16),
              _buildActionButtons(data),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _buildUserHeader(Map<String, dynamic> data) {
    final nickname = (data['nickname'] ?? '名前なし').toString();
    final avatarUrl = (data['avatarUrl'] ?? '').toString();
    final searchId = (data['searchId'] ?? '').toString();
    final isOfficial = data['isOfficial'] == true;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          avatarUrl.isNotEmpty
              ? CircleAvatar(
                  radius: 40,
                  backgroundImage: CachedNetworkImageProvider(avatarUrl),
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                )
              : CircleAvatar(
                  radius: 40,
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                  child: Text(
                    nickname.isNotEmpty ? nickname[0] : '?',
                    style: const TextStyle(
                      color: AppTheme.primaryColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 28,
                    ),
                  ),
                ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  nickname,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isOfficial) const OfficialBadge(size: 18),
            ],
          ),
          if (searchId.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('@$searchId',
                style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          ],
        ],
      ),
    );
  }

  Widget _buildAccountInfo(Map<String, dynamic> data) {
    final email = (data['email'] ?? '').toString();
    final createdAt = data['createdAt'] as Timestamp?;
    final lastActiveAt = data['lastActiveAt'] as Timestamp?;
    final isAdmin = data['isAdmin'] == true;
    final isOfficial = data['isOfficial'] == true;
    final isBanned = data['isBanned'] == true;
    final area = (data['area'] ?? '未設定').toString();
    final experience = (data['experience'] ?? '未設定').toString();
    final gender = (data['gender'] ?? '未設定').toString();

    String permission = '一般ユーザー';
    if (isAdmin) {
      permission = '管理者';
    } else if (isOfficial) {
      permission = '公式アカウント';
    }
    if (isBanned) permission += '(凍結中)';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('アカウント情報', Icons.person_rounded),
          const SizedBox(height: 12),
          _buildInfoRow('メール', email.isNotEmpty ? email : '未設定'),
          _buildInfoRow('登録日', createdAt != null ? _formatDate(createdAt) : '不明'),
          _buildInfoRow(
              '最終アクティブ', lastActiveAt != null ? _formatDateTime(lastActiveAt) : '不明'),
          _buildInfoRow('権限', permission,
              valueColor: isBanned ? AppTheme.error : null),
          _buildInfoRow('エリア', area),
          _buildInfoRow('競技歴', experience),
          _buildInfoRow('性別', gender),
        ],
      ),
    );
  }

  Widget _buildActivityStats(Map<String, dynamic> data) {
    final stats = data['stats'] as Map<String, dynamic>? ?? {};
    final tournamentsPlayed = _safeInt(stats['tournamentsPlayed']);
    final wins = _safeInt(stats['wins']);
    final losses = _safeInt(stats['losses']);
    final followersCount = _safeInt(data['followersCount']);
    final followingCount = _safeInt(data['followingCount']);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('活動統計', Icons.bar_chart_rounded),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildStatCard('大会参加', tournamentsPlayed, Icons.emoji_events_rounded,
                  AppTheme.accentColor),
              const SizedBox(width: 8),
              _buildStatCard('勝利', wins, Icons.military_tech_rounded, AppTheme.success),
              const SizedBox(width: 8),
              _buildStatCard('敗北', losses, Icons.close_rounded, AppTheme.error),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildStatCard(
                  'フォロワー', followersCount, Icons.people_rounded, AppTheme.primaryColor),
              const SizedBox(width: 8),
              _buildStatCard(
                  'フォロー', followingCount, Icons.person_add_rounded, AppTheme.info),
              const SizedBox(width: 8),
              Expanded(child: _buildPostCountCard()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, int count, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 4),
            Text('$count',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            Text(label,
                style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _buildPostCountCard() {
    return FutureBuilder<AggregateQuerySnapshot>(
      future: _firestore
          .collection('posts')
          .where('userId', isEqualTo: widget.userId)
          .count()
          .get(),
      builder: (context, snap) {
        final count = snap.data?.count ?? 0;
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.teal.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              const Icon(Icons.article_rounded, size: 20, color: Colors.teal),
              const SizedBox(height: 4),
              Text('$count',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal)),
              Text('投稿',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600])),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionButtons(Map<String, dynamic> data) {
    final isBanned = data['isBanned'] == true;
    final isOfficial = data['isOfficial'] == true;
    final isAdmin = data['isAdmin'] == true;
    final nickname = (data['nickname'] ?? '名前なし').toString();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('管理アクション', Icons.admin_panel_settings_rounded),
          const SizedBox(height: 12),
          _buildActionTile(
            icon: Icons.account_circle_rounded,
            label: 'プロフィールページを表示',
            color: AppTheme.primaryColor,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MyPageScreen(targetUserId: widget.userId),
              ),
            ),
          ),
          if (widget.userId != _currentUid) ...[
            const Divider(height: 1),
            _buildActionTile(
              icon: FollowService.instance.isFollowing(widget.userId)
                  ? Icons.person_remove_rounded
                  : Icons.person_add_alt_1_rounded,
              label: FollowService.instance.isFollowing(widget.userId)
                  ? 'フォロー中（タップで解除）'
                  : 'フォローする',
              color: FollowService.instance.isFollowing(widget.userId)
                  ? AppTheme.textSecondary
                  : AppTheme.primaryColor,
              onTap: () => _toggleFollow(nickname),
            ),
          ],
          const Divider(height: 1),
          _buildActionTile(
            icon: isBanned ? Icons.lock_open_rounded : Icons.block_rounded,
            label: isBanned ? 'アカウント凍結を解除' : 'アカウントを凍結',
            color: isBanned ? AppTheme.success : AppTheme.error,
            onTap: () => _confirmToggleField(
              field: 'isBanned',
              currentValue: isBanned,
              nickname: nickname,
              enableLabel: 'アカウントを凍結',
              disableLabel: '凍結を解除',
              enableMessage: '$nickname さんのアカウントを凍結しますか？\n凍結されたユーザーはアプリを使用できなくなります。',
              disableMessage: '$nickname さんの凍結を解除しますか？',
            ),
          ),
          const Divider(height: 1),
          _buildActionTile(
            icon: isOfficial ? Icons.verified_rounded : Icons.verified_outlined,
            label: isOfficial ? '公式アカウントを解除' : '公式アカウントに設定',
            color: isOfficial ? AppTheme.textSecondary : AppTheme.info,
            onTap: () => _confirmToggleField(
              field: 'isOfficial',
              currentValue: isOfficial,
              nickname: nickname,
              enableLabel: '公式アカウントに設定',
              disableLabel: '公式アカウントを解除',
              enableMessage: '$nickname さんを公式アカウントに設定しますか？',
              disableMessage: '$nickname さんの公式アカウントを解除しますか？',
            ),
          ),
          const Divider(height: 1),
          _buildActionTile(
            icon: isAdmin
                ? Icons.shield_rounded
                : Icons.shield_outlined,
            label: isAdmin ? '管理者権限を解除' : '管理者権限を付与',
            color: isAdmin ? AppTheme.textSecondary : Colors.purple,
            onTap: () => _confirmToggleField(
              field: 'isAdmin',
              currentValue: isAdmin,
              nickname: nickname,
              enableLabel: '管理者権限を付与',
              disableLabel: '管理者権限を解除',
              enableMessage: '$nickname さんに管理者権限を付与しますか？',
              disableMessage: '$nickname さんの管理者権限を解除しますか？',
            ),
          ),
          const Divider(height: 1),
          _buildActionTile(
            icon: Icons.chat_bubble_outline_rounded,
            label: 'チャットを開始',
            color: AppTheme.primaryColor,
            onTap: () => _startDm(nickname),
          ),
          const Divider(height: 1),
          _buildActionTile(
            icon: Icons.delete_forever_rounded,
            label: 'アカウントを削除',
            color: AppTheme.error,
            onTap: () => _confirmDeleteUser(data),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
      title: Text(label,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: color)),
      trailing: _loadingAction
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor),
            )
          : Icon(Icons.chevron_right, color: Colors.grey[400]),
      onTap: _loadingAction ? null : onTap,
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.primaryColor),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary)),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    color: valueColor ?? AppTheme.textPrimary,
                    fontWeight: valueColor != null ? FontWeight.w600 : null)),
          ),
        ],
      ),
    );
  }

  void _confirmToggleField({
    required String field,
    required bool currentValue,
    required String nickname,
    required String enableLabel,
    required String disableLabel,
    required String enableMessage,
    required String disableMessage,
  }) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(currentValue ? disableLabel : enableLabel),
          content: Text(currentValue ? disableMessage : enableMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('キャンセル',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _toggleField(field, !currentValue);
              },
              child: Text(
                currentValue ? disableLabel : enableLabel,
                style: TextStyle(
                  color: field == 'isBanned'
                      ? (currentValue ? AppTheme.success : AppTheme.error)
                      : AppTheme.primaryColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _toggleField(String field, bool newValue) async {
    setState(() => _loadingAction = true);
    try {
      await _firestore.collection('users').doc(widget.userId).update({
        field: newValue,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('設定を更新しました'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラーが発生しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
    if (mounted) {
      setState(() => _loadingAction = false);
    }
  }

  void _confirmDeleteUser(Map<String, dynamic> data) {
    final nickname = (data['nickname'] ?? '名前なし').toString();
    final searchId = (data['searchId'] ?? '').toString();
    final isOfficial = data['isOfficial'] == true;
    final isAdmin = data['isAdmin'] == true;
    final isSelf = widget.userId == _currentUid;

    // 自分自身は削除不可
    if (isSelf) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('自分自身のアカウントは削除できません'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('アカウントを削除',
              style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$nickname${searchId.isNotEmpty ? '（@$searchId）' : ''} さんのアカウントを削除しますか？',
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 12),
              const Text(
                'この操作は取り消せません。プロフィール・フォロー・通知などのデータと、ログイン情報（認証アカウント）がすべて削除されます。',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
              ),
              if (isOfficial || isAdmin) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isAdmin
                        ? '⚠️ このアカウントは「管理者」です。本当に削除してよいか確認してください。'
                        : '⚠️ このアカウントは「公式アカウント」です。本当に削除してよいか確認してください。',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.error, fontWeight: FontWeight.w600, height: 1.4),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('キャンセル',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _deleteUser(nickname);
              },
              child: const Text('削除する',
                  style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteUser(String nickname) async {
    setState(() => _loadingAction = true);
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('adminDeleteUser');
      await callable.call({'uid': widget.userId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$nickname さんのアカウントを削除しました'),
            backgroundColor: AppTheme.success,
          ),
        );
        // 削除済みのユーザーを開いたままにできないので一覧へ戻る
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        final message = e is FirebaseFunctionsException && (e.message ?? '').isNotEmpty
            ? e.message!
            : '削除に失敗しました: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: AppTheme.error),
        );
        setState(() => _loadingAction = false);
      }
    }
  }

  Future<void> _startDm(String otherName) async {
    final myUid = _currentUid;
    if (myUid.isEmpty) return;

    setState(() => _loadingAction = true);

    try {
      final existing = await _firestore
          .collection('chats')
          .where('type', isEqualTo: 'dm')
          .where('members', arrayContains: myUid)
          .get();

      String? chatId;
      for (final doc in existing.docs) {
        final members = List<String>.from(doc['members'] ?? []);
        if (members.contains(widget.userId)) {
          chatId = doc.id;
          break;
        }
      }

      if (chatId == null) {
        final myDoc = await _firestore.collection('users').doc(myUid).get();
        final myName = (myDoc.data()?['nickname'] as String?) ?? '自分';

        final ref = await _firestore.collection('chats').add({
          'type': 'dm',
          'members': [myUid, widget.userId],
          'memberNames': {myUid: myName, widget.userId: otherName},
          'lastMessage': '',
          'lastMessageAt': FieldValue.serverTimestamp(),
          'lastRead': {myUid: FieldValue.serverTimestamp()},
          'createdAt': FieldValue.serverTimestamp(),
        });
        chatId = ref.id;
      }

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              chatId: chatId!,
              chatTitle: otherName,
              chatType: 'dm',
              otherUserId: widget.userId,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラーが発生しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }

    if (mounted) {
      setState(() => _loadingAction = false);
    }
  }

  int _safeInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    return 0;
  }

  String _formatDate(Timestamp ts) {
    final d = ts.toDate();
    return '${d.year}/${d.month}/${d.day}';
  }

  String _formatDateTime(Timestamp ts) {
    final d = ts.toDate();
    return '${d.year}/${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
