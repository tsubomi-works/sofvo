import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';
import '../../services/content_filter_service.dart';
import '../../widgets/official_badge.dart';

class CommentScreen extends StatefulWidget {
  final String postId;
  final String postOwnerName;

  const CommentScreen({
    super.key,
    required this.postId,
    required this.postOwnerName,
  });

  @override
  State<CommentScreen> createState() => _CommentScreenState();
}

class _CommentScreenState extends State<CommentScreen> {
  final _commentController = TextEditingController();
  final _scrollController = ScrollController();
  User? get _currentUser => FirebaseAuth.instance.currentUser;
  bool _isSending = false;
  final Map<String, bool> _officialCache = {};

  Future<void> _checkOfficial(String userId) async {
    if (_officialCache.containsKey(userId)) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      if (mounted) {
        setState(() {
          _officialCache[userId] = doc.data()?['isOfficial'] == true;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _commentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _currentUser == null) return;

    if (ContentFilterService.containsProhibitedContent(text)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('不適切な表現が含まれています。内容を修正してください。'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }

    _commentController.clear();
    setState(() => _isSending = true);

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .get();
      final nickname =
          (userDoc.data()?['nickname'] as String?) ?? '名無し';

      await FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .collection('comments')
          .add({
        'userId': _currentUser!.uid,
        'userNickname': nickname,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });

      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('コメントの送信に失敗しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _deleteComment(String commentId) async {
    try {
      await FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .collection('comments')
          .doc(commentId)
          .delete();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('コメントを削除しました'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('削除に失敗しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _showDeleteDialog(String commentId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('コメントを削除',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text('このコメントを削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('キャンセル',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteComment(commentId);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return 'たった今';
    final now = DateTime.now();
    final date = timestamp.toDate();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'たった今';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 7) return '${diff.inDays}日前';
    return '${date.month}/${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('コメント'),
      ),
      body: Column(
        children: [
          // ── コメント一覧 ──
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('posts')
                  .doc(widget.postId)
                  .collection('comments')
                  .orderBy('createdAt', descending: false)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.primaryColor));
                }

                final comments = snapshot.data?.docs ?? [];

                if (comments.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text('まだコメントはありません',
                            style: TextStyle(
                                fontSize: 15,
                                color: AppTheme.textSecondary)),
                        const SizedBox(height: 4),
                        Text('最初のコメントを投稿しましょう！',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppTheme.textHint)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: comments.length,
                  itemBuilder: (context, index) {
                    final data =
                        comments[index].data() as Map<String, dynamic>;
                    final commentId = comments[index].id;
                    final isMyComment =
                        data['userId'] == _currentUser?.uid;
                    return _buildCommentItem(commentId, data, isMyComment);
                  },
                );
              },
            ),
          ),

          // ── 入力欄 ──
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(color: Colors.grey[200]!),
              ),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor:
                        AppTheme.primaryColor.withValues(alpha: 0.12),
                    child: const Icon(Icons.person,
                        size: 18, color: AppTheme.primaryColor),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundColor,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _commentController,
                        style: const TextStyle(fontSize: 15),
                        maxLines: 3,
                        minLines: 1,
                        decoration: const InputDecoration(
                          hintText: 'コメントを入力...',
                          hintStyle: TextStyle(color: AppTheme.textHint),
                          border: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 10),
                        ),
                        onSubmitted: (_) => _sendComment(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _isSending ? null : _sendComment,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _isSending
                            ? Colors.grey
                            : AppTheme.primaryColor,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(Icons.send,
                          color: Colors.white, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showCommentOptionsSheet(String commentId, Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(Icons.flag_outlined, color: AppTheme.warning),
                title: const Text('このコメントを報告'),
                onTap: () {
                  Navigator.pop(ctx);
                  _reportComment(commentId, data);
                },
              ),
              ListTile(
                leading: Icon(Icons.close, color: AppTheme.textSecondary),
                title: const Text('キャンセル'),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reportComment(String commentId, Map<String, dynamic> data) async {
    final uid = _currentUser?.uid;
    if (uid == null) return;

    final reasons = [
      'スパム・迷惑行為',
      '不適切なコンテンツ',
      'なりすまし',
      'ハラスメント',
      'その他',
    ];

    final selectedReason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('報告の理由を選択',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              ...reasons.map((reason) => ListTile(
                    title: Text(reason),
                    onTap: () => Navigator.pop(ctx, reason),
                  )),
            ],
          ),
        ),
      ),
    );

    if (selectedReason == null) return;

    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'commentId': commentId,
        'postId': widget.postId,
        'reporterId': uid,
        'targetUserId': data['userId'],
        'reason': selectedReason,
        'type': 'comment',
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('報告を受け付けました。ご協力ありがとうございます。'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('報告に失敗しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Widget _buildCommentItem(
      String commentId, Map<String, dynamic> data, bool isMyComment) {
    final nickname = (data['userNickname'] as String?) ?? '名無し';
    final text = (data['text'] as String?) ?? '';
    final createdAt = data['createdAt'] as Timestamp?;
    final timeText = _formatTime(createdAt);
    final userId = data['userId'] as String? ?? '';
    if (userId.isNotEmpty && !_officialCache.containsKey(userId)) {
      _checkOfficial(userId);
    }
    final isOfficial = _officialCache[userId] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor:
                AppTheme.primaryColor.withValues(alpha: 0.12),
            child: Text(
              nickname.isNotEmpty ? nickname[0] : '?',
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryColor),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(nickname,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    if (isOfficial)
                      const OfficialBadge(size: 14),
                    const SizedBox(width: 6),
                    Text(timeText,
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textHint)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        if (isMyComment) {
                          _showDeleteDialog(commentId);
                        } else {
                          _showCommentOptionsSheet(commentId, data);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.more_horiz,
                            size: 18, color: AppTheme.textSecondary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: Text(text,
                      style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textPrimary,
                          height: 1.4)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
