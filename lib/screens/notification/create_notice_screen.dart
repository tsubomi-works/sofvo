import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';

/// お知らせ一斉配信画面（公式アカウント用）
class CreateNoticeScreen extends StatefulWidget {
  const CreateNoticeScreen({super.key});

  @override
  State<CreateNoticeScreen> createState() => _CreateNoticeScreenState();
}

class _CreateNoticeScreenState extends State<CreateNoticeScreen> {
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final _linkController = TextEditingController();
  final _linkLabelController = TextEditingController();
  String _selectedType = 'info';
  int _selectedTemplateIndex = 0;
  bool _isPinned = false;
  bool _isSending = false;
  DateTime? _scheduledAt;
  String _targetPlatform = 'all'; // 'all' | 'ios' | 'android'

  static const _targetOptions = [
    {'value': 'all', 'label': '全員', 'icon': Icons.public},
    {'value': 'ios', 'label': 'iOS', 'icon': Icons.phone_iphone},
    {'value': 'android', 'label': 'Android', 'icon': Icons.phone_android},
  ];

  static const _noticeTemplates = <String, List<Map<String, String>>>{
    'info': [
      {'label': '自由入力', 'title': '', 'body': ''},
      {'label': 'イベント告知', 'title': 'イベントのお知らせ', 'body': '下記の日程でイベントを開催します。\n\n日時: \n場所: \n内容: \n\n皆様のご参加をお待ちしております！'},
      {'label': 'ルール変更', 'title': 'ルール変更のお知らせ', 'body': '以下のルールが変更されました。\n\n【変更点】\n・\n\n【適用日】\n\nご不明点があればお問い合わせください。'},
    ],
    'release': [
      {'label': '自由入力', 'title': '', 'body': ''},
      {'label': '新機能リリース', 'title': '新機能リリースのお知らせ', 'body': '新しい機能が追加されました！\n\n【新機能】\n・\n\nぜひお試しください！'},
      {'label': '正式リリース', 'title': 'Sofvo 正式リリースのお知らせ', 'body': 'ソフトバレーボール マッチングアプリ「Sofvo」をご利用いただきありがとうございます。大会検索・メンバー募集・チャットなどの機能をお楽しみください。'},
    ],
    'update': [
      {'label': '自由入力', 'title': '', 'body': ''},
      {'label': 'アップデート', 'title': 'バージョン アップデート', 'body': '以下の機能が改善されました。\n\n【改善点】\n・\n\nアプリを最新版に更新してご利用ください。'},
      {'label': '不具合修正', 'title': '不具合修正のお知らせ', 'body': '以下の不具合を修正しました。\n\n【修正内容】\n・\n\nご不便をおかけして申し訳ございませんでした。'},
    ],
    'maintenance': [
      {'label': '自由入力', 'title': '', 'body': ''},
      {'label': '定期メンテナンス', 'title': 'メンテナンスのお知らせ', 'body': '下記の日時にメンテナンスを実施します。\n\n日時: 月 日（ ） 00:00 〜 00:00\n\nメンテナンス中はサービスをご利用いただけません。ご迷惑をおかけしますが、ご了承ください。'},
      {'label': '緊急メンテナンス', 'title': '緊急メンテナンスのお知らせ', 'body': '現在、緊急メンテナンスを実施中です。\n\n復旧予定: 月 日（ ） 00:00\n\nご不便をおかけして申し訳ございません。復旧次第お知らせいたします。'},
    ],
  };

