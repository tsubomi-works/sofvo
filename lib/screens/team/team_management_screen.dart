import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../config/app_theme.dart';
import '../../widgets/invite_share_sheet.dart';
import 'team_detail_screen.dart';
import '../chat/chat_screen.dart';

class TeamManagementScreen extends StatefulWidget {
  const TeamManagementScreen({super.key});

  @override
  State<TeamManagementScreen> createState() => _TeamManagementScreenState();
}

class _TeamManagementScreenState extends State<TeamManagementScreen> {
  User? get _currentUser => FirebaseAuth.instance.currentUser;

  @override
  Widget build(BuildContext context) {
    if (_currentUser == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('チーム管理')),
        body: const Center(child: Text('ログインしてください')),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('チーム管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showHelpDialog,
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('teams')
            .where('memberIds', arrayContains: _currentUser!.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: AppTheme.primaryColor));
          }

          if (snapshot.hasError) {
            // インデックス未作成の場合のフォールバック
            return _buildFallbackList();
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) return _buildEmptyState();

          final mainTeams = <QueryDocumentSnapshot>[];
          final otherTeams = <QueryDocumentSnapshot>[];

          for (final doc in docs) {
            final data = doc.data() as Map<String, dynamic>;
            if (data['isMain'] == true) {
              mainTeams.add(doc);
            } else {
              otherTeams.add(doc);
            }
          }

