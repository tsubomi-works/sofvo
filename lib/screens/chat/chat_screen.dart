import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/app_theme.dart';
import 'package:flutter/gestures.dart';
import '../../widgets/official_badge.dart';
import '../../widgets/link_preview_widget.dart';
import '../../utils/in_app_link.dart';
import '../profile/user_profile_screen.dart';
import 'group_chat_settings_screen.dart';
import '../../services/push_notification_service.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  final String chatType;
  final String? otherUserId;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    required this.chatType,
    this.otherUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _currentUser = FirebaseAuth.instance.currentUser;
  final _picker = ImagePicker();
  bool _isSending = false;
  bool _isMuted = false;
  bool _showQuickReplies = false;
  Map<String, dynamic> _lastReadMap = {};
  List<String> _memberIds = [];
  Map<String, String> _memberNames = {};
  Map<String, String> _memberAvatars = {};
  String _groupIconUrl = '';
  int _previousMessageCount = 0;
  String _resolvedTitle = '';
  final _officialCache = <String, bool>{};
  String _otherUserAvatarUrl = '';
  Timestamp? _myLastReadBefore; // 画面を開いた時点のlastRead（未読境界用）
  bool _initialScrollDone = false;

  /// 公式アカウント（チャットボット）のUID
  static const String _officialUid = 'zlBy8aWUlCYjyy0NUU9HidrQu983';
  bool _isAdmin = false; // 現在ユーザーが管理者(isAdmin)か
  bool _isOfficialAccount = false; // 現在ユーザーが公式アカウント(isOfficial)か
  bool _chatbotEnabled = true; // このDMでボット自動返信が有効か（未設定＝有効）

  bool get _isDm => widget.chatType == 'dm';

  /// ボット自動返信のオンオフを操作できるか。
  /// ・公式アカウント本人（ボット運用者。UID一致 or isOfficial フラグ）
  /// ・管理者(isAdmin)
  /// のいずれかで、かつ公式アカウントが関わるDMのとき操作可能。
  bool get _canToggleBot =>
      _isDm &&
      (_isOfficialAccount ||
          _isAdmin ||
          _currentUser?.uid == _officialUid ||
          widget.otherUserId == _officialUid);

  late final Stream<QuerySnapshot> _messagesStream;
  StreamSubscription<DocumentSnapshot>? _chatDocSubscription;

  @override
  void initState() {
    super.initState();
    _resolvedTitle = widget.chatTitle;
    WidgetsBinding.instance.addObserver(this);
    _loadLastReadAndMarkAsRead();
    _loadMuteState();
    // 公式アカウントDMの場合、クイックリプライを表示
    if (widget.chatType == 'dm' && widget.otherUserId == 'zlBy8aWUlCYjyy0NUU9HidrQu983') {
      _checkShowQuickReplies();
    }
    // ボット自動返信トグルの表示判定のため、DMなら権限（管理者/公式）を読み込む
    if (_isDm) _loadAdminStatus();

    // メッセージストリームを一度だけ生成（再生成による無限ローディングを防止）
    _messagesStream = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .snapshots();

    // チャットドキュメントの変更をリスナーで監視（StreamBuilder外で処理）
    _chatDocSubscription = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .snapshots()
        .listen((chatSnap) {
      if (chatSnap.exists && mounted) {
        final chatData = chatSnap.data() ?? {};
        setState(() {
          _lastReadMap = (chatData['lastRead'] as Map<String, dynamic>?) ?? {};
          _memberIds = List<String>.from(chatData['members'] ?? _memberIds);
          _memberNames = Map<String, String>.from(
            (chatData['memberNames'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, v.toString()),
            ) ?? {},
          );
          _groupIconUrl = (chatData['iconUrl'] as String?) ?? _groupIconUrl;
          // 未設定は「有効」（既存DMの後方互換）。false のときだけ自動返信オフ
          _chatbotEnabled = chatData['chatbotEnabled'] != false;
        });
        // DMの場合、相手の名前とアバターを解決
        if (widget.chatType == 'dm') {
          _resolveDmTitle();
          _resolveDmAvatar();
        }
      }
    });
  }

  /// DMの相手の名前をmemberNamesまたはusersコレクションから取得
  Future<void> _resolveDmTitle() async {
    if (_currentUser == null) return;
    final myUid = _currentUser!.uid;

    // memberNamesから取得を試みる
    final otherEntry = _memberNames.entries.where((e) => e.key != myUid);
    if (otherEntry.isNotEmpty && otherEntry.first.value.isNotEmpty && otherEntry.first.value != 'ユーザー') {
      if (mounted && _resolvedTitle != otherEntry.first.value) {
        setState(() => _resolvedTitle = otherEntry.first.value);
      }
      return;
    }

    // memberNamesにない場合、usersコレクションから取得
    final otherUid = _memberIds.firstWhere((id) => id != myUid, orElse: () => '');
    if (otherUid.isEmpty) return;

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(otherUid).get();
    final nickname = (userDoc.data()?['nickname'] as String?) ?? '';
    if (nickname.isNotEmpty && mounted) {
      setState(() => _resolvedTitle = nickname);
      // memberNamesも修正
      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({
        'memberNames.$otherUid': nickname,
      });
    }
  }

  /// このチャットが公式アカウント（チャットボット）とのDMか。
  /// ユーザー側から見た場合（相手が公式）も、公式アカウント運用者側から見た場合
  /// （自分が公式）も対象にする。
  bool get _isBotDm =>
      _isDm &&
      (widget.otherUserId == _officialUid ||
          _currentUser?.uid == _officialUid ||
          _isOfficialAccount);

  /// 現在ユーザーの権限（管理者 / 公式アカウント）を読み込む（ボット自動返信トグルの表示判定用）。
  /// ローカルの古いキャッシュ（isAdmin 付与前など）を避けるため、まずサーバーから読む。
  /// サーバーが不通のときだけキャッシュにフォールバックする。
  Future<void> _loadAdminStatus() async {
    if (_currentUser == null) return;
    final ref = FirebaseFirestore.instance.collection('users').doc(_currentUser!.uid);
    Map<String, dynamic>? data;
    try {
      data = (await ref.get(const GetOptions(source: Source.server))).data();
    } catch (_) {
      try {
        data = (await ref.get()).data(); // フォールバック（オフライン等）
      } catch (_) {
        return;
      }
    }
    if (!mounted || data == null) return;
    final admin = data['isAdmin'] == true;
    final official = data['isOfficial'] == true;
    if (admin != _isAdmin || official != _isOfficialAccount) {
      setState(() {
        _isAdmin = admin;
        _isOfficialAccount = official;
      });
    }
  }

  /// このDMのボット自動返信をオン/オフする（管理者のみ）。
  /// chats/{chatId}.chatbotEnabled を書き換え、サーバー側トリガーが参照する。
  Future<void> _toggleChatbot() async {
    final next = !_chatbotEnabled;
    setState(() => _chatbotEnabled = next); // 楽観的更新（リスナーで確定）
    try {
      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({
        'chatbotEnabled': next,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next ? 'ボットの自動返信をオンにしました' : 'ボットの自動返信をオフにしました（運営が手動で対応）'),
            backgroundColor: next ? AppTheme.success : AppTheme.textSecondary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _chatbotEnabled = !next); // 失敗したら戻す
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('切り替えに失敗しました'), backgroundColor: AppTheme.error),
        );
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

  /// DMの相手のアバターURLを取得
  Future<void> _resolveDmAvatar() async {
    if (_currentUser == null) return;
    final otherUid = _memberIds.firstWhere((id) => id != _currentUser!.uid, orElse: () => '');
    if (otherUid.isEmpty) return;
    if (_memberAvatars.containsKey(otherUid) && _memberAvatars[otherUid]!.isNotEmpty) {
      if (mounted && _otherUserAvatarUrl != _memberAvatars[otherUid]) {
        setState(() => _otherUserAvatarUrl = _memberAvatars[otherUid]!);
      }
      return;
    }
    final userDoc = await FirebaseFirestore.instance.collection('users').doc(otherUid).get();
    final avatarUrl = (userDoc.data()?['avatarUrl'] as String?) ?? '';
    if (mounted && avatarUrl.isNotEmpty) {
      setState(() {
        _otherUserAvatarUrl = avatarUrl;
        _memberAvatars[otherUid] = avatarUrl;
      });
    }
  }

  /// メッセージ送信者のアバターURLを取得（グループチャット用）
  Future<void> _resolveSenderAvatar(String senderId) async {
    if (_memberAvatars.containsKey(senderId)) return;
    final userDoc = await FirebaseFirestore.instance.collection('users').doc(senderId).get();
    final avatarUrl = (userDoc.data()?['avatarUrl'] as String?) ?? '';
    if (mounted) {
      setState(() => _memberAvatars[senderId] = avatarUrl);
    }
  }

  @override
  void dispose() {
    _chatDocSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _markAsRead();
  }

  /// 画面を開いた時点のlastReadを保存してから既読にする
  Future<void> _loadLastReadAndMarkAsRead() async {
    if (_currentUser == null) return;
    try {
      final chatDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .get();
      if (chatDoc.exists) {
        final data = chatDoc.data() ?? {};
        final lastReadMap = (data['lastRead'] as Map<String, dynamic>?) ?? {};
        final myLastRead = lastReadMap[_currentUser!.uid];
        if (myLastRead is Timestamp) {
          _myLastReadBefore = myLastRead;
        }
      }
    } catch (_) {}
    _markAsRead();
  }

  void _markAsRead() {
    if (_currentUser == null) return;
    // Firestore の書き込み完了を待ってからバッジを再計算する。
    // fire-and-forget で updateBadgeCount を呼ぶと、.get() が
    // update 前の値を読み取って iOS バッジが古い値のまま残る
    // （アプリ内は real-time stream なので正しい値になるが、
    //   iOS ネイティブバッジは updateBadgeCount の結果に依存する）。
    FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({
      'lastRead.${_currentUser!.uid}': FieldValue.serverTimestamp(),
      'unreadCount.${_currentUser!.uid}': 0,
    }).then((_) {
      // アプリアイコンバッジを未読数に合わせて更新
      PushNotificationService.updateBadgeCount();
    });
  }

  Future<void> _loadMuteState() async {
    if (_currentUser == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .collection('mutedChats')
        .doc(widget.chatId)
        .get();
    if (mounted) setState(() => _isMuted = doc.exists);
  }

  Future<void> _toggleMute() async {
    if (_currentUser == null) return;
    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .collection('mutedChats')
        .doc(widget.chatId);

    final wasMuted = _isMuted;
    setState(() => _isMuted = !_isMuted);

    try {
      if (wasMuted) {
        await ref.delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('通知をオンにしました'), backgroundColor: AppTheme.success),
          );
        }
      } else {
        await ref.set({'mutedAt': FieldValue.serverTimestamp()});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('このチャットの通知をオフにしました'), backgroundColor: AppTheme.warning),
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isMuted = wasMuted);
    }
  }

  Future<void> _checkShowQuickReplies() async {
    // 初回は自動表示
    final msgs = await FirebaseFirestore.instance
        .collection('chats').doc(widget.chatId)
        .collection('messages').limit(1).get();
    if (mounted && msgs.docs.isEmpty) {
      setState(() => _showQuickReplies = true);
    }
  }

  void _sendQuickReply(String text) {
    _messageController.text = text;
    _sendMessage();
    setState(() => _showQuickReplies = false);
  }

  Widget _buildQuickReplies() {
    final options = [
      ('使い方を知りたい', Icons.help_outline, AppTheme.primaryColor),
      ('バグ・不具合を報告', Icons.bug_report_outlined, AppTheme.error),
      ('機能の改善要望', Icons.lightbulb_outline, AppTheme.warning),
      ('その他の質問', Icons.chat_outlined, AppTheme.success),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
            ),
            child: const Text(
              'こんにちは！Sofvoサポートです。\nお困りのことを選んでください：',
              style: TextStyle(fontSize: 14, height: 1.5, color: AppTheme.textPrimary),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((opt) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _sendQuickReply(opt.$1),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: opt.$3.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: opt.$3.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(opt.$2, size: 16, color: opt.$3),
                        const SizedBox(width: 6),
                        Text(opt.$1, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: opt.$3)),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _currentUser == null) return;

    final savedText = text;
    _messageController.clear();

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .get();
      final senderName =
          (userDoc.data()?['nickname'] as String?) ?? '自分';

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
        'senderId': _currentUser!.uid,
        'senderName': senderName,
        'type': 'text',
        'text': savedText,
        'createdAt': FieldValue.serverTimestamp(),
      });

      final chatUpdate = <String, dynamic>{
        'lastMessage': savedText,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSenderId': _currentUser!.uid,
        'lastRead.${_currentUser!.uid}': FieldValue.serverTimestamp(),
        'unreadCount.${_currentUser!.uid}': 0,
      };
      for (final memberId in _memberIds) {
        if (memberId == _currentUser!.uid) continue;
        chatUpdate['unreadCount.$memberId'] = FieldValue.increment(1);
      }
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .update(chatUpdate);

      _scrollToBottom();
    } catch (e) {
      // 送信失敗時にテキストを復元
      _messageController.text = savedText;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('メッセージの送信に失敗しました: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _sendImage() async {
    if (_currentUser == null) return;

    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (picked == null) return;
      if (!mounted) return;

      setState(() => _isSending = true);

      final bytes = await picked.readAsBytes();
      if (bytes.length > 5 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('画像サイズが5MBを超えています'),
              backgroundColor: AppTheme.warning,
            ),
          );
          setState(() => _isSending = false);
        }
        return;
      }
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      final ref = FirebaseStorage.instance
          .ref()
          .child('chat_images')
          .child(widget.chatId)
          .child(fileName);

      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final downloadUrl = await ref.getDownloadURL();

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .get();
      final senderName =
          (userDoc.data()?['nickname'] as String?) ?? '自分';

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
        'senderId': _currentUser!.uid,
        'senderName': senderName,
        'type': 'image',
        'text': '',
        'mediaUrl': downloadUrl,
        'fileName': picked.name,
        'createdAt': FieldValue.serverTimestamp(),
      });

      final imgUpdate = <String, dynamic>{
        'lastMessage': '📷 画像',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSenderId': _currentUser!.uid,
        'lastRead.${_currentUser!.uid}': FieldValue.serverTimestamp(),
        'unreadCount.${_currentUser!.uid}': 0,
      };
      for (final memberId in _memberIds) {
        if (memberId == _currentUser!.uid) continue;
        imgUpdate['unreadCount.$memberId'] = FieldValue.increment(1);
      }
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .update(imgUpdate);

      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('画像の送信に失敗しました: $e'),
              backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendFile() async {
    if (_currentUser == null) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'zip'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) return;

      if (file.size > 10 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ファイルサイズが10MBを超えています'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      setState(() => _isSending = true);

      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      final ref = FirebaseStorage.instance
          .ref()
          .child('chat_files')
          .child(widget.chatId)
          .child(fileName);

      String contentType = 'application/octet-stream';
      final ext = file.extension?.toLowerCase() ?? '';
      if (ext == 'pdf') contentType = 'application/pdf';
      else if (ext == 'doc') contentType = 'application/msword';
      else if (ext == 'docx') contentType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      else if (ext == 'xls') contentType = 'application/vnd.ms-excel';
      else if (ext == 'xlsx') contentType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      else if (ext == 'ppt') contentType = 'application/vnd.ms-powerpoint';
      else if (ext == 'pptx') contentType = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      else if (ext == 'txt') contentType = 'text/plain';
      else if (ext == 'zip') contentType = 'application/zip';

      await ref.putData(file.bytes!, SettableMetadata(contentType: contentType));
      final downloadUrl = await ref.getDownloadURL();

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .get();
      final senderName =
          (userDoc.data()?['nickname'] as String?) ?? '自分';

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
        'senderId': _currentUser!.uid,
        'senderName': senderName,
        'type': 'file',
        'text': '',
        'mediaUrl': downloadUrl,
        'fileName': file.name,
        'fileExtension': ext,
        'fileSize': file.size,
        'createdAt': FieldValue.serverTimestamp(),
      });

      final fileUpdate = <String, dynamic>{
        'lastMessage': '📎 ${file.name}',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSenderId': _currentUser!.uid,
        'lastRead.${_currentUser!.uid}': FieldValue.serverTimestamp(),
        'unreadCount.${_currentUser!.uid}': 0,
      };
      for (final memberId in _memberIds) {
        if (memberId == _currentUser!.uid) continue;
        fileUpdate['unreadCount.$memberId'] = FieldValue.increment(1);
      }
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .update(fileUpdate);

      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('ファイルの送信に失敗しました: $e'),
              backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.image, color: Colors.blue),
              ),
              title: const Text('画像を送信'),
              subtitle: const Text('写真ライブラリから選択'),
              onTap: () {
                Navigator.pop(ctx);
                _sendImage();
              },
            ),
            ListTile(
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.attach_file, color: Colors.orange),
              ),
              title: const Text('ファイルを送信'),
              subtitle: const Text('PDF、Word、Excel など'),
              onTap: () {
                Navigator.pop(ctx);
                _sendFile();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showFullImage(String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(url, fit: BoxFit.contain),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(Icons.close,
                      color: Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatFileSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _getFileIcon(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'txt':
        return Icons.text_snippet;
      case 'zip':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return Colors.red;
      case 'doc':
      case 'docx':
        return Colors.blue;
      case 'xls':
      case 'xlsx':
        return Colors.green;
      case 'ppt':
      case 'pptx':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayTitle = _resolvedTitle.isNotEmpty ? _resolvedTitle : widget.chatTitle;
    final initial = displayTitle.isNotEmpty ? displayTitle[0] : '?';
    // DM相手の公式バッジ確認
    if (widget.chatType == 'dm' && widget.otherUserId != null && widget.otherUserId!.isNotEmpty) {
      if (!_officialCache.containsKey(widget.otherUserId!)) {
        _checkOfficial(widget.otherUserId!);
      }
    }
    final showTitleBadge = widget.chatType == 'dm' &&
        widget.otherUserId != null &&
        _officialCache[widget.otherUserId] == true;

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: GestureDetector(
          onTap: widget.chatType == 'group' ? () {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => GroupChatSettingsScreen(
                chatId: widget.chatId,
                chatName: displayTitle,
              ),
            ));
          } : null,
          child: Row(
            children: [
              (_groupIconUrl.isNotEmpty)
                  ? CircleAvatar(
                      radius: 18,
                      backgroundImage: NetworkImage(_groupIconUrl),
                      backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                    )
                  : (_otherUserAvatarUrl.isNotEmpty && widget.chatType == 'dm')
                    ? CircleAvatar(
                        radius: 18,
                        backgroundImage: NetworkImage(_otherUserAvatarUrl),
                        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                      )
                    : CircleAvatar(
                        radius: 18,
                        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                        child: Text(initial,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primaryColor)),
                      ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(displayTitle,
                    overflow: TextOverflow.ellipsis),
              ),
              if (showTitleBadge) const OfficialBadge(size: 16),
            ],
          ),
        ),
        actions: [
          // ボット自動返信のオンオフ（公式DM × 管理者/公式アカウントのみ表示）
          // ヘッダーは濃紺のため、アイコンは白系にして視認できるようにする。
          // オン＝白（点灯）、オフ＝半透明の白（消灯）で状態を区別。
          if (_canToggleBot)
            IconButton(
              tooltip: _chatbotEnabled ? 'ボット自動返信: オン' : 'ボット自動返信: オフ',
              icon: Icon(
                _chatbotEnabled ? Icons.smart_toy : Icons.smart_toy_outlined,
                color: _chatbotEnabled ? Colors.white : Colors.white.withValues(alpha: 0.45),
              ),
              onPressed: _toggleChatbot,
            ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: _showChatMenu,
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                      child: CircularProgressIndicator(color: AppTheme.primaryColor));
                }

                final messages = snapshot.data?.docs ?? [];
                if (messages.isEmpty) {
                  _previousMessageCount = 0;
                  return Center(
                    child: Text('メッセージを送ってみましょう！',
                        style: TextStyle(color: AppTheme.textSecondary)),
                  );
                }

                _previousMessageCount = messages.length;

                // 未読境界のindexを計算（descending順なので、lastReadより新しいメッセージの最後のindex）
                // messages[0]=最新, messages[n-1]=最古
                // 未読 = createdAt > _myLastReadBefore のメッセージ群
                // 未読の最も古いメッセージ（=descending順で最大index）の位置にバナーを出す
                int? unreadBoundaryIndex;
                if (_myLastReadBefore != null) {
                  final lastReadDate = _myLastReadBefore!.toDate();
                  for (int i = 0; i < messages.length; i++) {
                    final msgData = messages[i].data() as Map<String, dynamic>;
                    final msgTime = (msgData['createdAt'] as Timestamp?)?.toDate();
                    final senderId = msgData['senderId'] as String?;
                    // 自分のメッセージは未読カウントしない
                    if (senderId == _currentUser?.uid) continue;
                    if (msgTime != null && msgTime.isAfter(lastReadDate)) {
                      unreadBoundaryIndex = i; // 最後に見つかったものが最古の未読
                    }
                  }
                }

                // 初回ロード時、未読メッセージがあればその位置にスクロール
                if (!_initialScrollDone && unreadBoundaryIndex != null) {
                  _initialScrollDone = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scrollController.hasClients) {
                      // 未読境界indexの位置に大まかにスクロール
                      // reverse: trueなのでindexが大きいほど上にある
                      final estimatedOffset = unreadBoundaryIndex! * 72.0;
                      final maxOffset = _scrollController.position.maxScrollExtent;
                      _scrollController.jumpTo(
                        estimatedOffset > maxOffset ? maxOffset : estimatedOffset,
                      );
                    }
                  });
                } else if (!_initialScrollDone) {
                  _initialScrollDone = true;
                }

                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    // reverse: true なので index 0 = 最新メッセージ（descending順の先頭）
                    final doc = messages[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final isMe = data['senderId'] == _currentUser?.uid;
                    final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
                    // 日付セパレーター: 表示上の「1つ上」= descending順の次のindex
                    DateTime? prevCreatedAt;
                    if (index < messages.length - 1) {
                      final prevData = messages[index + 1].data() as Map<String, dynamic>;
                      prevCreatedAt = (prevData['createdAt'] as Timestamp?)?.toDate();
                    }
                    final dateSep = createdAt != null ? _dateSeparatorLabel(createdAt, prevCreatedAt) : null;

                    // 未読バナー: 未読境界のメッセージの上（=表示上の上）に表示
                    final showUnreadBanner = (index == unreadBoundaryIndex);

                    return Column(
                      children: [
                        if (dateSep != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.grey[200],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(dateSep, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                            ),
                          ),
                        if (showUnreadBanner)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Expanded(child: Divider(color: AppTheme.primaryColor.withValues(alpha: 0.4), thickness: 1)),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text(
                                    'ここから未読メッセージ',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.primaryColor,
                                    ),
                                  ),
                                ),
                                Expanded(child: Divider(color: AppTheme.primaryColor.withValues(alpha: 0.4), thickness: 1)),
                              ],
                            ),
                          ),
                        _buildMessageBubble(data, isMe, messageId: doc.id),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          if (_showQuickReplies)
            _buildQuickReplies(),
          if (_isSending)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primaryColor)),
                  const SizedBox(width: 8),
                  Text('送信中...',
                      style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary)),
                ],
              ),
            ),
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
                  IconButton(
                    icon: Icon(Icons.add_circle_outline,
                        color: AppTheme.textSecondary),
                    onPressed: _isSending ? null : _showAttachMenu,
                  ),
                  if (widget.chatType == 'dm' && widget.otherUserId == 'zlBy8aWUlCYjyy0NUU9HidrQu983')
                    IconButton(
                      icon: Icon(Icons.help_outline,
                          color: _showQuickReplies ? AppTheme.primaryColor : AppTheme.textSecondary),
                      onPressed: () => setState(() => _showQuickReplies = !_showQuickReplies),
                    ),
                  Expanded(
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundColor,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _messageController,
                        style: const TextStyle(fontSize: 15),
                        maxLines: 4,
                        minLines: 1,
                        decoration: const InputDecoration(
                          hintText: 'メッセージを入力',
                          hintStyle:
                              TextStyle(color: AppTheme.textHint),
                          border: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 10),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _isSending ? null : _sendMessage,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _isSending
                            ? Colors.grey
                            : AppTheme.primaryColor,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.send,
                          color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      )),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> data, bool isMe, {String? messageId}) {
    final type = (data['type'] as String?) ?? 'text';
    final text = (data['text'] as String?) ?? '';
    final senderName = (data['senderName'] as String?) ?? '';
    final mediaUrl = (data['mediaUrl'] as String?) ?? '';
    final fileName = (data['fileName'] as String?) ?? '';
    final fileExtension = (data['fileExtension'] as String?) ?? '';
    final fileSize = data['fileSize'] as int?;
    final createdAt = data['createdAt'] as Timestamp?;
    final timeText = _formatMessageTime(createdAt);
    final isDeleted = data['deleted'] == true;

    if (isDeleted) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.block, size: 14, color: AppTheme.textHint),
              const SizedBox(width: 6),
              Text('メッセージが削除されました',
                  style: TextStyle(fontSize: 13, color: AppTheme.textHint, fontStyle: FontStyle.italic)),
            ]),
          ),
        ),
      );
    }

    return GestureDetector(
      onLongPress: isMe && messageId != null ? () => _showDeleteMessageDialog(messageId) : null,
      child: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!isMe && widget.chatType != 'dm')
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 4),
              child: GestureDetector(
                onTap: () {
                  final senderId = data['senderId'] as String?;
                  if (senderId != null && senderId.isNotEmpty) {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => UserProfileScreen(userId: senderId),
                    ));
                  }
                },
                child: Builder(builder: (_) {
                  final senderId = data['senderId'] as String? ?? '';
                  if (senderId.isNotEmpty && !_officialCache.containsKey(senderId)) {
                    _checkOfficial(senderId);
                  }
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(senderName,
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                      if (_officialCache[senderId] == true)
                        const OfficialBadge(size: 13),
                    ],
                  );
                }),
              ),
            ),
          Row(
            mainAxisAlignment:
                isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isMe) ...[
                GestureDetector(
                  onTap: () {
                    final senderId = data['senderId'] as String?;
                    if (senderId != null && senderId.isNotEmpty) {
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => UserProfileScreen(userId: senderId),
                      ));
                    }
                  },
                  child: _buildSenderAvatar(data['senderId'] as String?, senderName),
                ),
                const SizedBox(width: 8),
              ],
              if (isMe)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _buildReadReceipt(createdAt),
                      Text(timeText, style: const TextStyle(fontSize: 11, color: AppTheme.textHint)),
                    ],
                  ),
                ),
              Flexible(
                child: _buildMessageContent(type, text, mediaUrl, fileName, fileExtension, fileSize, isMe),
              ),
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 2),
                  child: Text(timeText,
                      style: const TextStyle(fontSize: 11, color: AppTheme.textHint)),
                ),
            ],
          ),
        ],
      ),
    ),
    );
  }

  void _showDeleteMessageDialog(String messageId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('メッセージを削除', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text('このメッセージを削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('chats').doc(widget.chatId)
                  .collection('messages').doc(messageId)
                  .update({'deleted': true, 'text': '', 'mediaUrl': ''});
              if (ctx.mounted) Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  Widget _buildSenderAvatar(String? senderId, String senderName) {
    if (senderId != null && senderId.isNotEmpty) {
      // グループチャットの場合、非同期でアバターを取得
      if (!_memberAvatars.containsKey(senderId)) {
        _resolveSenderAvatar(senderId);
      }
      final avatarUrl = _memberAvatars[senderId] ?? '';
      if (avatarUrl.isNotEmpty) {
        return CircleAvatar(
          radius: 16,
          backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
          backgroundImage: NetworkImage(avatarUrl),
        );
      }
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
      child: Text(
        senderName.isNotEmpty ? senderName[0] : '?',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
      ),
    );
  }

  Widget _buildMessageContent(String type, String text, String mediaUrl, String fileName, String fileExtension, int? fileSize, bool isMe) {
    if (type == 'image' && mediaUrl.isNotEmpty) {
      return GestureDetector(
        onTap: () => _showFullImage(mediaUrl),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            mediaUrl,
            width: 200,
            height: 200,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryColor)),
              );
            },
          ),
        ),
      );
    }

    if (type == 'file' && mediaUrl.isNotEmpty) {
      final color = _getFileColor(fileExtension);
      return GestureDetector(
        onTap: () async {
          final uri = Uri.parse(mediaUrl);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isMe
                ? AppTheme.primaryColor.withValues(alpha: 0.85)
                : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
            border: isMe ? null : Border.all(color: Colors.grey[200]!),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_getFileIcon(fileExtension), color: color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isMe ? Colors.white : AppTheme.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${fileExtension.toUpperCase()} ${_formatFileSize(fileSize)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: isMe ? Colors.white70 : AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.download_rounded,
                size: 20,
                color: isMe ? Colors.white70 : AppTheme.textSecondary,
              ),
            ],
          ),
        ),
      );
    }

    // URLを検出してリンク化 + プレビュー表示
    final urlRegex = RegExp(
      r'https?://[^\s\u3000\u3001\u3002\uFF0C\uFF0E]+',
      caseSensitive: false,
    );
    final urls = urlRegex.allMatches(text).map((m) => m.group(0)!).toList();
    final hasUrl = urls.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? AppTheme.primaryColor : Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
        border: isMe ? null : Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasUrl)
            _buildRichTextWithLinks(text, urlRegex, isMe)
          else
            Text(
              text,
              style: TextStyle(
                fontSize: 15,
                color: isMe ? Colors.white : AppTheme.textPrimary,
                height: 1.4,
              ),
            ),
          // URLプレビューカード
          ...urls.map((url) => LinkPreviewWidget(url: url, isMe: isMe)),
        ],
      ),
    );
  }

  Widget _buildRichTextWithLinks(String text, RegExp urlRegex, bool isMe) {
    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (final match in urlRegex.allMatches(text)) {
      // マッチ前のテキスト
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
        ));
      }
      // URLリンク
      final url = match.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          decoration: TextDecoration.underline,
          decorationColor: isMe ? Colors.white70 : AppTheme.primaryColor,
          color: isMe ? Colors.white : AppTheme.primaryColor,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => openLinkInAppOrExternal(context, url),
      ));
      lastEnd = match.end;
    }

    // 残りのテキスト
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: 15,
          color: isMe ? Colors.white : AppTheme.textPrimary,
          height: 1.4,
        ),
        children: spans,
      ),
    );
  }

  void _showChatMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (widget.chatType == 'dm') ...[
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('プロフィールを見る'),
                onTap: () {
                  Navigator.pop(ctx);
                  if (widget.otherUserId != null && widget.otherUserId!.isNotEmpty) {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => UserProfileScreen(userId: widget.otherUserId!),
                    ));
                  }
                },
              ),
            ],
            if (widget.chatType == 'group') ...[
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('グループ設定'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => GroupChatSettingsScreen(
                      chatId: widget.chatId,
                      chatName: widget.chatTitle,
                    ),
                  ));
                },
              ),
            ],
            ListTile(
              leading: Icon(_isMuted ? Icons.notifications_outlined : Icons.notifications_off_outlined),
              title: Text(_isMuted ? '通知をオンにする' : '通知をオフにする'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleMute();
              },
            ),
            if (widget.chatType == 'dm')
              ListTile(
                leading:
                    const Icon(Icons.block, color: AppTheme.error),
                title: const Text('ブロック',
                    style: TextStyle(color: AppTheme.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmBlockUser();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmBlockUser() {
    if (_currentUser == null || widget.otherUserId == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('ブロックしますか？', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text('ブロックすると相手の投稿やメッセージが表示されなくなります。設定からいつでも解除できます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(_currentUser!.uid)
                  .collection('blockedUsers')
                  .doc(widget.otherUserId!)
                  .set({'blockedAt': FieldValue.serverTimestamp()});
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('ユーザーをブロックしました'), backgroundColor: AppTheme.success),
                );
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('ブロック'),
          ),
        ],
      ),
    );
  }

  Widget _buildReadReceipt(Timestamp? messageTime) {
    if (messageTime == null || _currentUser == null) return const SizedBox();

    final msgDate = messageTime.toDate();
    final otherMembers = _memberIds.where((id) => id != _currentUser!.uid).toList();
    if (otherMembers.isEmpty) return const SizedBox();

    final readMemberIds = <String>[];
    for (final memberId in otherMembers) {
      final lastRead = _lastReadMap[memberId];
      if (lastRead is Timestamp && lastRead.toDate().isAfter(msgDate)) {
        readMemberIds.add(memberId);
      }
    }

    if (readMemberIds.isEmpty) return const SizedBox();

    if (widget.chatType == 'dm') {
      return const Text('既読', style: TextStyle(fontSize: 10, color: AppTheme.primaryColor));
    } else {
      return GestureDetector(
        onTap: () => _showReadMembers(readMemberIds),
        child: Text('既読 ${readMemberIds.length}', style: const TextStyle(fontSize: 10, color: AppTheme.primaryColor)),
      );
    }
  }

  void _showReadMembers(List<String> readMemberIds) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Text('既読 ${readMemberIds.length}人', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
            const SizedBox(height: 12),
            ...readMemberIds.map((id) {
              final name = _memberNames[id] ?? 'ユーザー';
              return ListTile(
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                  child: Text(name.isNotEmpty ? name[0] : '?',
                    style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold)),
                ),
                title: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => UserProfileScreen(userId: id),
                  ));
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _formatMessageTime(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(date.year, date.month, date.day);
    final time = '${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    if (msgDay == today) return time;
    if (msgDay == today.subtract(const Duration(days: 1))) return '昨日 $time';
    if (date.year == now.year) return '${date.month}/${date.day} $time';
    return '${date.year}/${date.month}/${date.day} $time';
  }

  /// 日付が変わった箇所にセパレーターを表示するか判定
  String? _dateSeparatorLabel(DateTime current, DateTime? previous) {
    final currentDay = DateTime(current.year, current.month, current.day);
    if (previous != null) {
      final prevDay = DateTime(previous.year, previous.month, previous.day);
      if (currentDay == prevDay) return null;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (currentDay == today) return '今日';
    if (currentDay == today.subtract(const Duration(days: 1))) return '昨日';
    if (current.year == now.year) return '${current.month}月${current.day}日';
    return '${current.year}年${current.month}月${current.day}日';
  }
}
