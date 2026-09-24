import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'tournament_detail_screen.dart';
import 'tournament_finance_screen.dart';
import 'tournament_rules_screen.dart';
import 'venue_search_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import '../../config/app_theme.dart';
import '../../utils/tournament_status.dart';

/// エントリー締切日（`yyyy/M/d`）がローカル暦で「今日より前」なら true（当日はまだ募集中扱い）
bool _tournamentDeadlineDatePassed(String deadline) {
  final m = RegExp(r'^(\d{4})/(\d{1,2})/(\d{1,2})$').firstMatch(deadline.trim());
  if (m == null) return false;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final deadlineDate = DateTime(y, mo, d);
  final n = DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  return deadlineDate.isBefore(today);
}

class TournamentManagementScreen extends StatefulWidget {
  const TournamentManagementScreen({super.key});
  @override
  State<TournamentManagementScreen> createState() => _TournamentManagementScreenState();
}

class _TournamentManagementScreenState extends State<TournamentManagementScreen> {
  User? get _currentUser => FirebaseAuth.instance.currentUser;

  static const _iconOptions = <String, IconData>{
    'emoji_events': Icons.emoji_events,
    'sports_volleyball': Icons.sports_volleyball,
    'sports': Icons.sports,
    'star': Icons.star,
    'bolt': Icons.bolt,
    'local_fire_department': Icons.local_fire_department,
    'diamond': Icons.diamond,
    'shield': Icons.shield,
    'flag': Icons.flag,
    'military_tech': Icons.military_tech,
    'workspace_premium': Icons.workspace_premium,
    'celebration': Icons.celebration,
  };