          // 自分がオーナーのチームを先頭にソート
          int ownerSort(QueryDocumentSnapshot a, QueryDocumentSnapshot b) {
            final aOwner = (a.data() as Map<String, dynamic>)['ownerId'] == _currentUser!.uid;
            final bOwner = (b.data() as Map<String, dynamic>)['ownerId'] == _currentUser!.uid;
            if (aOwner && !bOwner) return -1;
            if (!aOwner && bOwner) return 1;
            return 0;
          }
          mainTeams.sort(ownerSort);
          otherTeams.sort(ownerSort);

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              _buildInfoBanner(),
              const SizedBox(height: 20),
              if (mainTeams.isNotEmpty) ...[
                _buildSectionHeader('メインチーム', Icons.star, AppTheme.accentColor),
                const SizedBox(height: 10),
                ...mainTeams.map((doc) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildTeamCard(doc),
                    )),
              ],
              if (otherTeams.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildSectionHeader('即席チーム・参加チーム', Icons.groups, AppTheme.primaryColor),
                const SizedBox(height: 10),
                ...otherTeams.map((doc) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildTeamCard(doc),
                    )),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateTeamSheet,
        backgroundColor: AppTheme.primaryColor,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('チームを作成',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // インデックス未作成時のフォールバック
  Widget _buildFallbackList() {
    return FutureBuilder<QuerySnapshot>(
      future: FirebaseFirestore.instance
          .collection('teams')
          .where('memberIds', arrayContains: _currentUser!.uid)
          .get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return _buildEmptyState();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            _buildInfoBanner(),
            const SizedBox(height: 20),
            ...docs.map((doc) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _buildTeamCard(doc),
                )),
          ],
        );
      },
    );
  }

  Widget _buildInfoBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor.withValues(alpha:0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: AppTheme.primaryColor, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'メインチームは常に活動する固定チームです。\n即席チームは大会ごとの一時的なチームです。',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.groups_outlined, size: 80, color: AppTheme.textHint),
          const SizedBox(height: 16),
          const Text('まだチームがありません',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const Text('チームを作成して大会にエントリーしましょう！',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _showCreateTeamSheet,
            icon: const Icon(Icons.add),
            label: const Text('チームを作成'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Widget _buildTeamCard(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final name = data['name'] ?? '無名チーム';
    final isMain = data['isMain'] == true;
    final ownerId = data['ownerId'] ?? '';
    final memberIds = data['memberIds'] is List ? List<String>.from(data['memberIds']) : <String>[];
    final memberNames = data['memberNames'] is Map ? Map<String, String>.from(data['memberNames']) : <String, String>{};
    final memberAvatars = data['memberAvatars'] is Map ? Map<String, String>.from(data['memberAvatars']) : <String, String>{};
    final isOwner = ownerId == _currentUser!.uid;
    final role = isOwner ? 'オーナー' : 'メンバー';

    Color roleColor = isOwner ? AppTheme.accentColor : AppTheme.textSecondary;
    IconData roleIcon = isOwner ? Icons.shield : Icons.person;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TeamDetailScreen(
              teamName: name,
              isMain: isMain,
              isOwner: isOwner,
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: isMain
              ? Border.all(color: AppTheme.accentColor.withValues(alpha:0.3), width: 2)
              : null,
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha:0.04), blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              decoration: BoxDecoration(
                color: isMain
                    ? AppTheme.accentColor.withValues(alpha:0.04)
                    : AppTheme.primaryColor.withValues(alpha:0.03),
                borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14), topRight: Radius.circular(14)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: isMain
                        ? AppTheme.accentColor.withValues(alpha:0.15)
                        : AppTheme.primaryColor.withValues(alpha:0.12),
                    child: Text(name[0],
                        style: TextStyle(
                            color: isMain ? AppTheme.accentColor : AppTheme.primaryColor,
                            fontWeight: FontWeight.bold, fontSize: 18)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(name,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (isMain) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                    color: AppTheme.accentColor.withValues(alpha:0.15),
                                    borderRadius: BorderRadius.circular(6)),
                                child: const Text('メイン',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(roleIcon, size: 14, color: roleColor),
                            const SizedBox(width: 4),
                            Text(role, style: TextStyle(fontSize: 12, color: roleColor, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 12),
                            Icon(Icons.people, size: 14, color: AppTheme.textSecondary),
                            const SizedBox(width: 4),
                            Text('${memberIds.length}人',
                                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: AppTheme.textHint),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  ...memberIds.take(5).map((mid) {
                    final mName = memberNames[mid] ?? '?';
                    final mAvatar = memberAvatars[mid] ?? '';
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: mAvatar.isNotEmpty
                          ? CircleAvatar(
                              radius: 16,
                              backgroundImage: NetworkImage(mAvatar),
                              backgroundColor: AppTheme.primaryColor.withValues(alpha:0.1),
                            )
                          : CircleAvatar(
                              radius: 16,
                              backgroundColor: AppTheme.primaryColor.withValues(alpha:0.1),
                              child: Text(mName.isNotEmpty ? mName[0] : '?',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                            ),
                    );
                  }),
                  if (memberIds.length > 5) ...[
                    const SizedBox(width: 4),
                    Text('+${memberIds.length - 5}',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                  ],
                  const Spacer(),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _openOrCreateTeamChat(
                          teamId: doc.id,
                          teamName: name,
                          memberIds: memberIds,
                          memberNames: memberNames,
                        ),
                        icon: const Icon(Icons.chat_bubble_outline, size: 16),
                        label: const Text('チャット', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.success,
                            side: const BorderSide(color: AppTheme.success),
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                      ),
                      if (isOwner) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => _showInviteSheet(doc.id, name),
                          icon: const Icon(Icons.person_add, size: 16),
                          label: const Text('招待', style: TextStyle(fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primaryColor,
                              side: const BorderSide(color: AppTheme.primaryColor),
                              minimumSize: const Size(0, 32),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: AppTheme.error, size: 20),
                          onPressed: () => _showDeleteConfirm(doc.id, name),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (isOwner) _buildJoinRequests(doc.id),
          ],
        ),
      ),
    );
  }

  // ── 参加リクエスト（承認制）— オーナーのみ表示 ──
  Widget _buildJoinRequests(String teamId) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('teams')
          .doc(teamId)
          .collection('joinRequests')
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.accentColor.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.how_to_reg, size: 16, color: AppTheme.accentColor),
                  const SizedBox(width: 6),
                  Text('参加リクエスト ${docs.length}件',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
                ],
              ),
              const SizedBox(height: 8),
              ...docs.map((req) {
                final r = req.data() as Map<String, dynamic>;
                final applicantUid = (r['uid'] ?? req.id).toString();
                final name = (r['name'] ?? '名前なし').toString();
                final avatar = (r['avatar'] ?? '').toString();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      avatar.isNotEmpty
                          ? CircleAvatar(radius: 16, backgroundImage: NetworkImage(avatar))
                          : CircleAvatar(
                              radius: 16,
                              backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                              child: Text(name.isNotEmpty ? name[0] : '?',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primaryColor))),
                      const SizedBox(width: 10),
                      Expanded(child: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                      TextButton(
                        onPressed: () => _respondJoinRequest(teamId, applicantUid, name, true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: AppTheme.primaryColor,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('承認', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: () => _respondJoinRequest(teamId, applicantUid, name, false),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.error,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: const Text('却下', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _respondJoinRequest(String teamId, String applicantUid, String applicantName, bool approve) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('respondTeamJoinRequest');
      await callable.call({'teamId': teamId, 'applicantUid': applicantUid, 'approve': approve});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approve ? '$applicantNameさんの参加を承認しました' : '$applicantNameさんの参加を却下しました'),
            backgroundColor: approve ? AppTheme.success : AppTheme.textSecondary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('処理に失敗しました。もう一度お試しください'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ── チームチャットを開く or 作成 ──
  Future<void> _openOrCreateTeamChat({
    required String teamId,
    required String teamName,
    required List<String> memberIds,
    required Map<String, String> memberNames,
  }) async {
    if (_currentUser == null) return;

    // linkedId でチームに紐づくチャットを検索
    final existing = await FirebaseFirestore.instance
        .collection('chats')
        .where('type', isEqualTo: 'team')
        .where('linkedId', isEqualTo: teamId)
        .get();

    String chatId;
    if (existing.docs.isNotEmpty) {
      chatId = existing.docs.first.id;
    } else {
      // チーム全メンバーを含むチャットを新規作成
      final ref = await FirebaseFirestore.instance.collection('chats').add({
        'type': 'team',
        'name': teamName,
        'linkedId': teamId,
        'members': memberIds,
        'memberNames': memberNames.map((k, v) => MapEntry(k, v)),
        'lastMessage': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      chatId = ref.id;
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatTitle: teamName,
            chatType: 'team',
          ),
        ),
      );
    }
  }

  // ── チーム作成 ──
  void _showCreateTeamSheet() {
    final nameController = TextEditingController();
    bool isMain = false;

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) => StatefulBuilder(builder: (ctx, setPageState) {
        bool hasInput() => nameController.text.isNotEmpty;

        Future<bool> onWillPop() async {
          if (!hasInput()) return true;
          final result = await showDialog<bool>(
            context: ctx,
            builder: (dlgCtx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('入力内容の破棄'),
              content: const Text('入力した内容が失われますが、よろしいですか？'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dlgCtx, false), child: const Text('編集に戻る')),
                ElevatedButton(onPressed: () => Navigator.pop(dlgCtx, true),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
                  child: const Text('破棄する')),
              ],
            ),
          );
          return result ?? false;
        }

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final shouldPop = await onWillPop();
            if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
          },
          child: Scaffold(
            backgroundColor: AppTheme.backgroundColor,
            appBar: AppBar(
              leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () async {
                final shouldPop = await onWillPop();
                if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
              }),
              title: const Text('新しいチームを作成', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              centerTitle: true,
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('チームを作成してメンバーを招待しましょう', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                const SizedBox(height: 24),
                const Text('チーム名', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                TextField(
                  controller: nameController, maxLength: 20, autofocus: true,
                  onChanged: (_) => setPageState(() {}),
                  decoration: InputDecoration(hintText: '例: サンダース', hintStyle: const TextStyle(color: AppTheme.textHint),
                    filled: true, fillColor: AppTheme.backgroundColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(Icons.star, color: AppTheme.accentColor, size: 22),
                    const SizedBox(width: 12),
                    const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('メインチームに設定', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                      Text('常に一緒に活動する固定チーム', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ])),
                    Switch(value: isMain, onChanged: (v) => setPageState(() => isMain = v), activeColor: AppTheme.accentColor),
                  ]),
                ),
                const SizedBox(height: 32),
                SizedBox(width: double.infinity, child: ElevatedButton(
                  onPressed: nameController.text.trim().isNotEmpty
                      ? () async {
                          final uid = _currentUser!.uid;
                          final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
                          final nickname = (userDoc.data()?['nickname'] ?? '自分').toString();
                          await FirebaseFirestore.instance.collection('teams').add({
                            'name': nameController.text.trim(), 'isMain': isMain, 'ownerId': uid,
                            'memberIds': [uid], 'memberNames': {uid: nickname},
                            'memberAvatars': {uid: userDoc.data()?['avatarUrl'] ?? ''},
                            'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp(),
                          });
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('「${nameController.text.trim()}」を作成しました！'), backgroundColor: AppTheme.success));
                          }
                        } : null,
                  style: ElevatedButton.styleFrom(disabledBackgroundColor: Colors.grey[300],
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: const Text('チームを作成', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                )),
              ]),
            ),
          ),
        );
      }),
    ));
  }

  // ── メンバー招待 ──
  void _showInviteSheet(String teamId, String teamName) {
    final searchCtrl = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];
    final Set<String> selectedIds = {};
    bool searching = false;

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (routeContext) {
        return StatefulBuilder(
          builder: (sheetCtx, setModalState) {
            Future<void> searchFollowing() async {
              setModalState(() => searching = true);
              final snap = await FirebaseFirestore.instance
                  .collection('users')
                  .doc(_currentUser!.uid)
                  .collection('following')
                  .get();

              List<Map<String, dynamic>> results = [];
              for (final doc in snap.docs) {
                final userDoc = await FirebaseFirestore.instance.collection('users').doc(doc.id).get();
                if (userDoc.exists) {
                  final data = userDoc.data()!;
                  data['uid'] = doc.id;
                  final query = searchCtrl.text.toLowerCase();
                  if (query.isEmpty ||
                      (data['nickname'] ?? '').toString().toLowerCase().contains(query)) {
                    results.add(data);
                  }
                }
              }
              setModalState(() {
                searchResults = results;
                searching = false;
              });
            }

            return Scaffold(
              backgroundColor: AppTheme.backgroundColor,
              appBar: AppBar(
                title: const Text('メンバー追加', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                centerTitle: true,
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('「$teamName」にメンバーを招待',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                    const SizedBox(height: 12),

                    // 招待リンク/コードで招待（まだ登録していない人もOK）
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          showInviteShareSheet(
                            context,
                            teamId: teamId,
                            teamName: teamName,
                            title: 'リンク/コードで招待',
                            description: 'まだSofvoに登録していない人も招待できます。リンクとコードを送ると、相手の登録後に「参加リクエスト」が届くので、オーナーが承認するとチームに参加します。',
                          );
                        },
                        icon: const Icon(Icons.link, size: 20),
                        label: const Text('招待リンク/コードで招待（未登録の人もOK）',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryColor,
                          side: const BorderSide(color: AppTheme.primaryColor),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('または、フォローしている人から選択',
                        style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: searchCtrl,
                          decoration: InputDecoration(
                            hintText: 'ニックネームで検索',
                            filled: true, fillColor: AppTheme.backgroundColor,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: searchFollowing,
                        style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                        child: const Text('検索'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (searching)
                    const Center(child: Padding(padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(color: AppTheme.primaryColor)))
                  else if (searchResults.isNotEmpty)
                    SizedBox(
                      height: 250,
                      child: ListView.builder(
                        itemCount: searchResults.length,
                        itemBuilder: (_, i) {
                          final u = searchResults[i];
                          final uid = u['uid'] ?? '';
                          final nick = (u['nickname'] ?? '?').toString();
                          final avatar = (u['avatarUrl'] ?? '').toString();
                          final isSelected = selectedIds.contains(uid);
                          return InkWell(
                            onTap: () {
                              setModalState(() {
                                if (isSelected) {
                                  selectedIds.remove(uid);
                                } else {
                                  selectedIds.add(uid);
                                }
                              });
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isSelected ? AppTheme.primaryColor.withValues(alpha:0.05) : AppTheme.backgroundColor,
                                borderRadius: BorderRadius.circular(12),
                                border: isSelected ? Border.all(color: AppTheme.primaryColor, width: 2) : null,
                              ),
                              child: Row(
                                children: [
                                  avatar.isNotEmpty
                                      ? CircleAvatar(radius: 20, backgroundImage: NetworkImage(avatar))
                                      : CircleAvatar(radius: 20,
                                          backgroundColor: AppTheme.primaryColor.withValues(alpha:0.12),
                                          child: Text(nick[0], style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold))),
                                  const SizedBox(width: 12),
                                  Expanded(child: Text(nick, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
                                  Icon(isSelected ? Icons.check_circle : Icons.circle_outlined,
                                      color: isSelected ? AppTheme.primaryColor : AppTheme.textHint, size: 24),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    )
                  else
                    const Padding(padding: EdgeInsets.all(20),
                        child: Center(child: Text('「検索」を押してフォロー中のユーザーを表示',
                            style: TextStyle(color: AppTheme.textSecondary)))),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: selectedIds.isNotEmpty
                        ? () async {
                            for (final uid in selectedIds) {
                              final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
                              final nick = (userDoc.data()?['nickname'] ?? '?').toString();
                              await FirebaseFirestore.instance.collection('teams').doc(teamId).update({
                                'memberIds': FieldValue.arrayUnion([uid]),
                                'memberNames.$uid': nick,
                                'memberAvatars.$uid': (userDoc.data()?['avatarUrl'] ?? '').toString(),
                              });
                            }
                            if (mounted) {
                              Navigator.of(context).pop();
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text('${selectedIds.length}人をチームに追加しました！'),
                                  backgroundColor: AppTheme.success));
                            }
                          }
                        : null,
                    style: ElevatedButton.styleFrom(disabledBackgroundColor: Colors.grey[300]),
                    child: Text(selectedIds.isNotEmpty ? '${selectedIds.length}人を追加する' : 'メンバーを選択してください',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              ),
            );
          },
        );
      },
    ));
  }

  // ── チーム削除 ──
  void _showDeleteConfirm(String teamId, String teamName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('チームを解散', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Text('「$teamName」を解散しますか？\nこの操作は取り消せません。', style: const TextStyle(height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance.collection('teams').doc(teamId).delete();
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('「$teamName」を解散しました'), backgroundColor: AppTheme.error));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, minimumSize: const Size(100, 40)),
            child: const Text('解散する'),
          ),
        ],
      ),
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('チームの権限について', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHelpItem(Icons.shield, AppTheme.accentColor, 'オーナー', 'チームの全操作が可能。\nメンバー招待・除外、チーム名変更、解散。'),
            const SizedBox(height: 12),
            _buildHelpItem(Icons.admin_panel_settings, AppTheme.info, '副キャプテン', 'メンバー招待が可能。\nオーナーの補佐役。'),
            const SizedBox(height: 12),
            _buildHelpItem(Icons.person, AppTheme.textSecondary, 'メンバー', 'チームに参加している一般メンバー。'),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('閉じる'))],
      ),
    );
  }

  Widget _buildHelpItem(IconData icon, Color color, String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text(desc, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
          ]),
        ),
      ],
    );
  }
}
