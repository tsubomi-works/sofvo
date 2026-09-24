import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../config/app_theme.dart';
import '../home/create_post_screen.dart';
import 'venue_search_screen.dart';
import '../gadget/gadget_register_screen.dart';
import '../profile/user_profile_screen.dart';
import '../../services/notification_service.dart';

/// 大会終了後のアクション促進画面
/// Step1: ふりかえり投稿（テンプレート選択）
/// Step2: 投稿完了後 → ついでにもう1つ
class PostEventActionScreen extends StatefulWidget {
  final String tournamentId;
  final String tournamentName;
  final String? result; // 例: '優勝', '準優勝', '3位', 'ベスト8'

  const PostEventActionScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
    this.result,
  });

  @override
  State<PostEventActionScreen> createState() => _PostEventActionScreenState();
}

class _PostEventActionScreenState extends State<PostEventActionScreen> {
  bool _posted = false; // 投稿完了したか

  List<String> get _templates {
    final result = widget.result;
    final hasResult = result != null && result.isNotEmpty;
    return [
      if (hasResult && result == '優勝') '優勝できました！チームに感謝！',
      if (hasResult && result != '優勝') '悔しい！次こそリベンジ！',
      '楽しかった！次も参加したい',
      '初参加でしたが楽しめました！',
    ];
  }

  Future<void> _openPostWithTemplate(String template) async {
    final text = '${widget.tournamentName}\n'
        '${widget.result != null && widget.result!.isNotEmpty ? '結果: ${widget.result}\n' : ''}'
        '\n$template';

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          tournamentId: widget.tournamentId,
          tournamentName: widget.tournamentName,
          initialText: text,
        ),
      ),
    );
    if (result == true && mounted) {
      setState(() => _posted = true);
    }
  }

  Future<void> _openFreePost() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          tournamentId: widget.tournamentId,
          tournamentName: widget.tournamentName,
        ),
      ),
    );
    if (result == true && mounted) {
      setState(() => _posted = true);
    }
  }

  /// 大会の会場を直接編集画面で開く
  Future<void> _openVenueEdit() async {
    final tournDoc = await FirebaseFirestore.instance
        .collection('tournaments').doc(widget.tournamentId).get();
    if (!tournDoc.exists || !mounted) return;
    final data = tournDoc.data()!;
    final venueId = data['venueId'] as String? ?? '';

    if (venueId.isEmpty) {
      // venueIdが無い場合は検索画面にフォールバック
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => const VenueSearchScreen()));
      return;
    }

    final venueDoc = await FirebaseFirestore.instance
        .collection('venues').doc(venueId).get();
    if (!mounted) return;

    if (venueDoc.exists) {
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => VenueRegisterScreen(
            existingVenue: venueDoc.data(),
            venueId: venueId,
          )));
    } else {
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => const VenueSearchScreen()));
    }
  }

  /// 大会参加者一覧をフォロー可能なリストで表示
  Future<void> _openParticipantsList() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => _TournamentParticipantsScreen(
          tournamentId: widget.tournamentId,
          tournamentName: widget.tournamentName,
        )));
  }

  @override
  Widget build(BuildContext context) {
    return _posted ? _buildFollowUpScreen() : _buildReviewScreen();
  }

  // ━━━ Step1: ふりかえり投稿画面 ━━━
  Widget _buildReviewScreen() {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 40),

              // ヘッダー
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.emoji_events, size: 32, color: AppTheme.accentColor),
              ),
              const SizedBox(height: 16),
              const Text(
                'お疲れさまでした！',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                widget.tournamentName,
                style: const TextStyle(fontSize: 15, color: AppTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (widget.result != null && widget.result!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '結果: ${widget.result}',
                    style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      color: AppTheme.accentColor,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 32),

              // 説明
              const Text(
                '今日の感想を残しませんか？',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),

              // テンプレート選択肢
              Expanded(
                child: ListView(
                  children: [
                    ..._templates.map((t) => _templateButton(t)),
                    _templateButton('自分の言葉で書く', icon: Icons.edit, isFreeForm: true),
                  ],
                ),
              ),

              // あとで
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'あとで',
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _templateButton(String text, {IconData? icon, bool isFreeForm = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isFreeForm
            ? AppTheme.primaryColor.withValues(alpha: 0.06)
            : Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => isFreeForm ? _openFreePost() : _openPostWithTemplate(text),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isFreeForm
                    ? AppTheme.primaryColor.withValues(alpha: 0.3)
                    : Colors.grey[200]!,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon ?? Icons.chat_bubble_outline,
                  size: 20,
                  color: isFreeForm ? AppTheme.primaryColor : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: isFreeForm ? AppTheme.primaryColor : AppTheme.textPrimary,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ━━━ Step2: ついでにもう1つ画面 ━━━
  Widget _buildFollowUpScreen() {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 40),

              // 投稿完了メッセージ
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, size: 32, color: AppTheme.success),
              ),
              const SizedBox(height: 16),
              const Text(
                '投稿しました！',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 32),

              // ついでにもう1つ
              const Text(
                'ついでにもう1つ\nやってみませんか？',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),

              Expanded(
                child: ListView(
                  children: [
                    _followUpAction(
                      icon: Icons.apartment,
                      title: '会場の情報を登録',
                      subtitle: '床・ポール・設備の記録',
                      onTap: () => _openVenueEdit(),
                    ),
                    _followUpAction(
                      icon: Icons.sports_handball,
                      title: '使った道具を登録',
                      subtitle: 'シューズ・サポーター等の記録',
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const GadgetRegisterScreen()),
                        );
                      },
                    ),
                    _followUpAction(
                      icon: Icons.people,
                      title: '参加者をフォロー',
                      subtitle: '今日の対戦相手とつながる',
                      onTap: () => _openParticipantsList(),
                    ),
                  ],
                ),
              ),

              // おしまい
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('おしまい', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _followUpAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 22, color: AppTheme.primaryColor),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 大会参加者一覧（フォロー可能）
class _TournamentParticipantsScreen extends StatefulWidget {
  final String tournamentId;
  final String tournamentName;

