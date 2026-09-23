import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../config/app_theme.dart';
import '../../main.dart';
import '../../services/auth_service.dart';
import '../help/faq_screen.dart';
import '../chat/chat_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushNotification = true;
  bool _emailNotification = false;
  bool _matchNotification = true;
  bool _tournamentNotification = true;
  bool _followNotification = true;
  bool _chatNotification = true;
  bool _likeCommentNotification = true;
  bool _organizerNotification = true;
  bool _officialNotification = true;
  bool _reminderNotification = true;
  bool _teamNotification = true;
  String _searchId = '';
  bool _isAdmin = false;
  bool _osNotificationDenied = false;
  String _appVersion = '';
  String? _notificationEmail;
  bool _notificationEmailVerified = false;
  String? _pendingNotificationEmail;

  @override
  void initState() {
    super.initState();
    _loadNotificationSettings();
    _checkOsNotificationPermission();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = '${info.version}+${info.buildNumber}');
    } catch (_) {}
  }

  Future<void> _checkOsNotificationPermission() async {
    if (kIsWeb) return;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      if (mounted) {
        setState(() {
          _osNotificationDenied =
              settings.authorizationStatus == AuthorizationStatus.denied;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadNotificationSettings() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    final results = await Future.wait([
      userRef.get(),
      userRef.collection('private').doc('info').get(),
    ]);
    final doc = results[0];
    final privateDoc = results[1];
    if (doc.exists) {
      final data = doc.data();
      final privateData = privateDoc.data();
      final settings =
          data?['notificationSettings'] as Map<String, dynamic>?;
      if (mounted) {
        setState(() {
          _searchId = (data?['searchId'] as String?) ?? '';
          _isAdmin = data?['isAdmin'] == true;
          _notificationEmail = privateData?['notificationEmail'] as String?;
          _notificationEmailVerified = privateData?['notificationEmailVerified'] == true;
          _pendingNotificationEmail = privateData?['pendingNotificationEmail'] as String?;
          if (settings != null) {
            _pushNotification = settings['push'] ?? true;
            _emailNotification = settings['email'] ?? false;
            _tournamentNotification = settings['tournament'] ?? true;
            _followNotification = settings['follow'] ?? true;
            _matchNotification = settings['match'] ?? true;
            _chatNotification = settings['chat'] ?? true;
            _likeCommentNotification = settings['likeComment'] ?? true;
            _organizerNotification = settings['organizer'] ?? true;
            _officialNotification = settings['official'] ?? true;
            _reminderNotification = settings['reminder'] ?? true;
            _teamNotification = settings['team'] ?? true;
          }
        });
      }
    }
  }

  Future<void> _saveNotificationSettings() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'notificationSettings': {
          'push': _pushNotification,
          'email': _emailNotification,
          'tournament': _tournamentNotification,
          'follow': _followNotification,
          'match': _matchNotification,
          'chat': _chatNotification,
          'likeComment': _likeCommentNotification,
          'organizer': _organizerNotification,
          'official': _officialNotification,
          'reminder': _reminderNotification,
          'team': _teamNotification,
        },
      }, SetOptions(merge: true));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('操作に失敗しました'),
            backgroundColor: AppTheme.error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('設定'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── アカウント情報 ──
          _buildSectionHeader('アカウント'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              children: [
                _buildInfoTile(
                  Icons.email_outlined,
                  'メールアドレス',
                  user?.email ?? '未設定',
                ),
                _buildDivider(),
                ListTile(
                  leading: Icon(Icons.mark_email_read_outlined,
                      color: AppTheme.primaryColor, size: 22),
                  title: const Text('通知用メールアドレス',
                      style: TextStyle(fontSize: 15)),
                  subtitle: Text(
                    _notificationEmailVerified && _notificationEmail != null
                        ? '認証済み: $_notificationEmail'
                        : _pendingNotificationEmail != null
                            ? '認証待ち: $_pendingNotificationEmail（メール内のリンクを確認してください）'
                            : '未設定（通常のメールアドレスに送信されます）',
                    style: TextStyle(
                      fontSize: 12,
                      color: _notificationEmailVerified
                          ? AppTheme.success
                          : _pendingNotificationEmail != null
                              ? AppTheme.warning
                              : AppTheme.textSecondary,
                    ),
                  ),
                  trailing: Icon(Icons.chevron_right,
                      color: Colors.grey[400], size: 22),
                  onTap: () => _showNotificationEmailDialog(),
                ),
                _buildDivider(),
                _buildCopyableTile(
                  Icons.badge_outlined,
                  'ユーザーID',
                  _searchId.isNotEmpty ? '@$_searchId' : '未設定',
                ),
                _buildDivider(),
                ListTile(
                  leading: Icon(Icons.lock_outline,
                      color: AppTheme.primaryColor, size: 22),
                  title: const Text('パスワード変更',
                      style: TextStyle(fontSize: 15)),
                  trailing: Icon(Icons.chevron_right,
                      color: Colors.grey[400], size: 22),
                  onTap: () => _showChangePasswordDialog(),
                ),
                if (_isAdmin) ...[
                  _buildDivider(),
                  ListTile(
                    leading: const Icon(Icons.shield_outlined, color: AppTheme.error, size: 22),
                    title: const Text('権限', style: TextStyle(fontSize: 15)),
                    trailing: const Text('特別権限', style: TextStyle(fontSize: 14, color: AppTheme.error, fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── 通知設定 ──
          _buildSectionHeader('通知設定'),
          const SizedBox(height: 8),

          // プッシュ通知マスタートグル
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: _buildSwitchTile(
              Icons.notifications_outlined,
              'プッシュ通知',
              'ロック画面・バナーに通知を表示',
              _pushNotification,
              (v) {
                setState(() => _pushNotification = v);
                _saveNotificationSettings();
              },
            ),
          ),
          if (_osNotificationDenied) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                // 端末の通知設定を開く
                await launchUrl(Uri.parse('app-settings:'));
                // 戻ってきたら再チェック
                Future.delayed(const Duration(seconds: 1), _checkOsNotificationPermission);
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.warning.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '端末の通知設定がオフになっています。タップして設定を開く',
                        style: TextStyle(fontSize: 13, color: AppTheme.warning),
                      ),
                    ),
                    Icon(Icons.open_in_new, color: AppTheme.warning, size: 16),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),

          // プッシュ通知の個別設定
          _buildSubSectionHeader('プッシュ通知の種類'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: AnimatedOpacity(
              opacity: _pushNotification ? 1.0 : 0.5,
              duration: const Duration(milliseconds: 200),
              child: Column(
                children: [
                  _buildSwitchTile(
                    Icons.chat_bubble_outline,
                    'チャット',
                    '新しいメッセージを受け取った時',
                    _chatNotification,
                    _pushNotification ? (v) {
                      setState(() => _chatNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.sports_volleyball_outlined,
                    '大会',
                    '大会のお知らせ・結果・空き通知',
                    _tournamentNotification,
                    _pushNotification ? (v) {
                      setState(() => _tournamentNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.favorite_outline,
                    'いいね・コメント',
                    '投稿へのリアクション',
                    _likeCommentNotification,
                    _pushNotification ? (v) {
                      setState(() => _likeCommentNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.person_add_outlined,
                    'フォロー',
                    '新しいフォロワー',
                    _followNotification,
                    _pushNotification ? (v) {
                      setState(() => _followNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.sync_alt,
                    'マッチング',
                    'メンバー募集のマッチング結果',
                    _matchNotification,
                    _pushNotification ? (v) {
                      setState(() => _matchNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.campaign_outlined,
                    '大会運営者からの通知',
                    'エントリー中の大会の主催者からの連絡',
                    _organizerNotification,
                    _pushNotification ? (v) {
                      setState(() => _organizerNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.star_outline,
                    'Sofvo公式からの通知',
                    'メンテナンス・新機能・イベント情報',
                    _officialNotification,
                    _pushNotification ? (v) {
                      setState(() => _officialNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.access_time,
                    'リマインダー',
                    '大会前日のお知らせ',
                    _reminderNotification,
                    _pushNotification ? (v) {
                      setState(() => _reminderNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                  _buildDivider(),
                  _buildSwitchTile(
                    Icons.group_outlined,
                    'チーム',
                    'メンバーの加入・退出',
                    _teamNotification,
                    _pushNotification ? (v) {
                      setState(() => _teamNotification = v);
                      _saveNotificationSettings();
                    } : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // メール通知
          _buildSubSectionHeader('その他'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: _buildSwitchTile(
              Icons.mail_outline,
              'メール通知',
              '重要なお知らせをメールで受け取る',
              _emailNotification,
              (v) {
                setState(() => _emailNotification = v);
                _saveNotificationSettings();
              },
            ),
          ),
          const SizedBox(height: 24),

          // ── アプリ情報 ──
          _buildSectionHeader('アプリ情報'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              children: [
                _buildInfoTile(
                  Icons.info_outline,
                  'バージョン',
                  _appVersion.isNotEmpty ? _appVersion : '...',
                ),
                _buildDivider(),
                ListTile(
                  leading: Icon(Icons.description_outlined,
                      color: AppTheme.primaryColor, size: 22),
                  title: const Text('利用規約（EULA）',
                      style: TextStyle(fontSize: 15)),
                  trailing: Icon(Icons.open_in_new,
                      color: Colors.grey[400], size: 18),
                  onTap: () => _openUrl('https://sofvo.com/terms.html'),
                ),
                _buildDivider(),
                ListTile(
                  leading: Icon(Icons.privacy_tip_outlined,
                      color: AppTheme.primaryColor, size: 22),
                  title: const Text('プライバシーポリシー',
                      style: TextStyle(fontSize: 15)),
                  trailing: Icon(Icons.open_in_new,
                      color: Colors.grey[400], size: 18),
                  onTap: () => _openUrl('https://sofvo.com/privacy.html'),
                ),
                _buildDivider(),
                ListTile(
                  leading: Icon(Icons.help_outline,
                      color: AppTheme.primaryColor, size: 22),
                  title: const Text('よくある質問',
                      style: TextStyle(fontSize: 15)),
                  trailing: Icon(Icons.chevron_right,
                      color: Colors.grey[400], size: 22),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FaqScreen())),
                ),
                _buildDivider(),
                ListTile(
                  leading: Icon(Icons.chat_bubble_outline,
                      color: AppTheme.primaryColor, size: 22),
                  title: const Text('ヘルプ・お問い合わせ',
                      style: TextStyle(fontSize: 15)),
                  trailing: Icon(Icons.chevron_right,
                      color: Colors.grey[400], size: 18),
                  onTap: () => _openOfficialChat(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── 危険ゾーン ──
          _buildSectionHeader('アカウント操作'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.logout,
                      color: AppTheme.error, size: 22),
                  title: const Text('ログアウト',
                      style: TextStyle(
                          fontSize: 15,
                          color: AppTheme.error,
                          fontWeight: FontWeight.w500)),
                  onTap: () => _showLogoutDialog(),
                ),
                _buildDivider(),
                ListTile(
                  leading: Icon(Icons.delete_forever,
                      color: AppTheme.error, size: 22),
                  title: const Text('アカウント削除',
                      style: TextStyle(
                          fontSize: 15,
                          color: AppTheme.error,
                          fontWeight: FontWeight.w500)),
                  onTap: () => _showDeleteAccountDialog(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: AppTheme.textSecondary,
      ),
    );
  }

  Widget _buildInfoTile(IconData icon, String title, String value) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.primaryColor, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(
        value,
        style: const TextStyle(
          fontSize: 14,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildCopyableTile(IconData icon, String title, String value) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.primaryColor, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
          if (value != '未設定') ...[
            const SizedBox(width: 4),
            Icon(Icons.copy, size: 16, color: Colors.grey[400]),
          ],
        ],
      ),
      onTap: value != '未設定'
          ? () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('ユーザーIDをコピーしました'),
                  backgroundColor: AppTheme.success,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          : null,
    );
  }

  Widget _buildSubSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.textHint,
        ),
      ),
    );
  }

  Widget _buildSwitchTile(
    IconData icon,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool>? onChanged,
  ) {
    return ListTile(
      leading: Icon(icon, color: onChanged != null ? AppTheme.primaryColor : AppTheme.textHint, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(subtitle,
          style: const TextStyle(
              fontSize: 12, color: AppTheme.textSecondary)),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: AppTheme.primaryColor,
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(height: 1, indent: 56, color: Colors.grey[100]);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ページを開けませんでした'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _openOfficialChat(BuildContext context) async {
    const officialUid = 'zlBy8aWUlCYjyy0NUU9HidrQu983';
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    // 既存DMを検索
    final existing = await FirebaseFirestore.instance
        .collection('chats')
        .where('type', isEqualTo: 'dm')
        .where('members', arrayContains: myUid)
        .get();

    String? chatId;
    for (final doc in existing.docs) {
      final members = List<String>.from(doc['members'] ?? []);
      if (members.contains(officialUid)) {
        chatId = doc.id;
        break;
      }
    }

    if (chatId == null) {
      final myDoc = await FirebaseFirestore.instance.collection('users').doc(myUid).get();
      final myName = (myDoc.data()?['nickname'] as String?) ?? '自分';
      final ref = await FirebaseFirestore.instance.collection('chats').add({
        'type': 'dm',
        'members': [myUid, officialUid],
        'memberNames': {myUid: myName, officialUid: '【公式】Sofvo'},
        'lastMessage': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastRead': {myUid: FieldValue.serverTimestamp()},
        'createdAt': FieldValue.serverTimestamp(),
      });
      chatId = ref.id;
    }

    if (mounted) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chatId!, chatTitle: '【公式】Sofvo', chatType: 'dm', otherUserId: officialUid),
      ));
    }
  }

  void _showNotificationEmailDialog() {
    final emailCtrl = TextEditingController(text: _pendingNotificationEmail ?? '');
    bool sending = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('通知用メールアドレス', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Apple/Googleサインインなどでログイン用メールアドレスを変更できない場合に、'
                'ウェルカムメール等の通知だけ別のアドレスに届けたいときに使います。'
                '入力すると確認メールが届くので、メール内のリンクを開くと設定が反映されます。',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.5),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'example@example.com',
                  filled: true,
                  fillColor: AppTheme.backgroundColor,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: sending
                  ? null
                  : () async {
                      final email = emailCtrl.text.trim();
                      if (email.isEmpty || !email.contains('@')) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('正しいメールアドレスを入力してください'), backgroundColor: AppTheme.warning));
                        return;
                      }
                      setDialogState(() => sending = true);
                      try {
                        await FirebaseFunctions.instance
                            .httpsCallable('requestNotificationEmailVerification')
                            .call({'email': email});
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          setState(() => _pendingNotificationEmail = email);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('$email 宛に確認メールを送信しました'), backgroundColor: AppTheme.success));
                        }
                      } on FirebaseFunctionsException catch (e) {
                        setDialogState(() => sending = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text(e.message ?? '送信に失敗しました'), backgroundColor: AppTheme.error));
                        }
                      } catch (_) {
                        setDialogState(() => sending = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('送信に失敗しました'), backgroundColor: AppTheme.error));
                        }
                      }
                    },
              child: sending
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('確認メールを送る'),
            ),
          ],
        );
      }),
    );
  }

  void _showChangePasswordDialog() {
    final currentPwCtrl = TextEditingController();
    final newPwCtrl = TextEditingController();
    final confirmPwCtrl = TextEditingController();

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) => StatefulBuilder(builder: (ctx, setPageState) {
        bool hasInput() => currentPwCtrl.text.isNotEmpty || newPwCtrl.text.isNotEmpty || confirmPwCtrl.text.isNotEmpty;

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
                ElevatedButton(
                  onPressed: () => Navigator.pop(dlgCtx, true),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
                  child: const Text('破棄する'),
                ),
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
              title: const Text('パスワード変更', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              centerTitle: true,
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('現在のパスワード', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(controller: currentPwCtrl, obscureText: true, onChanged: (_) => setPageState(() {}),
                  decoration: InputDecoration(labelText: '現在のパスワード', filled: true, fillColor: AppTheme.backgroundColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none))),
                const SizedBox(height: 20),
                const Text('新しいパスワード', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(controller: newPwCtrl, obscureText: true, onChanged: (_) => setPageState(() {}),
                  decoration: InputDecoration(labelText: '新しいパスワード（6文字以上）', filled: true, fillColor: AppTheme.backgroundColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none))),
                const SizedBox(height: 16),
                TextField(controller: confirmPwCtrl, obscureText: true, onChanged: (_) => setPageState(() {}),
                  decoration: InputDecoration(labelText: '新しいパスワード（確認）', filled: true, fillColor: AppTheme.backgroundColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none))),
                const SizedBox(height: 32),
                SizedBox(width: double.infinity, child: ElevatedButton(
                  onPressed: currentPwCtrl.text.isNotEmpty && newPwCtrl.text.length >= 6 && newPwCtrl.text == confirmPwCtrl.text
                      ? () async {
                          try {
                            await AuthService().changePassword(currentPwCtrl.text, newPwCtrl.text);
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('パスワードを変更しました'), backgroundColor: AppTheme.success));
                          } catch (e) {
                            if (mounted) {
                              String message = 'パスワードの変更に失敗しました';
                              if (e.toString().contains('wrong-password') || e.toString().contains('invalid-credential')) message = '現在のパスワードが正しくありません';
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: AppTheme.error));
                            }
                          }
                        } : null,
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[300], padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: const Text('変更する', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                )),
                if (newPwCtrl.text.isNotEmpty && newPwCtrl.text.length < 6)
                  Padding(padding: const EdgeInsets.only(top: 8), child: Text('パスワードは6文字以上にしてください', style: TextStyle(fontSize: 12, color: AppTheme.error))),
                if (confirmPwCtrl.text.isNotEmpty && newPwCtrl.text != confirmPwCtrl.text)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text('パスワードが一致しません', style: TextStyle(fontSize: 12, color: AppTheme.error))),
              ]),
            ),
          ),
        );
      }),
    ));
  }

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('ログアウト',
            style:
                TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: const Text('ログアウトしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('キャンセル',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              // グローバルの招待/紹介パラメータをクリア（前ユーザーの状態が残らないように）
              pendingTournamentId = null;
              pendingCheckInTournamentId = null;
              pendingReferrerUserId = null;
              // suppressAuthStateChange をリセット（登録フローで残っている場合に備える）
              suppressAuthStateChange = false;
              await AuthService().signOut();
              // signOut後はAuthGateがauthStateChangesで検知して
              // 自動的にLoginScreenに遷移する。
              // ナビゲーションスタック上のSettingsScreen等を全て除去して
              // AuthGate（ルート）を表示させる。
              if (ctx.mounted) {
                Navigator.of(ctx).popUntil((route) => route.isFirst);
              }
              scaffoldMessengerKey.currentState?.showSnackBar(
                const SnackBar(
                  content: Text('ログアウトしました'),
                  backgroundColor: AppTheme.success,
                  duration: Duration(seconds: 2),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              minimumSize: const Size(100, 40),
            ),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );
  }

  void _showDeleteAccountDialog() {
    final passwordCtrl = TextEditingController();
    final authService = AuthService();
    final provider = authService.signInProvider;
    final isPasswordUser = provider == 'password';

    bool isDeleting = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (isDeleting) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              content: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(height: 16),
                  CircularProgressIndicator(color: AppTheme.primaryColor),
                  SizedBox(height: 24),
                  Text('アカウントを削除しています...',
                      style: TextStyle(fontSize: 15)),
                  SizedBox(height: 8),
                  Text('しばらくお待ちください',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                  SizedBox(height: 16),
                ],
              ),
            );
          }
          return AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            title: const Text('アカウント削除',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'アカウントを完全に削除しますか？\n\n'
                  '・すべての投稿が削除されます\n'
                  '・チーム情報が削除されます\n'
                  '・この操作は取り消せません',
                  style: TextStyle(height: 1.5),
                ),
                const SizedBox(height: 16),
                if (isPasswordUser)
                  TextField(
                    controller: passwordCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '確認のためパスワードを入力',
                      filled: true,
                      fillColor: AppTheme.backgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  )
                else
                  Text(
                    provider == 'google.com'
                        ? '削除するにはGoogleアカウントで再認証します'
                        : '削除するにはApple IDで再認証します',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('キャンセル',
                    style: TextStyle(color: AppTheme.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (isPasswordUser && passwordCtrl.text.isEmpty) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(
                        content: Text('パスワードを入力してください'),
                        backgroundColor: AppTheme.warning,
                      ),
                    );
                    return;
                  }
                  setDialogState(() => isDeleting = true);
                  try {
                    await authService.deleteAccount(
                        isPasswordUser ? passwordCtrl.text : null);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      await showDialog(
                        context: this.context,
                        barrierDismissible: false,
                        builder: (ctx) => AlertDialog(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          title: const Text('アカウント削除完了',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                          content: const Text(
                            'アカウントが正常に削除されました。\nご利用ありがとうございました。',
                            style: TextStyle(height: 1.5),
                          ),
                          actions: [
                            ElevatedButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                      // pushAndRemoveUntil(LoginScreen)ではなくpopUntilを使用。
                      // deleteAccount()でFirebase Authユーザーが削除されると
                      // AuthGateが認証状態の変化を検知してLoginScreenを自動表示する。
                      // AuthGateをウィジェットツリーに残すことで、
                      // 再ログイン時も正しくonAuthSuccessが動作する。
                      if (mounted) {
                        Navigator.of(this.context).popUntil((route) => route.isFirst);
                      }
                    }
                  } catch (e) {
                    setDialogState(() => isDeleting = false);
                    debugPrint('アカウント削除エラー: $e');
                    if (mounted) {
                      String message = 'アカウント削除に失敗しました';
                      final errorStr = e.toString();
                      if (errorStr.contains('wrong-password') ||
                          errorStr.contains('invalid-credential')) {
                        message = 'パスワードが正しくありません';
                      } else if (errorStr.contains('popup-closed-by-user') ||
                          errorStr.contains('cancelled-popup-request') ||
                          errorStr.contains('キャンセル')) {
                        message = '認証がキャンセルされました';
                      } else if (errorStr.contains('popup-blocked')) {
                        message = 'ポップアップがブロックされました。ポップアップを許可してください';
                      } else {
                        message = 'エラー: $errorStr';
                      }
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          content: Text(message),
                          backgroundColor: AppTheme.error,
                        ),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.error,
                  minimumSize: const Size(100, 40),
                ),
                child: const Text('削除する'),
              ),
            ],
          );
        },
      ),
    );
  }
}