  IconData _getIcon(String? iconName) {
    if (iconName == null || !_iconOptions.containsKey(iconName)) return Icons.emoji_events;
    return _iconOptions[iconName]!;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUser == null) {
      return Scaffold(appBar: AppBar(title: const Text('大会管理')),
          body: const Center(child: Text('ログインしてください')));
    }
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(title: const Text('大会管理')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('tournaments')
            .where('organizerId', isEqualTo: _currentUser!.uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('読み込みに失敗しました', style: TextStyle(color: AppTheme.textSecondary)));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
          }
          final docs = (snapshot.data?.docs ?? [])
              .where((d) => (d.data() as Map<String, dynamic>)['isDemo'] != true)
              .toList(); // 体験デモ大会は除外
          if (docs.isEmpty) return _buildEmptyState();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              return Padding(padding: const EdgeInsets.only(bottom: 12), child: _buildTournamentCard(docs[index]));
            },
          );
        },
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'template',
            onPressed: _showTemplatePickerSheet,
            backgroundColor: Colors.white,
            child: const Icon(Icons.description_outlined, color: AppTheme.primaryColor, size: 20),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.extended(
            heroTag: 'create',
            onPressed: _showCreateTournamentSheet,
            backgroundColor: AppTheme.primaryColor,
            icon: const Icon(Icons.add, color: Colors.white),
            label: const Text('大会を作成', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.emoji_events_outlined, size: 80, color: AppTheme.textHint),
        const SizedBox(height: 16),
        const Text('まだ主催大会がありません', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
        const SizedBox(height: 8),
        const Text('大会を作成して参加者を募集しましょう！', style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
      ]),
    );
  }

  /// entries サブコレクションの実数をカウント（denormalized な currentTeams が
  /// ズレていてもエントリー数表示が正しくなるようにする）。読み取り失敗時は null を
  /// 返し、呼び出し側で currentTeams にフォールバックする。
  Future<int?> _entriesCount(String docId) async {
    try {
      final agg = await FirebaseFirestore.instance
          .collection('tournaments').doc(docId).collection('entries')
          .count().get();
      return agg.count;
    } catch (_) {
      return null;
    }
  }

  Widget _buildTournamentCard(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final title = data['title'] ?? '無名大会';
    final date = data['date'] ?? '';
    final location = data['location'] ?? '';
    final status = normalizeTournamentStatus(data['status'] ?? '準備中');
    final rawFee = data['entryFee'];
    final entryFee = rawFee is int ? '¥$rawFee' : (rawFee ?? '¥0').toString();
    final fallbackTeams = (data['currentTeams'] is num) ? (data['currentTeams'] as num).toInt() : 0;
    final maxTeams = data['maxTeams'] ?? 8;
    final courts = data['courts'] ?? 0;
    final type = data['type'] ?? '混合';
    Color statusColor;
    switch (status) {
      case '募集中': statusColor = AppTheme.success; break;
      case 'エントリー締切': statusColor = AppTheme.accentColor; break;
      case '大会準備中':
        statusColor = AppTheme.primaryLight;
        break;
      case '準備中': statusColor = AppTheme.warning; break;
      case '開催中': statusColor = AppTheme.primaryColor; break;
      default: statusColor = AppTheme.textSecondary;
    }
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournament: {...data, 'id': doc.id, 'name': data['title'] ?? ''}))),
      child: Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey[200]!)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GestureDetector(
              onTap: () => _showIconPicker(doc.id, data['icon'] as String?),
              child: CircleAvatar(radius: 20, backgroundColor: AppTheme.primaryColor.withValues(alpha:0.12),
                  child: Icon(_getIcon(data['icon'] as String?), color: AppTheme.primaryColor, size: 20)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Row(children: [
                _buildTag(status, statusColor), const SizedBox(width: 6),
                if (type.isNotEmpty) _buildTag(type, AppTheme.primaryColor),
              ]),
            ])),
            IconButton(
              icon: Icon(Icons.arrow_forward_ios, color: AppTheme.textSecondary, size: 18),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournament: {...data, 'id': doc.id, 'name': data['title'] ?? ''}))),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            _buildInfoChip(Icons.calendar_today_outlined, date), const SizedBox(width: 16),
            _buildInfoChip(Icons.location_on_outlined, location),
          ]),
          if (courts > 0) ...[const SizedBox(height: 6), _buildInfoChip(Icons.grid_view, '$courtsコート')],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: FutureBuilder<int?>(
              future: _entriesCount(doc.id),
              builder: (context, snap) {
                final currentTeams = snap.data ?? fallbackTeams;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('エントリー $currentTeams/$maxTeamsチーム', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const SizedBox(height: 6),
                  ClipRRect(borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: maxTeams > 0 ? (currentTeams / maxTeams).clamp(0.0, 1.0) : 0,
                        backgroundColor: Colors.grey[200], color: AppTheme.primaryColor, minHeight: 6)),
                ]);
              },
            )),
            const SizedBox(width: 16),
            Text(entryFee, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
          ]),
        ]),
      ),
    ));
  }

  void _showIconPicker(String docId, String? currentIcon) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('アイコンを変更', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _iconOptions.entries.map((entry) {
            final isSelected = (currentIcon ?? 'emoji_events') == entry.key;
            return GestureDetector(
              onTap: () async {
                try {
                  await FirebaseFirestore.instance.collection('tournaments').doc(docId).update({'icon': entry.key});
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text('操作に失敗しました'),
                        backgroundColor: AppTheme.error));
                  }
                }
              },
              child: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: isSelected ? AppTheme.primaryColor.withValues(alpha: 0.15) : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                  border: isSelected ? Border.all(color: AppTheme.primaryColor, width: 2) : null,
                ),
                child: Icon(entry.value, color: isSelected ? AppTheme.primaryColor : AppTheme.textSecondary, size: 24),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ══════════════════════════════════════
  //  Status / Delete dialogs
  // ══════════════════════════════════════

  void _showStatusDialog(String docId, String currentStatus) {
    final statuses = ['準備中', '募集中', 'エントリー締切', '大会準備中', '開催中', '終了'];
    showDialog(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('ステータス変更', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, children: statuses.map((s) {
        return RadioListTile<String>(title: Text(s), value: s, groupValue: currentStatus, activeColor: AppTheme.primaryColor,
          onChanged: (v) async {
            if (v != null) {
              final update = <String, dynamic>{'status': v};
              // 大会が「開催中」に切り替わった実時刻をサーバー時刻で記録（予定時刻
              // date+matchStartTime との差で進行開始の遅延を算出できる）。
              if (v == '開催中' && currentStatus != '開催中') {
                update['wentLiveAt'] = FieldValue.serverTimestamp();
              }
              await FirebaseFirestore.instance.collection('tournaments').doc(docId).update(update);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ステータスを「$v」に変更しました'), backgroundColor: AppTheme.success));
            }
          });
      }).toList()),
    ));
  }

  void _showDeleteDialog(String docId, String title) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('大会を削除', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      content: Text('「$title」を削除しますか？\nこの操作は取り消せません。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text('キャンセル', style: TextStyle(color: AppTheme.textSecondary))),
        ElevatedButton(
          onPressed: () async {
            await FirebaseFirestore.instance.collection('tournaments').doc(docId).delete();
            if (ctx.mounted) Navigator.pop(ctx);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('「$title」を削除しました'), backgroundColor: AppTheme.error));
          },
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
          child: const Text('削除する'),
        ),
      ],
    ));
  }

  // ══════════════════════════════════════
  //  Edit Tournament Sheet
  // ══════════════════════════════════════

  void _showEditTournamentSheet(String docId, Map<String, dynamic> data) {
    final titleCtrl = TextEditingController(text: data['title'] ?? '');
    final locationCtrl = TextEditingController(text: data['location'] ?? '');
    final rawFee = data['entryFee'];
    final feeCtrl = TextEditingController(text: (rawFee is int ? rawFee : int.tryParse(rawFee.toString().replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toString());
    final maxTeamsCtrl = TextEditingController(text: (data['maxTeams'] ?? 8).toString());
    final courtsCtrl = TextEditingController(text: (data['courts'] ?? 2).toString());
    final descriptionCtrl = TextEditingController(text: data['description'] ?? '');
    String selectedType = data['type'] ?? '混合';
    String selectedDate = data['date'] ?? '';
    String selectedDeadline = data['deadline'] ?? '';
    Map<String, dynamic>? tournamentRules = (data['rules'] is Map) ? Map<String, dynamic>.from(data['rules']) : null;
    Map<String, dynamic>? selectedVenue;
    if (data['venueId'] != null && (data['venueId'] as String).isNotEmpty) {
      selectedVenue = {'id': data['venueId'], 'name': data['location'], 'address': data['venueAddress'] ?? ''};
    }
    final origTitle = titleCtrl.text; final origLocation = locationCtrl.text; final origFee = feeCtrl.text;
    final origMaxTeams = maxTeamsCtrl.text; final origCourts = courtsCtrl.text; final origType = selectedType;
    final origDate = selectedDate; final origRules = tournamentRules; final origVenue = selectedVenue;
    final origDeadline = selectedDeadline; final origDescription = descriptionCtrl.text;
    bool saving = false;

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) => StatefulBuilder(builder: (ctx, setPageState) {
        bool hasChanges() => titleCtrl.text != origTitle || locationCtrl.text != origLocation || feeCtrl.text != origFee ||
            maxTeamsCtrl.text != origMaxTeams || courtsCtrl.text != origCourts || selectedType != origType ||
            selectedDate != origDate || tournamentRules != origRules || selectedVenue != origVenue ||
            selectedDeadline != origDeadline || descriptionCtrl.text != origDescription;

        Future<bool> onWillPop() async {
          if (!hasChanges()) return true;
          final result = await showDialog<String>(context: ctx, builder: (dlgCtx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('編集内容の保存'), content: const Text('変更が保存されていません。保存してから閉じますか？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dlgCtx, 'discard'), child: const Text('保存しない', style: TextStyle(color: AppTheme.textSecondary))),
              TextButton(onPressed: () => Navigator.pop(dlgCtx, 'cancel'), child: const Text('編集に戻る')),
              ElevatedButton(onPressed: titleCtrl.text.trim().isNotEmpty && selectedDate.isNotEmpty && locationCtrl.text.trim().isNotEmpty
                  ? () => Navigator.pop(dlgCtx, 'save') : null,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white), child: const Text('保存する')),
            ],
          ));
          if (result == 'save') {
            try {
              final currentStatus = normalizeTournamentStatus(data['status'] ?? '', emptyAsPreparing: false);
              final updateMap = <String, dynamic>{
                'title': titleCtrl.text.trim(), 'date': selectedDate, 'location': locationCtrl.text.trim(),
                'courts': int.tryParse(courtsCtrl.text) ?? 2, 'maxTeams': int.tryParse(maxTeamsCtrl.text) ?? 8,
                'entryFee': int.tryParse(feeCtrl.text.trim()) ?? 0, 'type': selectedType,
                'venueId': selectedVenue?['id'] ?? '', 'venueAddress': selectedVenue?['address'] ?? '',
                'area': _extractArea(selectedVenue?['address'] ?? ''),
                'deadline': selectedDeadline, 'description': descriptionCtrl.text.trim(),
                'rules': tournamentRules ?? {},
              };
              if (selectedDeadline.isNotEmpty &&
                  _tournamentDeadlineDatePassed(selectedDeadline) &&
                  (currentStatus == '募集中' || currentStatus == '満員')) {
                updateMap['status'] = 'エントリー締切';
              }
              await FirebaseFirestore.instance.collection('tournaments').doc(docId).update(updateMap);
              if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content: Text('大会情報を更新しました！'), backgroundColor: AppTheme.success));
              return true;
            } catch (e) {
              if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e'), backgroundColor: AppTheme.error));
              return false;
            }
          }
          return result == 'discard';
        }

        return PopScope(canPop: false, onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final shouldPop = await onWillPop();
          if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
        }, child: Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () async {
              final shouldPop = await onWillPop();
              if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
            }),
            title: const Text('大会を編集', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), centerTitle: true),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('大会名 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(controller: titleCtrl, maxLength: 30, onChanged: (_) => setPageState(() {}), decoration: _sheetInputDecoration('大会名を入力')),
              const SizedBox(height: 8),
              const Text('開催日 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: ctx, initialDate: DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (picked != null) setPageState(() => selectedDate = '${picked.year}/${picked.month.toString().padLeft(2, '0')}/${picked.day.toString().padLeft(2, '0')}');
                },
                child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [Icon(Icons.calendar_today, size: 18, color: AppTheme.textSecondary), const SizedBox(width: 10),
                    Text(selectedDate.isEmpty ? '日付を選択' : selectedDate, style: TextStyle(fontSize: 15, color: selectedDate.isEmpty ? AppTheme.textHint : AppTheme.textPrimary))])),
              ),
              const SizedBox(height: 12),
              const Text('エントリー締切', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: ctx, initialDate: DateTime.now().add(const Duration(days: 14)),
                      firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (picked != null) setPageState(() => selectedDeadline = '${picked.year}/${picked.month.toString().padLeft(2, '0')}/${picked.day.toString().padLeft(2, '0')}');
                },
                child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(Icons.event_busy, size: 18, color: selectedDeadline.isEmpty ? AppTheme.textSecondary : AppTheme.warning), const SizedBox(width: 10),
                    Expanded(child: Text(selectedDeadline.isEmpty ? '締切日を選択（任意）' : selectedDeadline, style: TextStyle(fontSize: 15, color: selectedDeadline.isEmpty ? AppTheme.textHint : AppTheme.textPrimary))),
                    if (selectedDeadline.isNotEmpty) GestureDetector(onTap: () => setPageState(() => selectedDeadline = ''), child: Icon(Icons.close, size: 18, color: Colors.grey[400])),
                  ])),
              ),
              const SizedBox(height: 16),
              const Text('会場 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.push<Map<String, dynamic>>(ctx, MaterialPageRoute(builder: (_) => const VenueSearchScreen(pickerMode: true)));
                  if (result != null) setPageState(() { selectedVenue = result; locationCtrl.text = result['name'] ?? ''; courtsCtrl.text = (result['courts'] ?? courtsCtrl.text).toString(); });
                },
                child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [Icon(selectedVenue != null ? Icons.check_circle : Icons.search, size: 18, color: selectedVenue != null ? AppTheme.success : AppTheme.textSecondary),
                    const SizedBox(width: 10), Expanded(child: Text(locationCtrl.text.isNotEmpty ? locationCtrl.text : '会場を探す',
                      style: TextStyle(fontSize: 15, color: locationCtrl.text.isNotEmpty ? AppTheme.textPrimary : AppTheme.textHint)))])),
              ),
              if (selectedVenue != null && (selectedVenue!['address'] ?? '').toString().isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(selectedVenue!['address'], style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('使用コート数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                  TextField(controller: courtsCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('2'), onChanged: (_) => setPageState(() {}))])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('募集チーム数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                  TextField(controller: maxTeamsCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('8'), onChanged: (_) => setPageState(() {}))])),
              ]),
              const SizedBox(height: 8),
              Builder(builder: (_) {
                final courts = int.tryParse(courtsCtrl.text) ?? 2; final teams = int.tryParse(maxTeamsCtrl.text) ?? 8;
                final tpc = courts > 0 ? (teams / courts).ceil() : teams;
                return Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(10)),
                  child: Text('1コート $tpc チーム（自動計算）', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)));
              }),
              const SizedBox(height: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('参加費（円）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                TextField(controller: feeCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('3000'))]),
              const SizedBox(height: 16),
              const Text('カテゴリ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: ['混合', 'メンズ', 'レディース'].map((t) {
                return ChoiceChip(label: Text(t), selected: selectedType == t,
                    onSelected: (s) { if (s) setPageState(() => selectedType = t); },
                    selectedColor: AppTheme.primaryColor.withValues(alpha:0.15));
              }).toList()),
              const SizedBox(height: 16),
              const Text('大会説明・備考', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(controller: descriptionCtrl, maxLines: 3, onChanged: (_) => setPageState(() {}),
                decoration: _sheetInputDecoration('参加者への注意事項やアピールを記入（任意）')),
              const SizedBox(height: 24),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(
                onPressed: () async {
                  final result = await Navigator.push<Map<String, dynamic>>(context,
                    MaterialPageRoute(builder: (_) => TournamentRulesScreen(initialRules: tournamentRules, courtCount: int.tryParse(courtsCtrl.text), maxTeams: int.tryParse(maxTeamsCtrl.text), entryFee: int.tryParse(feeCtrl.text))));
                  if (result != null) setPageState(() { tournamentRules = result; });
                },
                icon: Icon(tournamentRules != null ? Icons.check_circle : Icons.tune, color: tournamentRules != null ? AppTheme.success : AppTheme.primaryColor),
                label: Text(tournamentRules != null ? 'ルール設定済み' : 'ルールを設定する',
                    style: TextStyle(fontWeight: FontWeight.w600, color: tournamentRules != null ? AppTheme.success : AppTheme.primaryColor)),
                style: OutlinedButton.styleFrom(side: BorderSide(color: tournamentRules != null ? AppTheme.success : AppTheme.primaryColor),
                  padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
              const SizedBox(height: 24),
              SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: !saving && titleCtrl.text.trim().isNotEmpty && selectedDate.isNotEmpty && locationCtrl.text.trim().isNotEmpty
                    ? () async {
                        setPageState(() => saving = true);
                        try {
                          final currentStatus = normalizeTournamentStatus(data['status'] ?? '', emptyAsPreparing: false);
                          final updateMap = <String, dynamic>{
                            'title': titleCtrl.text.trim(), 'date': selectedDate, 'location': locationCtrl.text.trim(),
                            'courts': int.tryParse(courtsCtrl.text) ?? 2, 'maxTeams': int.tryParse(maxTeamsCtrl.text) ?? 8,
                            'entryFee': int.tryParse(feeCtrl.text.trim()) ?? 0, 'type': selectedType,
                            'venueId': selectedVenue?['id'] ?? '', 'venueAddress': selectedVenue?['address'] ?? '',
                            'area': _extractArea(selectedVenue?['address'] ?? ''),
                            'deadline': selectedDeadline, 'description': descriptionCtrl.text.trim(),
                            'rules': tournamentRules ?? {},
                          };
                          if (selectedDeadline.isNotEmpty &&
                              _tournamentDeadlineDatePassed(selectedDeadline) &&
                              (currentStatus == '募集中' || currentStatus == '満員')) {
                            updateMap['status'] = 'エントリー締切';
                          }
                          await FirebaseFirestore.instance.collection('tournaments').doc(docId).update(updateMap);
                          if (ctx.mounted) { Navigator.pop(ctx); }
                          if (mounted) { ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content: Text('大会情報を更新しました！'), backgroundColor: AppTheme.success)); }
                        } catch (e) {
                          if (ctx.mounted) { setPageState(() => saving = false); ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e'), backgroundColor: AppTheme.error)); }
                        }
                      } : null,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[300], padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: saving
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('保存する', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))),
            ])),
        ));
      }),
    ));
  }

  // ══════════════════════════════════════
  //  Create Tournament Sheet
  // ══════════════════════════════════════

  void _showCreateTournamentSheet({Map<String, dynamic>? templateData}) {
    final titleCtrl = TextEditingController();
    final locationCtrl = TextEditingController(text: (templateData?['location'] ?? '') as String);
    final feeCtrl = TextEditingController(text: (templateData?['entryFee'] ?? '3000').toString().replaceAll(RegExp(r'[^0-9]'), ''));
    final maxTeamsCtrl = TextEditingController(text: (templateData?['maxTeams'] ?? 8).toString());
    final courtsCtrl = TextEditingController(text: (templateData?['courts'] ?? 2).toString());
    final descriptionCtrl = TextEditingController();
    String selectedType = (templateData?['type'] ?? '混合') as String;
    String selectedDate = '';
    String selectedDeadline = '';
    Map<String, dynamic>? tournamentRules = (templateData?['rules'] is Map) ? Map<String, dynamic>.from(templateData!['rules']) : null;
    Map<String, dynamic>? selectedVenue;
    if (templateData != null && templateData['venueId'] != null && (templateData['venueId'] as String).isNotEmpty) {
      selectedVenue = {'id': templateData['venueId'], 'name': templateData['location'], 'address': templateData['venueAddress'] ?? ''};
    }
    String openTime = (templateData?['openTime'] ?? '') as String;
    String receptionTime = (templateData?['receptionTime'] ?? '') as String;
    String captainMeetingTime = (templateData?['captainMeetingTime'] ?? '') as String;
    String openingTime = (templateData?['openingTime'] ?? '') as String;
    String matchStartTime = (templateData?['matchStartTime'] ?? '') as String;
    String finalTime = (templateData?['finalTime'] ?? '') as String;
    String closingTime = (templateData?['closingTime'] ?? '') as String;

    // 時間フォーマット正規化（9:00 → 09:00）
    String _fmtTime(String t) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t.trim());
      if (m != null) return '${m.group(1)!.padLeft(2, '0')}:${m.group(2)!}';
      return t;
    }
    openTime = _fmtTime(openTime);
    receptionTime = _fmtTime(receptionTime);
    captainMeetingTime = _fmtTime(captainMeetingTime);
    openingTime = _fmtTime(openingTime);
    matchStartTime = _fmtTime(matchStartTime);
    finalTime = _fmtTime(finalTime);
    closingTime = _fmtTime(closingTime);
    Uint8List? rulesPdfBytes;
    String? rulesPdfName;
    bool isUploadingPdf = false;

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (_) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          bool hasInput() => titleCtrl.text.isNotEmpty || locationCtrl.text.isNotEmpty || selectedDate.isNotEmpty;

          Future<bool> onWillPop() async {
            if (!hasInput()) return true;
            final result = await showDialog<bool>(context: ctx, builder: (dlgCtx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('入力内容の破棄'), content: const Text('入力した内容が失われますが、よろしいですか？'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dlgCtx, false), child: const Text('編集に戻る')),
                ElevatedButton(onPressed: () => Navigator.pop(dlgCtx, true),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white), child: const Text('破棄する')),
              ],
            ));
            return result ?? false;
          }

          return PopScope(canPop: false, onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final shouldPop = await onWillPop();
            if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
          }, child: Scaffold(
            backgroundColor: AppTheme.backgroundColor,
            appBar: AppBar(
              leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () async {
                final shouldPop = await onWillPop();
                if (shouldPop && ctx.mounted) Navigator.of(ctx).pop();
              }),
              title: Text(templateData != null ? 'テンプレートから作成' : '新しい大会を作成', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), centerTitle: true),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('大会名 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(controller: titleCtrl, maxLength: 30, onChanged: (_) => setSheetState(() {}), decoration: _sheetInputDecoration('大会名を入力')),
              const SizedBox(height: 8),
              const Text('開催日 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: ctx, initialDate: DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (picked != null) setSheetState(() => selectedDate = '${picked.year}/${picked.month.toString().padLeft(2, '0')}/${picked.day.toString().padLeft(2, '0')}');
                },
                child: Container(
                  width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(Icons.calendar_today, size: 18, color: AppTheme.textSecondary), const SizedBox(width: 10),
                    Text(selectedDate.isEmpty ? '日付を選択' : selectedDate, style: TextStyle(fontSize: 15, color: selectedDate.isEmpty ? AppTheme.textHint : AppTheme.textPrimary)),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              const Text('エントリー締切', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: ctx, initialDate: DateTime.now().add(const Duration(days: 14)),
                      firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (picked != null) setSheetState(() => selectedDeadline = '${picked.year}/${picked.month.toString().padLeft(2, '0')}/${picked.day.toString().padLeft(2, '0')}');
                },
                child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(Icons.event_busy, size: 18, color: selectedDeadline.isEmpty ? AppTheme.textSecondary : AppTheme.warning), const SizedBox(width: 10),
                    Expanded(child: Text(selectedDeadline.isEmpty ? '締切日を選択（任意）' : selectedDeadline, style: TextStyle(fontSize: 15, color: selectedDeadline.isEmpty ? AppTheme.textHint : AppTheme.textPrimary))),
                    if (selectedDeadline.isNotEmpty) GestureDetector(onTap: () => setSheetState(() => selectedDeadline = ''), child: Icon(Icons.close, size: 18, color: Colors.grey[400])),
                  ])),
              ),
              const SizedBox(height: 16),
              const Text('会場 *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.push<Map<String, dynamic>>(ctx, MaterialPageRoute(builder: (_) => const VenueSearchScreen(pickerMode: true)));
                  if (result != null) setSheetState(() { selectedVenue = result; locationCtrl.text = result['name'] ?? ''; courtsCtrl.text = (result['courts'] ?? courtsCtrl.text).toString(); });
                },
                child: Container(
                  width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(selectedVenue != null ? Icons.check_circle : Icons.search, size: 18, color: selectedVenue != null ? AppTheme.success : AppTheme.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(selectedVenue != null ? selectedVenue!['name'] ?? '' : '会場を探す',
                        style: TextStyle(fontSize: 15, color: selectedVenue != null ? AppTheme.textPrimary : AppTheme.textHint))),
                  ]),
                ),
              ),
              if (selectedVenue != null && (selectedVenue!['address'] ?? '').toString().isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(selectedVenue!['address'], style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('使用コート数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                  TextField(controller: courtsCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('2'),
                    onChanged: (_) => setSheetState(() {})),
                ])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('募集チーム数', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                  TextField(controller: maxTeamsCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('8'),
                    onChanged: (_) => setSheetState(() {})),
                ])),
              ]),
              const SizedBox(height: 8),
              Builder(builder: (_) {
                final courts = int.tryParse(courtsCtrl.text) ?? 2;
                final teams = int.tryParse(maxTeamsCtrl.text) ?? 8;
                final tpc = courts > 0 ? (teams / courts).ceil() : teams;
                return Container(
                  width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(10)),
                  child: Text('1コート $tpc チーム（自動計算）', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                );
              }),
              const SizedBox(height: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('参加費（円）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
                TextField(controller: feeCtrl, keyboardType: TextInputType.number, decoration: _sheetInputDecoration('3000')),
              ]),
              const SizedBox(height: 16),
              const Text('カテゴリ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: ['混合', 'メンズ', 'レディース'].map((t) {
                return ChoiceChip(label: Text(t), selected: selectedType == t,
                    onSelected: (s) { if (s) setSheetState(() => selectedType = t); },
                    selectedColor: AppTheme.primaryColor.withValues(alpha:0.15));
              }).toList()),
              const SizedBox(height: 16),
              const Text('大会説明・備考', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(controller: descriptionCtrl, maxLines: 3, onChanged: (_) => setSheetState(() {}),
                decoration: _sheetInputDecoration('参加者への注意事項やアピールを記入（任意）')),
              const SizedBox(height: 24),
              // ── スケジュール設定 ──
              Row(children: [
                const Text('当日スケジュール', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    final courts = int.tryParse(courtsCtrl.text) ?? 2;
                    final maxTeams = int.tryParse(maxTeamsCtrl.text) ?? 8;
                    final teamsPerCourt = (tournamentRules?['management'] as Map<String, dynamic>?)?['teamsPerCourt'] ?? 4;
                    final actualCourts = ((maxTeams / teamsPerCourt).ceil()).clamp(1, courts);
                    final tpc = (maxTeams / actualCourts).ceil();
                    final matchesPerCourt = tpc * (tpc - 1) ~/ 2;
                    final prelimRounds = (tournamentRules?['preliminary'] as Map<String, dynamic>?)?['rounds'] ?? 1;
                    const minutesPerMatch = 10;
                    final totalPrelimMinutes = matchesPerCourt * minutesPerMatch * (prelimRounds as int);
                    final mst = matchStartTime.isNotEmpty ? matchStartTime : '09:15';
                    final parts = mst.split(':');
                    final startH = int.tryParse(parts[0]) ?? 9;
                    final startM = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
                    final startMinutes = startH * 60 + startM;
                    final finalsStart = startMinutes + totalPrelimMinutes + 15;
                    final closingStart = finalsStart + 60;
                    String fmt(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
                    final endTime = finalsStart + 60;
                    final clearOutTime = endTime + 30;
                    setSheetState(() {
                      openTime = fmt(startMinutes - 75);
                      receptionTime = fmt(startMinutes - 45);
                      captainMeetingTime = fmt(startMinutes - 30);
                      openingTime = fmt(startMinutes - 15);
                      if (matchStartTime.isEmpty) matchStartTime = fmt(startMinutes);
                      finalTime = fmt(endTime);
                      closingTime = fmt(clearOutTime);
                    });
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text('予選 $matchesPerCourt試合×${prelimRounds}R（各${minutesPerMatch}分）で自動計算しました'),
                        backgroundColor: AppTheme.success,
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: AppTheme.accentColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_fix_high, size: 14, color: AppTheme.accentColor),
                      const SizedBox(width: 4),
                      Text('自動計算', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
                    ]),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  _buildTimeRow('開場 *', openTime, (v) => setSheetState(() => openTime = v), ctx),
                  _buildTimeRow('受付', receptionTime, (v) => setSheetState(() => receptionTime = v), ctx),
                  _buildTimeRow('キャプテン会議', captainMeetingTime, (v) => setSheetState(() => captainMeetingTime = v), ctx),
                  _buildTimeRow('開会式', openingTime, (v) => setSheetState(() => openingTime = v), ctx),
                  _buildTimeRow('試合開始 *', matchStartTime, (v) => setSheetState(() => matchStartTime = v), ctx),
                  _buildTimeRow('終了 *', finalTime, (v) => setSheetState(() => finalTime = v), ctx),
                  _buildTimeRow('完全撤退', closingTime, (v) => setSheetState(() => closingTime = v), ctx),
                ]),
              ),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(
                onPressed: () async {
                  final result = await Navigator.push<Map<String, dynamic>>(context,
                    MaterialPageRoute(builder: (_) => TournamentRulesScreen(initialRules: tournamentRules, courtCount: int.tryParse(courtsCtrl.text), maxTeams: int.tryParse(maxTeamsCtrl.text), entryFee: int.tryParse(feeCtrl.text), startTime: matchStartTime, endTime: finalTime)));
                  if (result != null) setSheetState(() {
                    tournamentRules = result;
                  });
                },
                icon: Icon(tournamentRules != null ? Icons.check_circle : Icons.tune, color: tournamentRules != null ? AppTheme.success : AppTheme.primaryColor),
                label: Text(tournamentRules != null ? 'ルール設定済み ✓' : 'ルールを設定する',
                    style: TextStyle(fontWeight: FontWeight.w600, color: tournamentRules != null ? AppTheme.success : AppTheme.primaryColor)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: tournamentRules != null ? AppTheme.success : AppTheme.primaryColor),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              )),
              const SizedBox(height: 12),
              // ── ルールPDFアップロード ──
              const Text('ルールPDF（任意）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('大会要項やルールのPDFをアップロードできます', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              if (rulesPdfName != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.success.withValues(alpha: 0.3))),
                  child: Row(children: [
                    Icon(Icons.picture_as_pdf, color: AppTheme.error, size: 22),
                    const SizedBox(width: 10),
                    Expanded(child: Text(rulesPdfName!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                    GestureDetector(
                      onTap: () => setSheetState(() { rulesPdfBytes = null; rulesPdfName = null; }),
                      child: Icon(Icons.close, size: 18, color: Colors.grey[500]),
                    ),
                  ]),
                )
              else
                SizedBox(width: double.infinity, child: OutlinedButton.icon(
                  onPressed: isUploadingPdf ? null : () async {
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['pdf'],
                      withData: true,
                    );
                    if (result != null && result.files.single.bytes != null) {
                      final file = result.files.single;
                      if (file.size > 10 * 1024 * 1024) {
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('ファイルサイズは10MB以下にしてください'), backgroundColor: AppTheme.error));
                        return;
                      }
                      setSheetState(() { rulesPdfBytes = file.bytes; rulesPdfName = file.name; });
                    }
                  },
                  icon: const Icon(Icons.upload_file),
                  label: const Text('PDFを選択'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                    side: BorderSide(color: Colors.grey[300]!),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: titleCtrl.text.trim().isNotEmpty && selectedDate.isNotEmpty && locationCtrl.text.trim().isNotEmpty && !isUploadingPdf
                    ? () async {
                        setSheetState(() => isUploadingPdf = rulesPdfBytes != null);
                        final userDoc = await FirebaseFirestore.instance.collection('users').doc(_currentUser!.uid).get();
                        final nickname = (userDoc.data()?['nickname'] ?? '不明').toString();

                        // PDF をアップロード
                        String? pdfUrl;
                        String? pdfName;
                        if (rulesPdfBytes != null && rulesPdfName != null) {
                          try {
                            final timestamp = DateTime.now().millisecondsSinceEpoch;
                            final ref = FirebaseStorage.instance.ref().child('tournament_rules/${_currentUser!.uid}/${timestamp}_$rulesPdfName');
                            await ref.putData(rulesPdfBytes!, SettableMetadata(contentType: 'application/pdf'));
                            pdfUrl = await ref.getDownloadURL();
                            pdfName = rulesPdfName;
                          } catch (e) {
                            if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('PDFアップロードに失敗しました: $e'), backgroundColor: AppTheme.error));
                            setSheetState(() => isUploadingPdf = false);
                            return;
                          }
                        }

                        final initialStatus = selectedDeadline.isNotEmpty &&
                                _tournamentDeadlineDatePassed(selectedDeadline)
                            ? 'エントリー締切'
                            : '募集中';

                        final tournamentData = <String, dynamic>{
                          'title': titleCtrl.text.trim(), 'date': selectedDate, 'location': locationCtrl.text.trim(),
                          'venueId': selectedVenue?['id'] ?? '', 'venueAddress': selectedVenue?['address'] ?? '',
                          'courts': int.tryParse(courtsCtrl.text) ?? 2, 'maxTeams': int.tryParse(maxTeamsCtrl.text) ?? 8,
                          'currentTeams': 0, 'entryFee': int.tryParse(feeCtrl.text.trim()) ?? 0, 'type': selectedType,
                          'deadline': selectedDeadline, 'description': descriptionCtrl.text.trim(),
                          'area': _extractArea(selectedVenue?['address'] ?? ''),
                          'status': initialStatus, 'organizerId': _currentUser!.uid, 'organizerName': nickname,
                          'openTime': openTime, 'receptionTime': receptionTime, 'captainMeetingTime': captainMeetingTime, 'openingTime': openingTime,
                          'matchStartTime': matchStartTime, 'finalTime': finalTime, 'closingTime': closingTime,
                          'entryTeamIds': [], 'rules': tournamentRules ?? {}, 'createdAt': FieldValue.serverTimestamp(),
                          'isCertified': false,
                          if (pdfUrl != null) 'rulesPdfUrl': pdfUrl,
                          if (pdfName != null) 'rulesPdfName': pdfName,
                        };
                        final docRef = await FirebaseFirestore.instance.collection('tournaments').add(tournamentData);
                        if (mounted) {
                          Navigator.pop(ctx);
                          Navigator.push(this.context, MaterialPageRoute(
                            builder: (_) => TournamentDetailScreen(tournament: {...tournamentData, 'id': docRef.id, 'name': titleCtrl.text.trim(), 'isFollowing': true}),
                          ));
                        }
                      } : null,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[300], padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('大会を作成', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              )),
              const SizedBox(height: 8),
            ])),
          ));
        });
      },
    ));
  }

  // ══════════════════════════════════════
  //  Template: テンプレートから作成
  // ══════════════════════════════════════

  void _showTemplatePickerSheet() {
    final uid = _currentUser?.uid;
    if (uid == null) return;

    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(child: Text('テンプレートから作成', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
            const SizedBox(height: 4),
            Text('保存したテンプレートを使って大会を作成できます', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users').doc(uid).collection('templates')
                  .orderBy('createdAt', descending: true).snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
                final templates = snap.data!.docs;
                if (templates.isEmpty) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: AppTheme.backgroundColor, borderRadius: BorderRadius.circular(12)),
                    child: Column(children: [
                      Icon(Icons.description_outlined, size: 40, color: AppTheme.textHint),
                      const SizedBox(height: 8),
                      const Text('テンプレートがありません', style: TextStyle(color: AppTheme.textSecondary)),
                      const SizedBox(height: 4),
                      Text('大会カードのメニューから「テンプレートに保存」できます', style: TextStyle(fontSize: 12, color: AppTheme.textHint)),
                    ]),
                  );
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: templates.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final tData = templates[index].data() as Map<String, dynamic>;
                      final name = tData['name'] ?? 'テンプレート';
                      final type = tData['type'] ?? '';
                      final maxTeams = tData['maxTeams'] ?? 8;
                      return ListTile(
                        leading: Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.description_outlined, color: AppTheme.primaryColor, size: 20),
                        ),
                        title: Text(name.toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('$type  $maxTeamsチーム', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        trailing: const Icon(Icons.chevron_right, color: AppTheme.textHint),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showCreateTournamentSheet(templateData: tData);
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ]),
        );
      },
    );
  }

  /// 大会データからテンプレート保存
  Future<void> _saveAsTemplate(Map<String, dynamic> data) async {
    final uid = _currentUser?.uid;
    if (uid == null) return;
    final title = data['title'] ?? '大会';
    final rules = data['rules'] as Map<String, dynamic>? ?? {};
    final preliminary = rules['preliminary'] as Map<String, dynamic>? ?? {};

    await FirebaseFirestore.instance
        .collection('users').doc(uid).collection('templates').add({
      'name': '$titleのテンプレート',
      'type': data['type'] ?? '混合',
      'maxTeams': data['maxTeams'] ?? 8,
      'setCount': (preliminary['sets'] ?? '3').toString(),
      'pointsPerSet': (preliminary['pointsPerSet'] ?? '25').toString(),
      'location': data['location'] ?? '',
      'memo': '',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('テンプレートに保存しました'), backgroundColor: AppTheme.success),
      );
    }
  }

  // ══════════════════════════════════════
  //  Helpers
  // ══════════════════════════════════════

  static String _extractArea(String address) {
    const prefectures = [
      '北海道', '青森県', '岩手県', '宮城県', '秋田県', '山形県', '福島県',
      '茨城県', '栃木県', '群馬県', '埼玉県', '千葉県', '東京都', '神奈川県',
      '新潟県', '富山県', '石川県', '福井県', '山梨県', '長野県', '岐阜県',
      '静岡県', '愛知県', '三重県', '滋賀県', '京都府', '大阪府', '兵庫県',
      '奈良県', '和歌山県', '鳥取県', '島根県', '岡山県', '広島県', '山口県',
      '徳島県', '香川県', '愛媛県', '高知県', '福岡県', '佐賀県', '長崎県',
      '熊本県', '大分県', '宮崎県', '鹿児島県', '沖縄県',
    ];
    for (final p in prefectures) {
      if (address.startsWith(p)) return p;
    }
    return '';
  }

  InputDecoration _sheetInputDecoration(String hint) {
    return InputDecoration(hintText: hint, hintStyle: const TextStyle(color: AppTheme.textHint),
      filled: true, fillColor: AppTheme.backgroundColor,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none));
  }

  Widget _buildTag(String text, Color color) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha:0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)));
  }

  Widget _buildTimeRow(String label, String value, Function(String) onChanged, BuildContext ctx) {
    final isRequired = label.contains('*');
    final isEmpty = value.isEmpty || value == '--:--' || value == '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(
          child: GestureDetector(
            onTap: () {
              final parts = (isEmpty ? '08:00' : value).split(':');
              var h = int.tryParse(parts[0]) ?? 8;
              var m = ((int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0) ~/ 5) * 5;
              final hourCtrl = FixedExtentScrollController(initialItem: h);
              final minCtrl = FixedExtentScrollController(initialItem: m ~/ 5);
              showModalBottomSheet(
                context: ctx,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                builder: (_) => SizedBox(
                  height: 280,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
                          const Text('時刻を選択', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          TextButton(
                            onPressed: () {
                              onChanged('${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}');
                              Navigator.pop(ctx);
                            },
                            child: const Text('完了', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Row(children: [
                        Expanded(
                          child: CupertinoPicker(
                            scrollController: hourCtrl,
                            itemExtent: 40,
                            onSelectedItemChanged: (i) => h = i,
                            children: List.generate(24, (i) => Center(child: Text('${i.toString().padLeft(2, '0')}時', style: const TextStyle(fontSize: 20)))),
                          ),
                        ),
                        Expanded(
                          child: CupertinoPicker(
                            scrollController: minCtrl,
                            itemExtent: 40,
                            onSelectedItemChanged: (i) => m = i * 5,
                            children: List.generate(12, (i) => Center(child: Text('${(i * 5).toString().padLeft(2, '0')}分', style: const TextStyle(fontSize: 20)))),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey[200]!)),
              child: Text(isEmpty ? '--:--' : value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isEmpty ? Colors.grey[400] : null)),
            ),
          ),
        ),
        if (!isRequired && !isEmpty)
          GestureDetector(
            onTap: () => onChanged('--:--'),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.close, size: 18, color: Colors.grey[400]),
            ),
          ),
      ]),
    );
  }

  Widget _buildInfoChip(IconData icon, String text) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: AppTheme.textSecondary), const SizedBox(width: 4),
      Text(text, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
    ]);
  }
}