  const _TournamentParticipantsScreen({
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<_TournamentParticipantsScreen> createState() => _TournamentParticipantsScreenState();
}

class _TournamentParticipantsScreenState extends State<_TournamentParticipantsScreen> {
  final _firestore = FirebaseFirestore.instance;
  User? get _currentUser => FirebaseAuth.instance.currentUser;
  final Set<String> _followingIds = {};
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final uid = _currentUser?.uid;
    if (uid == null) return;

    // フォロー中のユーザーIDを取得
    final followingSnap = await _firestore
        .collection('users').doc(uid).collection('following').get();
    _followingIds.addAll(followingSnap.docs.map((d) => d.id));

    // 大会のエントリーからメンバーを収集
    final entriesSnap = await _firestore
        .collection('tournaments').doc(widget.tournamentId)
        .collection('entries').get();

    final participants = <Map<String, dynamic>>[];
    final seenUids = <String>{};

    for (final entry in entriesSnap.docs) {
      final data = entry.data();
      final teamName = data['teamName'] as String? ?? '';
      final memberNames = (data['memberNames'] as Map<String, dynamic>?) ?? {};

      for (final member in memberNames.entries) {
        final memberId = member.key;
        if (memberId == uid || seenUids.contains(memberId)) continue;
        seenUids.add(memberId);
        participants.add({
          'uid': memberId,
          'name': member.value?.toString() ?? '',
          'teamName': teamName,
        });
      }
    }

    // ユーザー情報（アバター等）を取得
    for (int i = 0; i < participants.length; i++) {
      final userDoc = await _firestore.collection('users').doc(participants[i]['uid']).get();
      if (userDoc.exists) {
        final userData = userDoc.data()!;
        participants[i]['avatarUrl'] = userData['avatarUrl'] ?? '';
        participants[i]['name'] = userData['nickname'] ?? userData['displayName'] ?? participants[i]['name'];
      }
    }

    if (mounted) setState(() { _participants = participants; _loading = false; });
  }

  Future<void> _toggleFollow(String targetUid) async {
    final uid = _currentUser?.uid;
    if (uid == null) return;

    final isFollowing = _followingIds.contains(targetUid);
    final myRef = _firestore.collection('users').doc(uid).collection('following').doc(targetUid);
    final theirRef = _firestore.collection('users').doc(targetUid).collection('followers').doc(uid);

    if (isFollowing) {
      await myRef.delete();
      await theirRef.delete();
      setState(() => _followingIds.remove(targetUid));
    } else {
      await myRef.set({'createdAt': FieldValue.serverTimestamp()});
      await theirRef.set({'createdAt': FieldValue.serverTimestamp()});
      setState(() => _followingIds.add(targetUid));
      // フォロー通知
      final myDoc = await _firestore.collection('users').doc(uid).get();
      final myName = myDoc.data()?['nickname'] ?? myDoc.data()?['displayName'] ?? '';
      NotificationService.sendFollowNotification(
        targetUserId: targetUid,
        senderName: myName,
        senderId: uid,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('参加者をフォロー', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor))
          : _participants.isEmpty
              ? Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.people_outline, size: 64, color: AppTheme.textHint),
                    const SizedBox(height: 16),
                    const Text('他の参加者がいません', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                  ]),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('${widget.tournamentName}の参加者',
                        style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
                    const SizedBox(height: 4),
                    Text('${_participants.length}人', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    const SizedBox(height: 12),
                    ..._participants.map((p) => _participantTile(p)),
                  ],
                ),
    );
  }

  Widget _participantTile(Map<String, dynamic> p) {
    final uid = p['uid'] as String;
    final name = p['name'] as String? ?? '';
    final teamName = p['teamName'] as String? ?? '';
    final avatarUrl = p['avatarUrl'] as String? ?? '';
    final isFollowing = _followingIds.contains(uid);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
        backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
        child: avatarUrl.isEmpty
            ? Text(name.isNotEmpty ? name[0] : '?',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.primaryColor))
            : null,
      ),
      title: Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: Text(teamName, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      trailing: SizedBox(
        width: 100,
        height: 34,
        child: isFollowing
            ? OutlinedButton(
                onPressed: () => _toggleFollow(uid),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  side: BorderSide(color: Colors.grey[300]!),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('フォロー中', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              )
            : ElevatedButton(
                onPressed: () => _toggleFollow(uid),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('フォロー', style: TextStyle(fontSize: 12)),
              ),
      ),
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => UserProfileScreen(userId: uid))),
    );
  }
}
