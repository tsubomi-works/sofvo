import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';
import '../../services/push_notification_service.dart';
import '../../widgets/empty_state_view.dart';
import '../../widgets/official_badge.dart';
import 'chat_screen.dart';
import 'create_group_chat_screen.dart';
import '../follow/follow_search_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  User? get _currentUser => FirebaseAuth.instance.currentUser;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _showSearchBar = false;
  Set<String> _blockedUserIds = {};
  Set<String> _pinnedChatIds = {};
  Set<String> _hiddenChatIds = {};
  final Map<String, String> _userNameCache = {};
  final Map<String, bool> _officialCache = {};
  final Map<String, String> _userAvatarCache = {};

  @override
  void initState() {
    super.initState();
    // チャット一覧を開いたタイミングで iOS バッジを再同期
    // （フォアグラウンドで受信したプッシュなどで iOS 側のバッジが
    //   実際の未読数とズレているケースをここで補正する）
    PushNotificationService.updateBadgeCount();
    _tabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: const Duration(milliseconds: 200),
    );
    _loadInitialData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    if (_currentUser == null) return;
    final userRef = FirebaseFirestore.instance.collection('users').doc(_currentUser!.uid);
    final results = await Future.wait([
      userRef.collection('blockedUsers').get(),
      userRef.collection('pinnedChats').get(),
      userRef.collection('hiddenChats').get(),
    ]);
    if (mounted) {
      setState(() {
        _blockedUserIds = results[0].docs.map((d) => d.id).toSet();
        _pinnedChatIds = results[1].docs.map((d) => d.id).toSet();
        _hiddenChatIds = results[2].docs.map((d) => d.id).toSet();
      });
    }
  }

  Future<void> _togglePin(String chatId) async {
    if (_currentUser == null) return;
    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .collection('pinnedChats')
        .doc(chatId);
    final wasPinned = _pinnedChatIds.contains(chatId);
    setState(() {
      if (wasPinned) { _pinnedChatIds.remove(chatId); } else { _pinnedChatIds.add(chatId); }
    });
    try {
      if (wasPinned) { await ref.delete(); } else { await ref.set({'pinnedAt': FieldValue.serverTimestamp()}); }
    } catch (e) {
      if (mounted) setState(() {
        if (wasPinned) { _pinnedChatIds.add(chatId); } else { _pinnedChatIds.remove(chatId); }
      });
    }
  }

  Future<void> _toggleHide(String chatId) async {
    if (_currentUser == null) return;
    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .collection('hiddenChats')
        .doc(chatId);
    final wasHidden = _hiddenChatIds.contains(chatId);
    setState(() {
      if (wasHidden) { _hiddenChatIds.remove(chatId); } else { _hiddenChatIds.add(chatId); }
    });
    try {
      if (wasHidden) { await ref.delete(); } else { await ref.set({'hiddenAt': FieldValue.serverTimestamp()}); }
    } catch (e) {
      if (mounted) setState(() {
        if (wasHidden) { _hiddenChatIds.add(chatId); } else { _hiddenChatIds.remove(chatId); }
      });
    }
  }

  Future<void> _deleteChat(String chatId, String type) async {
    if (_currentUser == null) return;
    final myUid = _currentUser!.uid;
    final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);

    if (type == 'dm') {
      // DMの場合: 自分をmembersから除外し、非表示にする
      await chatRef.update({
        'members': FieldValue.arrayRemove([myUid]),
      });
    } else {
      // グループの場合: 自分をmembersから除外
      await chatRef.update({
        'members': FieldValue.arrayRemove([myUid]),
        'memberNames.$myUid': FieldValue.delete(),
      });
    }

    // ピン留め・非表示も削除
    final userRef = FirebaseFirestore.instance.collection('users').doc(myUid);
    await userRef.collection('pinnedChats').doc(chatId).delete();
    await userRef.collection('hiddenChats').doc(chatId).delete();

    if (mounted) {
      setState(() {
        _pinnedChatIds.remove(chatId);
        _hiddenChatIds.remove(chatId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('チャットを削除しました'),
          backgroundColor: AppTheme.success,
        ),
      );
    }
  }

  /// ユーザー名をFirestoreから取得してキャッシュ + memberNamesを修正
  Future<void> _resolveAndCacheName(String chatId, String userId) async {
    if (_userNameCache.containsKey(userId) && _userAvatarCache.containsKey(userId)) return;
    final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final nickname = (doc.data()?['nickname'] as String?) ?? '';
    final avatarUrl = (doc.data()?['avatarUrl'] as String?) ?? '';
    if (mounted) {
      setState(() {
        if (nickname.isNotEmpty) _userNameCache[userId] = nickname;
        _userAvatarCache[userId] = avatarUrl;
        _officialCache[userId] = doc.data()?['isOfficial'] == true;
      });
      if (nickname.isNotEmpty) {
        // Firestoreのチャットドキュメントも修正
        await FirebaseFirestore.instance.collection('chats').doc(chatId).update({
          'memberNames.$userId': nickname,
        });
      }
    }
  }

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

  void _openChat({
    required String chatId,
    required String title,
    required String type,
    String? otherUserId,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatId: chatId,
          chatTitle: title,
          chatType: type,
          otherUserId: otherUserId,
        ),
      ),
    );
  }

  // ── DM作成 or 既存DM取得 ──
  Future<void> _startDmWith(String otherUid, String otherName) async {
    if (_currentUser == null) return;
    final myUid = _currentUser!.uid;

    final existing = await FirebaseFirestore.instance
        .collection('chats')
        .where('type', isEqualTo: 'dm')
        .where('members', arrayContains: myUid)
        .get();

    String? chatId;
    for (final doc in existing.docs) {
      final members = List<String>.from(doc['members'] ?? []);
      if (members.contains(otherUid)) {
        chatId = doc.id;
        break;
      }
    }

    if (chatId == null) {
      final myDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(myUid)
          .get();
      final myName = (myDoc.data()?['nickname'] as String?) ?? '自分';

      final ref =
          await FirebaseFirestore.instance.collection('chats').add({
        'type': 'dm',
        'members': [myUid, otherUid],
        'memberNames': {myUid: myName, otherUid: otherName},
        'lastMessage': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastRead': {myUid: FieldValue.serverTimestamp()},
        'createdAt': FieldValue.serverTimestamp(),
      });
      chatId = ref.id;
    }

    if (mounted) {
      _openChat(
        chatId: chatId,
        title: otherName,
        type: 'dm',
        otherUserId: otherUid,
      );
    }
  }

  // ── 新規DMシート ──
  void _showNewDmSheet() {
    if (_currentUser == null) return;

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (routeContext) {
        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            title: const Text('新しいメッセージ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            centerTitle: true,
          ),
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(_currentUser!.uid)
                .collection('following')
                .snapshots(),
            builder: (context, followSnap) {
              if (followSnap.connectionState ==
                  ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(color: AppTheme.primaryColor));
              }
              final followDocs = followSnap.data?.docs ?? [];
              if (followDocs.isEmpty) {
                return const Center(
                  child: Text('フォロー中のユーザーがいません',
                      style: TextStyle(
                          color: AppTheme.textSecondary)),
                );
              }
              // Resolve missing nicknames, avatars and isOfficial
              for (final doc in followDocs) {
                final data = doc.data() as Map<String, dynamic>? ?? {};
                final nickname = (data['nickname'] as String?) ?? '';
                if (nickname.isNotEmpty) {
                  _userNameCache[doc.id] = nickname;
                }
                if (!_userNameCache.containsKey(doc.id) || !_userAvatarCache.containsKey(doc.id) || !_officialCache.containsKey(doc.id)) {
                  FirebaseFirestore.instance
                      .collection('users')
                      .doc(doc.id)
                      .get()
                      .then((userDoc) {
                    final resolved = (userDoc.data()?['nickname'] as String?) ?? '';
                    final avatarUrl = (userDoc.data()?['avatarUrl'] as String?) ?? '';
                    final isOfficial = userDoc.data()?['isOfficial'] == true;
                    if (mounted) {
                      setState(() {
                        if (resolved.isNotEmpty) _userNameCache[doc.id] = resolved;
                        _userAvatarCache[doc.id] = avatarUrl;
                        _officialCache[doc.id] = isOfficial;
                      });
                      if (resolved.isNotEmpty) {
                        FirebaseFirestore.instance
                            .collection('users')
                            .doc(_currentUser!.uid)
                            .collection('following')
                            .doc(doc.id)
                            .update({'nickname': resolved}).catchError((_) {});
                      }
                    }
                  }).catchError((_) {});
                }
              }
              return ListView.separated(
                itemCount: followDocs.length,
                separatorBuilder: (_, __) => Divider(
                    height: 1, color: Colors.grey[100]),
                itemBuilder: (_, i) {
                  final uid = followDocs[i].id;
                  final name = _userNameCache[uid] ?? 'ユーザー';
                  final avatarUrl = _userAvatarCache[uid] ?? '';
                  return ListTile(
                    leading: avatarUrl.isNotEmpty
                        ? CircleAvatar(
                            radius: 20,
                            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                            backgroundImage: NetworkImage(avatarUrl),
                          )
                        : CircleAvatar(
                            backgroundColor: AppTheme.primaryColor
                                .withValues(alpha: 0.12),
                            child: Text(
                              name.isNotEmpty && name != 'ユーザー' ? name[0] : '?',
                              style: const TextStyle(
                                  color: AppTheme.primaryColor,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                    title: Row(
                        children: [
                          Flexible(child: Text(name,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis)),
                          if (_officialCache[uid] == true) const OfficialBadge(size: 15),
                        ]),
                    onTap: () {
                      Navigator.of(routeContext).pop();
                      _startDmWith(uid, name);
                    },
                  );
                },
              );
            },
          ),
        );
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          // ━━━ 統一ヘッダー ━━━
          Container(
            decoration: BoxDecoration(
              color: AppTheme.backgroundColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  offset: const Offset(0, 1),
                  blurRadius: 3,
                ),
              ],
            ),
            child: Material(
            color: Colors.transparent,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                    const Text('チャット',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                    const Spacer(),
                    // 検索アイコン
                    GestureDetector(
                      onTap: () => setState(() => _showSearchBar = !_showSearchBar),
                      child: Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(
                          color: _showSearchBar ? AppTheme.primaryColor.withValues(alpha: 0.1) : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.search, color: _showSearchBar ? AppTheme.primaryColor : AppTheme.textSecondary, size: 22),
                      ),
                    ),
                    const SizedBox(width: 4),
                    PopupMenuButton<String>(
                      icon: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.add, color: AppTheme.primaryColor, size: 22),
                      ),
                      offset: const Offset(0, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      onSelected: (value) {
                        switch (value) {
                          case 'dm':
                            _showNewDmSheet();
                            break;
                          case 'group':
                            Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const CreateGroupChatScreen()));
                            break;
                          case 'friend':
                            Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const FollowSearchScreen()));
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'dm',
                          child: Row(
                            children: [
                              Icon(Icons.chat_bubble_outline, size: 20, color: AppTheme.textPrimary),
                              const SizedBox(width: 12),
                              const Text('トークルームを作成'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'group',
                          child: Row(
                            children: [
                              Icon(Icons.group_add_outlined, size: 20, color: AppTheme.textPrimary),
                              const SizedBox(width: 12),
                              const Text('グループ作成'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'friend',
                          child: Row(
                            children: [
                              Icon(Icons.person_add_outlined, size: 20, color: AppTheme.textPrimary),
                              const SizedBox(width: 12),
                              const Text('友だち追加'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              ),
              if (_showSearchBar) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    onChanged: (value) => setState(() => _searchQuery = value.trim().toLowerCase()),
                    decoration: InputDecoration(
                      hintText: 'チャットを検索',
                      hintStyle: TextStyle(fontSize: 14, color: AppTheme.textHint),
                      prefixIcon: Icon(Icons.search, color: AppTheme.textHint, size: 20),
                      suffixIcon: GestureDetector(
                        onTap: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _showSearchBar = false;
                          });
                        },
                        child: Icon(Icons.close, color: AppTheme.textHint, size: 18),
                      ),
                      filled: true,
                      fillColor: AppTheme.backgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      isDense: true,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TabBar(
                controller: _tabController,
                labelColor: AppTheme.textPrimary,
                unselectedLabelColor: AppTheme.textSecondary,
                labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
                indicatorColor: AppTheme.primaryColor,
                indicatorWeight: 3,
                dividerColor: Colors.grey[300],
                tabs: const [
                  Tab(text: '個別チャット'),
                  Tab(text: 'グループチャット'),
                ],
              ),
            ]),
          ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _KeepAlivePage(child: _buildChatTab('dm')),
                _KeepAlivePage(child: _buildGroupChatTab()),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // グループチャット（チーム + グループ）
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildGroupChatTab() {
    if (_currentUser == null) {
      return const Center(child: Text('ログインしてください'));
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('members', arrayContains: _currentUser!.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }

        if (snapshot.hasError) {
          debugPrint('Group chat query error: ${snapshot.error}');
          return _buildEmptyForType('group');
        }

        // type == 'group' をDart側でフィルタ（非表示チャット除外）
        final allChats = (snapshot.data?.docs ?? []).where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return data['type'] == 'group' && !_hiddenChatIds.contains(doc.id);
        }).toList();
        // ピン留め優先 → lastMessageAt で降順ソート
        allChats.sort((a, b) {
          final aPinned = _pinnedChatIds.contains(a.id);
          final bPinned = _pinnedChatIds.contains(b.id);
          if (aPinned != bPinned) return aPinned ? -1 : 1;
          final aTime = (a.data() as Map<String, dynamic>)['lastMessageAt'] as Timestamp?;
          final bTime = (b.data() as Map<String, dynamic>)['lastMessageAt'] as Timestamp?;
          if (aTime == null && bTime == null) return 0;
          if (aTime == null) return 1;
          if (bTime == null) return -1;
          return bTime.compareTo(aTime);
        });
        // 検索フィルタ
        final chats = _searchQuery.isEmpty ? allChats : allChats.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final chatName = (data['name'] as String?) ?? '';
          final memberNames = data['memberNames'] as Map<String, dynamic>? ?? {};
          final allNames = memberNames.values.map((v) => v.toString().toLowerCase()).join(' ');
          return chatName.toLowerCase().contains(_searchQuery) || allNames.contains(_searchQuery);
        }).toList();

        if (chats.isEmpty) {
          return _searchQuery.isNotEmpty
              ? EmptyStateView(icon: Icons.search_off, title: '「$_searchQuery」に一致するグループがありません')
              : _buildEmptyForType('group');
        }

        return RefreshIndicator(
          color: AppTheme.primaryColor,
          onRefresh: () async {
            setState(() {});
            await Future.delayed(const Duration(milliseconds: 500));
          },
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: 4, bottom: 92 + MediaQuery.of(context).padding.bottom),
            itemCount: chats.length,
            separatorBuilder: (_, __) => Divider(
                height: 1, thickness: 1, color: Colors.grey[100], indent: 80),
            itemBuilder: (context, index) {
              final data = chats[index].data() as Map<String, dynamic>;
              final chatId = chats[index].id;
              final type = (data['type'] as String?) ?? 'team';
              return _buildFirestoreChatTile(chatId, data, type);
            },
          ),
        );
      },
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // Firestoreからチャット一覧を取得
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildChatTab(String type) {
    if (_currentUser == null) {
      return const Center(child: Text('ログインしてください'));
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('members', arrayContains: _currentUser!.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
              child:
                  CircularProgressIndicator(color: AppTheme.primaryColor));
        }

        if (snapshot.hasError) {
          debugPrint('Chat query error ($type): ${snapshot.error}');
          return _buildEmptyForType(type);
        }

        // type フィルタをDart側で適用（非表示チャット除外）
        final allChats = (snapshot.data?.docs ?? []).where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return data['type'] == type && !_hiddenChatIds.contains(doc.id);
        }).toList();
        // ピン留め優先 → lastMessageAt で降順ソート
        allChats.sort((a, b) {
          final aPinned = _pinnedChatIds.contains(a.id);
          final bPinned = _pinnedChatIds.contains(b.id);
          if (aPinned != bPinned) return aPinned ? -1 : 1;
          final aTime = (a.data() as Map<String, dynamic>)['lastMessageAt'] as Timestamp?;
          final bTime = (b.data() as Map<String, dynamic>)['lastMessageAt'] as Timestamp?;
          if (aTime == null && bTime == null) return 0;
          if (aTime == null) return 1;
          if (bTime == null) return -1;
          return bTime.compareTo(aTime);
        });
        // ブロックユーザーフィルタ & 検索フィルタ
        final chats = allChats.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          // ブロックチェック（DM のみ）
          if (type == 'dm' && _blockedUserIds.isNotEmpty) {
            final members = List<String>.from(data['members'] ?? []);
            if (members.any((m) => _blockedUserIds.contains(m) && m != _currentUser!.uid)) {
              return false;
            }
          }
          // 検索フィルタ
          if (_searchQuery.isNotEmpty) {
            final memberNames = data['memberNames'] as Map<String, dynamic>? ?? {};
            final chatName = (data['name'] as String?) ?? '';
            final allNames = memberNames.values.map((v) => v.toString().toLowerCase()).join(' ');
            return allNames.contains(_searchQuery) || chatName.toLowerCase().contains(_searchQuery);
          }
          return true;
        }).toList();

        if (chats.isEmpty) {
          return _searchQuery.isNotEmpty
              ? EmptyStateView(icon: Icons.search_off, title: '「$_searchQuery」に一致するチャットがありません')
              : _buildEmptyForType(type);
        }

        return RefreshIndicator(
          color: AppTheme.primaryColor,
          onRefresh: () async {
            setState(() {});
            await Future.delayed(const Duration(milliseconds: 500));
          },
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: 4, bottom: 92 + MediaQuery.of(context).padding.bottom),
            itemCount: chats.length,
            separatorBuilder: (_, __) => Divider(
                height: 1, thickness: 1, color: Colors.grey[100], indent: 80),
            itemBuilder: (context, index) {
              final data = chats[index].data() as Map<String, dynamic>;
              final chatId = chats[index].id;
              return _buildFirestoreChatTile(chatId, data, type);
            },
          ),
        );
      },
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 未読判定
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  bool _hasUnread(Map<String, dynamic> data) {
    if (_currentUser == null) return false;
    final uid = _currentUser!.uid;
    // lastRead vs lastMessageAt のタイムスタンプ比較で判定（最も確実）
    final lastReadMap = data['lastRead'] as Map<String, dynamic>? ?? {};
    final myLastRead = lastReadMap[uid] as Timestamp?;
    final lastMessageAt = data['lastMessageAt'] as Timestamp?;
    if (lastMessageAt == null) return false;
    if (myLastRead == null) return true;
    return lastMessageAt.toDate().isAfter(myLastRead.toDate());
  }

  Widget _buildFirestoreChatTile(
      String chatId, Map<String, dynamic> data, String type) {
    final memberNames =
        data['memberNames'] as Map<String, dynamic>? ?? {};
    final lastMessage = (data['lastMessage'] as String?) ?? '';
    final lastAt = data['lastMessageAt'] as Timestamp?;
    final timeText = _formatTime(lastAt);
    final unread = _hasUnread(data);
    final unreadCountMap = data['unreadCount'] as Map<String, dynamic>? ?? {};
    final rawUnread = unreadCountMap[_currentUser!.uid];
    final unreadNum = (rawUnread is int) ? rawUnread : (rawUnread is num) ? rawUnread.toInt() : 0;

    String title;
    String? otherUserId;
    if (type == 'dm') {
      final members = List<String>.from(data['members'] ?? []);
      otherUserId = members.firstWhere(
        (m) => m != _currentUser!.uid,
        orElse: () => '',
      );
      final otherEntry = memberNames.entries.firstWhere(
        (e) => e.key != _currentUser!.uid,
        orElse: () => MapEntry('', 'ユーザー'),
      );
      title = (otherEntry.value as String).isNotEmpty
          ? otherEntry.value as String
          : 'ユーザー';
      // 非同期で名前とアバターを解決
      if (otherUserId.isNotEmpty) {
        _resolveAndCacheName(chatId, otherUserId);
        if (title == 'ユーザー') {
          title = _userNameCache[otherUserId] ?? 'ユーザー';
        }
      }
      // isOfficial をキャッシュ確認・取得
      if (otherUserId.isNotEmpty && !_officialCache.containsKey(otherUserId)) {
        _checkOfficial(otherUserId);
      }
    } else {
      title = (data['name'] as String?) ?? 'チャット';
    }

    final isOfficial = otherUserId != null && otherUserId.isNotEmpty && _officialCache[otherUserId] == true;
    final initial = title.isNotEmpty ? title[0] : '?';

    IconData icon;
    Color iconColor;
    if (type == 'team') {
      icon = Icons.groups;
      iconColor = AppTheme.success;
    } else if (type == 'group') {
      icon = Icons.group;
      iconColor = AppTheme.primaryColor;
    } else if (type == 'tournament') {
      icon = Icons.emoji_events;
      iconColor = AppTheme.accentColor;
    } else {
      icon = Icons.person;
      iconColor = AppTheme.primaryColor;
    }

    final isPinned = _pinnedChatIds.contains(chatId);

    final dmAvatarUrl = (type == 'dm' && otherUserId != null && otherUserId.isNotEmpty)
        ? (_userAvatarCache[otherUserId] ?? '')
        : '';

    Widget avatarWidget = type == 'dm'
        ? (dmAvatarUrl.isNotEmpty
            ? CircleAvatar(
                radius: 24,
                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                backgroundImage: NetworkImage(dmAvatarUrl),
              )
            : CircleAvatar(
                radius: 24,
                backgroundColor:
                    AppTheme.primaryColor.withValues(alpha: 0.12),
                child: Text(initial,
                    style: const TextStyle(
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ))
        : _buildGroupLeading(data, icon, iconColor);

    if (isPinned) {
      avatarWidget = Stack(
        clipBehavior: Clip.none,
        children: [
          avatarWidget,
          Positioned(
            bottom: -2,
            right: -2,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: AppTheme.textSecondary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const Icon(Icons.push_pin, size: 10, color: Colors.white),
            ),
          ),
        ],
      );
    }

    return Container(
      color: unread
          ? AppTheme.primaryColor.withValues(alpha: 0.02)
          : Colors.white,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        onLongPress: () => _showChatMenu(chatId, isPinned, type),
        leading: avatarWidget,
        title: Row(
            children: [
              Flexible(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: unread ? FontWeight.bold : FontWeight.w600,
                        color: AppTheme.textPrimary),
                    overflow: TextOverflow.ellipsis),
              ),
              if (isOfficial) const OfficialBadge(size: 15),
            ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            lastMessage.isEmpty ? 'メッセージはありません' : lastMessage,
            style: TextStyle(
                fontSize: 13,
                color: unread ? AppTheme.textPrimary : AppTheme.textSecondary,
                fontWeight: unread ? FontWeight.w500 : FontWeight.normal),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(timeText,
                style: TextStyle(
                    fontSize: 12,
                    color: unread
                        ? AppTheme.primaryColor
                        : AppTheme.textHint)),
            const SizedBox(height: 4),
            if (unread)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                child: Text(
                  unreadNum > 99 ? '99+' : '${unreadNum > 0 ? unreadNum : 1}',
                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold, height: 1.1),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
        onTap: () {
          String? otherUserId;
          if (type == 'dm') {
            final members =
                List<String>.from(data['members'] ?? []);
            otherUserId = members.firstWhere(
              (m) => m != _currentUser!.uid,
              orElse: () => '',
            );
          }
          _openChat(
            chatId: chatId,
            title: title,
            type: type,
            otherUserId: otherUserId,
          );
        },
      ),
    );
  }

  void _showChatMenu(String chatId, bool isPinned, String type) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                color: AppTheme.primaryColor,
              ),
              title: Text(isPinned ? 'ピン留めを解除' : 'ピン留め'),
              onTap: () {
                Navigator.pop(ctx);
                _togglePin(chatId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined, color: AppTheme.textSecondary),
              title: const Text('非表示'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleHide(chatId);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('チャットを非表示にしました'),
                    backgroundColor: AppTheme.primaryColor,
                    action: SnackBarAction(
                      label: '元に戻す',
                      textColor: Colors.white,
                      onPressed: () => _toggleHide(chatId),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.error),
              title: const Text('削除', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteChat(chatId, type);
              },
            ),
          ]),
        ),
      ),
    );
  }

  void _confirmDeleteChat(String chatId, String type) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('チャットを削除'),
        content: Text(
          type == 'dm'
              ? 'このトークルームを削除しますか？\nメッセージ履歴は相手側には残ります。'
              : 'このグループから退出しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteChat(chatId, type);
            },
            child: const Text('削除', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupLeading(Map<String, dynamic> data, IconData icon, Color iconColor) {
    final iconUrl = data['iconUrl'] as String? ?? '';
    if (iconUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 24,
        backgroundImage: NetworkImage(iconUrl),
        backgroundColor: iconColor.withValues(alpha: 0.15),
      );
    }
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: iconColor, size: 24),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 空状態表示
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildEmptyForType(String type) {
    if (type == 'dm') {
      return EmptyStateView(
        icon: Icons.chat_bubble_outline,
        title: 'まだDMはありません',
        actions: [EmptyStateAction(label: '新しいメッセージを送る', icon: Icons.edit, onPressed: _showNewDmSheet)],
      );
    } else if (type == 'group') {
      return EmptyStateView(
        icon: Icons.groups_outlined,
        title: 'グループチャットはありません',
        actions: [EmptyStateAction(label: 'グループを作成', icon: Icons.edit, onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const CreateGroupChatScreen())))],
      );
    } else if (type == 'team') {
      return const EmptyStateView(
        icon: Icons.groups_outlined,
        title: 'チームチャットはありません\nチーム管理画面からチャットを開始できます',
      );
    } else {
      return const EmptyStateView(
        icon: Icons.emoji_events_outlined,
        title: '大会チャットはありません\n大会詳細画面からチャットを開始できます',
      );
    }
  }

  String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final now = DateTime.now();
    final date = timestamp.toDate();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'たった今';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 2) return '昨日';
    return '${date.month}/${date.day}';
  }
}

class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});
  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