  static const _noticeTypeOptions = [
    {'value': 'info', 'label': 'お知らせ', 'icon': Icons.info_outline, 'color': 0xFF1B3A5C},
    {'value': 'release', 'label': 'リリース', 'icon': Icons.campaign, 'color': 0xFFC4A962},
    {'value': 'update', 'label': 'アップデート', 'icon': Icons.update, 'color': 0xFF1565C0},
    {'value': 'maintenance', 'label': 'メンテナンス', 'icon': Icons.build, 'color': 0xFFF9A825},
  ];

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _linkController.dispose();
    _linkLabelController.dispose();
    super.dispose();
  }

  Future<void> _pickScheduledAt() async {
    final now = DateTime.now();
    final initial = _scheduledAt ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('ja', 'JP'),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    final picked = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (picked.isBefore(DateTime.now().add(const Duration(minutes: 1)))) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('配信時刻は現在時刻より後を選択してください'), backgroundColor: AppTheme.warning),
        );
      }
      return;
    }
    setState(() => _scheduledAt = picked);
  }

  String _formatScheduled(DateTime dt) {
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y/$m/$d $hh:$mm';
  }

  Future<void> _pickTournamentForLink() async {
    final searchController = TextEditingController();
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20, right: 20, top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Container(width: 40, height: 4,
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 16),
                  const Text('大会を選択', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: searchController,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: InputDecoration(
                      hintText: '大会名で検索',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      filled: true,
                      fillColor: AppTheme.backgroundColor,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: FutureBuilder<QuerySnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('tournaments')
                          .orderBy('date', descending: true)
                          .limit(100)
                          .get(),
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
                        }
                        final keyword = searchController.text.trim();
                        final docs = snap.data!.docs.where((d) {
                          if (keyword.isEmpty) return true;
                          final title = ((d.data() as Map<String, dynamic>)['title'] ?? '').toString();
                          return title.contains(keyword);
                        }).toList();
                        if (docs.isEmpty) {
                          return Center(child: Text('大会が見つかりません', style: TextStyle(color: AppTheme.textSecondary)));
                        }
                        return ListView.separated(
                          controller: scrollController,
                          itemCount: docs.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey[100]),
                          itemBuilder: (context, i) {
                            final d = docs[i];
                            final data = d.data() as Map<String, dynamic>;
                            final title = (data['title'] ?? '').toString();
                            final date = (data['date'] ?? '').toString();
                            return ListTile(
                              title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                              subtitle: date.isNotEmpty ? Text(date, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)) : null,
                              onTap: () => Navigator.pop(ctx, {'id': d.id, 'title': title}),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    searchController.dispose();
    if (picked == null || !mounted) return;
    final id = picked['id'] as String;
    setState(() {
      _linkController.text = 'https://sofvo.com/?t=$id';
      if (_linkLabelController.text.trim().isEmpty) {
        _linkLabelController.text = '大会の詳細を見る';
      }
    });
  }

  bool _isValidUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) return false;
    if (uri.host.isEmpty) return false;
    return true;
  }

  void _applyTemplate(int index) {
    final templates = _noticeTemplates[_selectedType] ?? _noticeTemplates['info']!;
    setState(() => _selectedTemplateIndex = index);
    final t = templates[index];
    _titleController.text = t['title'] ?? '';
    _bodyController.text = t['body'] ?? '';
  }

  Future<void> _send() async {
    if (_titleController.text.trim().isEmpty || _bodyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タイトルと本文を入力してください'), backgroundColor: AppTheme.warning),
      );
      return;
    }

    final linkText = _linkController.text.trim();
    final linkLabelText = _linkLabelController.text.trim();
    if (linkText.isNotEmpty && !_isValidUrl(linkText)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('リンクURLが正しくありません（http/https）'), backgroundColor: AppTheme.warning),
      );
      return;
    }

    final isScheduled = _scheduledAt != null;

    setState(() => _isSending = true);
    try {
      final data = <String, dynamic>{
        'type': _selectedType,
        'title': _titleController.text.trim(),
        'body': _bodyController.text.trim(),
        'platform': _targetPlatform,
        if (_isPinned) 'pinned': true,
        if (linkText.isNotEmpty) 'link': linkText,
        if (linkText.isNotEmpty && linkLabelText.isNotEmpty) 'linkLabel': linkLabelText,
      };

      if (isScheduled) {
        // 予約配信: createdAt は未設定のままにして home_screen の orderBy から除外する
        data['status'] = 'scheduled';
        data['scheduledAt'] = Timestamp.fromDate(_scheduledAt!);
      } else {
        data['status'] = 'published';
        data['createdAt'] = FieldValue.serverTimestamp();
      }

      await FirebaseFirestore.instance.collection('notices').add(data);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isScheduled
                ? '${_formatScheduled(_scheduledAt!)} に配信予約しました'
                : 'お知らせを配信しました'),
            backgroundColor: AppTheme.success,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('配信に失敗しました: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = _noticeTemplates[_selectedType] ?? _noticeTemplates['info']!;

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('お知らせ配信', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 種類
            Text('種類', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.8,
              children: _noticeTypeOptions.map((opt) {
                final value = opt['value'] as String;
                final label = opt['label'] as String;
                final icon = opt['icon'] as IconData;
                final color = Color(opt['color'] as int);
                final isSelected = value == _selectedType;
                return GestureDetector(
                  onTap: () {
                    setState(() { _selectedType = value; _selectedTemplateIndex = 0; });
                    _applyTemplate(0);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: isSelected ? color.withValues(alpha: 0.1) : AppTheme.backgroundColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? color : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 18, color: isSelected ? color : AppTheme.textSecondary),
                        const SizedBox(width: 6),
                        Text(label, style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected ? color : AppTheme.textSecondary,
                        )),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // 配信対象
            Text('配信対象', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Row(
              children: _targetOptions.map((opt) {
                final value = opt['value'] as String;
                final label = opt['label'] as String;
                final icon = opt['icon'] as IconData;
                final isSelected = value == _targetPlatform;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: value == 'android' ? 0 : 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _targetPlatform = value),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppTheme.primaryColor.withValues(alpha: 0.1)
                              : AppTheme.backgroundColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? AppTheme.primaryColor : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(icon, size: 16, color: isSelected ? AppTheme.primaryColor : AppTheme.textSecondary),
                            const SizedBox(width: 6),
                            Text(label, style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? AppTheme.primaryColor : AppTheme.textSecondary,
                            )),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // ピン留め
            Container(
              decoration: BoxDecoration(
                color: AppTheme.backgroundColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                value: _isPinned,
                onChanged: (v) => setState(() => _isPinned = v),
                title: const Text('ピン留め', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: Text('お知らせ一覧の上部に固定表示します', style: TextStyle(fontSize: 12, color: AppTheme.textHint)),
                secondary: Icon(Icons.push_pin, color: _isPinned ? AppTheme.primaryColor : AppTheme.textSecondary, size: 22),
                activeColor: AppTheme.primaryColor,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 20),

            // テンプレート
            if (templates.length > 1) ...[
              Text('テンプレート', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.backgroundColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _selectedTemplateIndex,
                    isExpanded: true,
                    borderRadius: BorderRadius.circular(12),
                    icon: const Icon(Icons.expand_more, color: AppTheme.textSecondary),
                    items: List.generate(templates.length, (i) => DropdownMenuItem(
                      value: i,
                      child: Text(templates[i]['label']!, style: const TextStyle(fontSize: 14)),
                    )),
                    onChanged: (i) {
                      if (i != null) _applyTemplate(i);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // タイトル
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                hintText: 'タイトルを入力',
                hintStyle: TextStyle(color: AppTheme.textHint),
                filled: true,
                fillColor: AppTheme.backgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                counterText: '',
              ),
              maxLength: 50,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),

            // 本文
            TextField(
              controller: _bodyController,
              decoration: InputDecoration(
                hintText: '本文を入力',
                hintStyle: TextStyle(color: AppTheme.textHint),
                filled: true,
                fillColor: AppTheme.backgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                counterStyle: TextStyle(color: AppTheme.textHint, fontSize: 11),
              ),
              maxLines: 5,
              maxLength: 500,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),

            // リンクURL（任意）
            Text('リンクURL（任意）', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickTournamentForLink,
              icon: const Icon(Icons.emoji_events_outlined, size: 18, color: AppTheme.primaryColor),
              label: const Text('大会を選んでリンクを自動入力', style: TextStyle(fontSize: 13, color: AppTheme.primaryColor, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 42),
                side: const BorderSide(color: AppTheme.primaryColor),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _linkController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: 'https://example.com',
                hintStyle: TextStyle(color: AppTheme.textHint),
                prefixIcon: const Icon(Icons.link, color: AppTheme.textSecondary, size: 20),
                filled: true,
                fillColor: AppTheme.backgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _linkLabelController,
              decoration: InputDecoration(
                hintText: 'ボタンの表示文字（例: 詳細を見る）',
                hintStyle: TextStyle(color: AppTheme.textHint),
                prefixIcon: const Icon(Icons.label_outline, color: AppTheme.textSecondary, size: 20),
                filled: true,
                fillColor: AppTheme.backgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                counterText: '',
              ),
              maxLength: 20,
              style: const TextStyle(fontSize: 14),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                'URLを指定するとお知らせ内にボタンが表示されます（未入力時は「詳細を見る」）',
                style: TextStyle(fontSize: 11, color: AppTheme.textHint),
              ),
            ),
            const SizedBox(height: 20),

            // 配信時刻（任意）
            Text('配信時刻', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            InkWell(
              onTap: _isSending ? null : _pickScheduledAt,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _scheduledAt != null ? AppTheme.primaryColor : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _scheduledAt != null ? Icons.schedule : Icons.flash_on,
                      size: 20,
                      color: _scheduledAt != null ? AppTheme.primaryColor : AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _scheduledAt != null
                            ? '${_formatScheduled(_scheduledAt!)} に配信'
                            : '即時配信（今すぐ送信）',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _scheduledAt != null ? AppTheme.primaryColor : AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    if (_scheduledAt != null)
                      IconButton(
                        icon: const Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
                        onPressed: _isSending ? null : () => setState(() => _scheduledAt = null),
                        tooltip: '予約を解除',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      )
                    else
                      const Icon(Icons.chevron_right, size: 20, color: AppTheme.textHint),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 配信ボタン
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isSending ? null : _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: _isSending
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(_scheduledAt != null ? '配信予約する' : '配信する',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
