import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import '../../config/app_theme.dart';
import '../../services/media_service.dart';
import '../../widgets/official_badge.dart';
import 'chat_screen.dart';

class CreateGroupChatScreen extends StatefulWidget {
  const CreateGroupChatScreen({super.key});

  @override
  State<CreateGroupChatScreen> createState() => _CreateGroupChatScreenState();
}

class _CreateGroupChatScreenState extends State<CreateGroupChatScreen> {
  User? get _currentUser => FirebaseAuth.instance.currentUser;
  final _searchController = TextEditingController();
  final _groupNameController = TextEditingController();
  final _picker = ImagePicker();

  // Step management: 0 = select members, 1 = set group info
  int _currentStep = 0;

  // Step 1 state
  final Map<String, String> _selectedMembers = {}; // uid -> nickname
  String _searchQuery = '';
  final Map<String, String> _nameCache = {}; // uid -> resolved nickname
  final Map<String, bool> _officialCache = {}; // uid -> isOfficial

  // Step 2 state
  Uint8List? _pickedImageBytes;
  String? _pickedImageName;
  bool _isCreating = false;

  @override
  void dispose() {
    _searchController.dispose();
    _groupNameController.dispose();
    super.dispose();
  }

  // ── Step 1: Toggle member selection ──
  void _toggleMember(String uid, String nickname) {
    setState(() {
      if (_selectedMembers.containsKey(uid)) {
        _selectedMembers.remove(uid);
      } else {
        _selectedMembers[uid] = nickname;
      }
    });
  }

  // ── Step 2: Pick group icon ──
  Future<void> _pickGroupIcon() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
    );
    if (picked == null || !mounted) return;

    // クロップUIを表示
    final bytes = await MediaService.cropIconImage(picked, context);
    if (bytes == null || !mounted) return;

    setState(() {
      _pickedImageBytes = bytes;
      _pickedImageName = picked.name;
    });
  }

  // ── Create group chat ──
  Future<void> _createGroupChat() async {
    if (_currentUser == null) return;

    final groupName = _groupNameController.text.trim();
    if (groupName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('グループ名を入力してください'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      final myUid = _currentUser!.uid;

      // Get current user's nickname
      final myDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(myUid)
          .get();
      final myName = (myDoc.data()?['nickname'] as String?) ?? '自分';

      // Build members list (selected + current user)
      final memberIds = <String>[myUid, ..._selectedMembers.keys];
      final memberNames = <String, String>{
        myUid: myName,
        ..._selectedMembers,
      };

      // Upload icon if selected
      String iconUrl = '';
      if (_pickedImageBytes != null) {
        final fileName =
            '${DateTime.now().millisecondsSinceEpoch}_${_pickedImageName ?? 'icon.jpg'}';
        final ref = FirebaseStorage.instance
            .ref()
            .child('group_icons')
            .child(fileName);

        await ref.putData(
          _pickedImageBytes!,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        iconUrl = await ref.getDownloadURL();
      }

      // Create Firestore document
      final chatRef = await FirebaseFirestore.instance.collection('chats').add({
        'type': 'group',
        'name': groupName,
        'iconUrl': iconUrl,
        'members': memberIds,
        'memberNames': memberNames,
        'createdBy': myUid,
        'lastMessage': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastRead': {myUid: FieldValue.serverTimestamp()},
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        // Replace entire navigation stack with ChatScreen
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              chatId: chatRef.id,
              chatTitle: groupName,
              chatType: 'group',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('グループの作成に失敗しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  // ── Navigate between steps ──
  void _goToStep2() {
    if (_selectedMembers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('メンバーを1人以上選択してください'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    setState(() => _currentStep = 1);
  }

  void _goBackToStep1() {
    setState(() => _currentStep = 0);
  }

  @override
  Widget build(BuildContext context) {
    return _currentStep == 0 ? _buildStep1() : _buildStep2();
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // Step 1: メンバーを選択
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildStep1() {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('メンバーを選択'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _selectedMembers.isNotEmpty ? _goToStep2 : null,
              child: Text(
                '次へ (${_selectedMembers.length})',
                style: TextStyle(
                  color: _selectedMembers.isNotEmpty
                      ? Colors.white
                      : Colors.white54,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Selected members chips ──
          if (_selectedMembers.isNotEmpty)
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _selectedMembers.entries.map((entry) {
                    final initial =
                        entry.value.isNotEmpty ? entry.value[0] : '?';
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => _toggleMember(entry.key, entry.value),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              children: [
                                CircleAvatar(
                                  radius: 22,
                                  backgroundColor: AppTheme.primaryColor
                                      .withValues(alpha: 0.12),
                                  child: Text(
                                    initial,
                                    style: const TextStyle(
                                      color: AppTheme.primaryColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: -2,
                                  right: -2,
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: AppTheme.textSecondary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: Colors.white, width: 1.5),
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 11,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 48,
                              child: Text(
                                entry.value,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          // ── Search bar ──
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.backgroundColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '名前で検索',
                  hintStyle: TextStyle(color: AppTheme.textHint, fontSize: 14),
                  prefixIcon:
                      Icon(Icons.search, size: 20, color: AppTheme.textHint),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
                onChanged: (value) {
                  setState(() => _searchQuery = value.trim().toLowerCase());
                },
              ),
            ),
          ),

          Divider(height: 1, color: Colors.grey[200]),

          // ── Following list ──
          Expanded(
            child: _currentUser == null
                ? const Center(child: Text('ログインしてください'))
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('users')
                        .doc(_currentUser!.uid)
                        .collection('following')
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(
                              color: AppTheme.primaryColor),
                        );
                      }

                      final followDocs = snapshot.data?.docs ?? [];
                      if (followDocs.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.people_outline,
                                  size: 56,
                                  color: AppTheme.primaryColor
                                      .withValues(alpha: 0.3)),
                              const SizedBox(height: 12),
                              const Text(
                                'フォロー中のユーザーがいません',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      // Resolve missing nicknames from users collection
                      for (final doc in followDocs) {
                        final data = doc.data() as Map<String, dynamic>? ?? {};
                        final nickname = (data['nickname'] as String?) ?? '';
                        if (nickname.isNotEmpty) {
                          _nameCache[doc.id] = nickname;
                        }
                        if (!_nameCache.containsKey(doc.id) || !_officialCache.containsKey(doc.id)) {
                          // Fetch from users collection
                          if (!_officialCache.containsKey(doc.id)) {
                            FirebaseFirestore.instance
                                .collection('users')
                                .doc(doc.id)
                                .get()
                                .then((userDoc) {
                              final name = (userDoc.data()?['nickname'] as String?) ?? '';
                              final isOfficial = userDoc.data()?['isOfficial'] == true;
                              if (mounted) {
                                setState(() {
                                  if (name.isNotEmpty) _nameCache[doc.id] = name;
                                  _officialCache[doc.id] = isOfficial;
                                });
                                if (name.isNotEmpty) {
                                  FirebaseFirestore.instance
                                      .collection('users')
                                      .doc(_currentUser!.uid)
                                      .collection('following')
                                      .doc(doc.id)
                                      .update({'nickname': name}).catchError((_) {});
                                }
                              }
                            }).catchError((_) {});
                          }
                        }
                      }

                      // Filter by search query
                      final filteredDocs = followDocs.where((doc) {
                        if (_searchQuery.isEmpty) return true;
                        final name = (_nameCache[doc.id] ?? '').toLowerCase();
                        return name.contains(_searchQuery);
                      }).toList();

                      if (filteredDocs.isEmpty) {
                        return const Center(
                          child: Text(
                            '該当するユーザーが見つかりません',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        );
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.only(top: 4),
                        itemCount: filteredDocs.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: Colors.grey[100], indent: 72),
                        itemBuilder: (_, index) {
                          final doc = filteredDocs[index];
                          final uid = doc.id;
                          final nickname = _nameCache[uid] ?? 'ユーザー';
                          final isSelected = _selectedMembers.containsKey(uid);
                          final initial =
                              nickname.isNotEmpty && nickname != 'ユーザー' ? nickname[0] : '?';

                          return Container(
                            color: Colors.white,
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 4),
                              leading: CircleAvatar(
                                radius: 22,
                                backgroundColor: AppTheme.primaryColor
                                    .withValues(alpha: 0.12),
                                child: Text(
                                  initial,
                                  style: const TextStyle(
                                    color: AppTheme.primaryColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      nickname,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textPrimary,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (_officialCache[uid] == true)
                                    const OfficialBadge(size: 15),
                                ],
                              ),
                              trailing: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppTheme.primaryColor
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected
                                        ? AppTheme.primaryColor
                                        : AppTheme.textHint,
                                    width: 2,
                                  ),
                                ),
                                child: isSelected
                                    ? const Icon(
                                        Icons.check,
                                        size: 16,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                              onTap: () => _toggleMember(uid, nickname),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // Step 2: グループ作成
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Widget _buildStep2() {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('グループ作成'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _goBackToStep1,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _isCreating ? null : _createGroupChat,
              child: Text(
                '作成',
                style: TextStyle(
                  color: _isCreating ? Colors.white54 : Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: _isCreating
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppTheme.primaryColor),
                  SizedBox(height: 16),
                  Text(
                    'グループを作成中...',
                    style: TextStyle(
                      fontSize: 15,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 32),

                  // ── Group icon picker ──
                  Center(
                    child: GestureDetector(
                      onTap: _pickGroupIcon,
                      child: Stack(
                        children: [
                          _pickedImageBytes != null
                              ? CircleAvatar(
                                  radius: 50,
                                  backgroundImage:
                                      MemoryImage(_pickedImageBytes!),
                                  backgroundColor: AppTheme.primaryColor
                                      .withValues(alpha: 0.12),
                                )
                              : CircleAvatar(
                                  radius: 50,
                                  backgroundColor: AppTheme.primaryColor
                                      .withValues(alpha: 0.12),
                                  child: const Icon(
                                    Icons.groups,
                                    size: 40,
                                    color: AppTheme.primaryColor,
                                  ),
                                ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppTheme.primaryColor,
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 2),
                              ),
                              child: const Icon(
                                Icons.camera_alt,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Group name input ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: TextField(
                        controller: _groupNameController,
                        style: const TextStyle(
                            fontSize: 16, color: AppTheme.textPrimary),
                        decoration: const InputDecoration(
                          hintText: 'グループ名を入力',
                          hintStyle:
                              TextStyle(color: AppTheme.textHint, fontSize: 15),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // ── Selected members section ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'メンバー (${_selectedMembers.length}人)',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Member avatars grid ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[200]!),
                      ),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children:
                            _selectedMembers.entries.map((entry) {
                          final initial =
                              entry.value.isNotEmpty ? entry.value[0] : '?';
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: AppTheme.primaryColor
                                    .withValues(alpha: 0.12),
                                child: Text(
                                  initial,
                                  style: const TextStyle(
                                    color: AppTheme.primaryColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: 56,
                                child: Text(
                                  entry.value,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textSecondary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // ── Create button ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _isCreating ? null : _createGroupChat,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('グループを作成'),
                      ),
                    ),
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
}
