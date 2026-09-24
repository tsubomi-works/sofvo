import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../utils/search_normalize.dart';

/// エントリー画面用のメンバー選択リスト（フォロー中から選ぶ）。
/// - 名前検索ボックス付き（フォロー中が多くても探せる）
/// - 過去に一緒にエントリーした回数が多い人を自動で上位表示（設定不要）
class FollowerMemberPicker extends StatefulWidget {
  final String uid;
  final Map<String, String> selectedMembers;
  final void Function(String uid, String name) onToggle;
  /// 指定すると、この大会で既に成立エントリー／承認待ちドラフトに
  /// 含まれている人を選択不可（グレーアウト）にする。
  final String? tournamentId;
  /// エントリー編集時、自分自身のエントリーIDは重複チェックから除外する
  /// （このエントリー自身のメンバーを「他で使用中」と誤判定しないため）。
  final String? excludeEntryId;

  const FollowerMemberPicker({
    super.key,
    required this.uid,
    required this.selectedMembers,
    required this.onToggle,
    this.tournamentId,
    this.excludeEntryId,
  });

  /// 大会内で既に「成立エントリー」または「辞退していない承認待ちドラフト」に
  /// 含まれている uid → チーム名。createEntryDraft/updateEntryMembers の
  /// サーバー側重複チェックと同じロジック（クライアント側の事前案内用）。
  static Future<Map<String, String>> loadTakenMap(
    String tournamentId, {
    String? excludeEntryId,
  }) async {
    final taken = <String, String>{};
    try {
      final tRef = FirebaseFirestore.instance.collection('tournaments').doc(tournamentId);
      final results = await Future.wait([
        tRef.collection('entries').get(),
        tRef.collection('entryDrafts').get(),
      ]);
      final entriesSnap = results[0];
      final draftsSnap = results[1];
      for (final d in entriesSnap.docs) {
        if (d.id == excludeEntryId) continue;
        final data = d.data();
        final uids = List<String>.from((data['memberUids'] as List?) ?? []);
        for (final u in uids) {
          taken[u] = (data['teamName'] ?? '既存のチーム').toString();
        }
      }
      for (final d in draftsSnap.docs) {
        final data = d.data();
        final approvals = Map<String, dynamic>.from(data['approvals'] as Map? ?? {});
        final invited = List<String>.from((data['invitedUids'] as List?) ?? []);
        for (final u in invited) {
          if (approvals[u] == 'declined') continue;
          taken[u] = (data['teamName'] ?? '招待中のチーム').toString();
        }
      }
    } catch (_) {
      // 取得に失敗しても選択自体は続行する（最終的にはサーバー側で弾かれる）
    }
    return taken;
  }

  /// uid → 一緒にエントリーした回数。ダイアログを開き直しても再計算しないようキャッシュ
  static final Map<String, Map<String, int>> _teammateCountsCache = {};

  /// 過去の大会（pointHistory）から「一緒にエントリーした回数」を集計する
  static Future<Map<String, int>> loadTeammateCounts(String uid) async {
    final cached = _teammateCountsCache[uid];
    if (cached != null) return cached;

    final counts = <String, int>{};
    try {
      final firestore = FirebaseFirestore.instance;
      final ph = await firestore
          .collection('users')
          .doc(uid)
          .collection('pointHistory')
          .get();
      // 直近20大会まで（読み取り量の上限）
      final tournamentIds = ph.docs.map((d) => d.id).take(20).toList();
      for (final tid in tournamentIds) {
        final entries = await firestore
            .collection('tournaments')
            .doc(tid)
            .collection('entries')
            .get();
        for (final e in entries.docs) {
          final data = e.data();
          final uids = <String>{
            ...List<String>.from((data['memberUids'] as List?) ?? []),
          };
          final leaderUid = (data['leaderUid'] ?? '').toString();
          final enteredBy = (data['enteredBy'] ?? '').toString();
          if (leaderUid.isNotEmpty) uids.add(leaderUid);
          if (enteredBy.isNotEmpty) uids.add(enteredBy);
          if (!uids.contains(uid)) continue; // 自分のチームのみ
          for (final m in uids) {
            if (m == uid) continue;
            counts[m] = (counts[m] ?? 0) + 1;
          }
        }
      }
    } catch (_) {
      // 集計に失敗しても一覧表示自体は続行する
    }
    _teammateCountsCache[uid] = counts;
    return counts;
  }

  @override
  State<FollowerMemberPicker> createState() => _FollowerMemberPickerState();
}

class _FollowerMemberPickerState extends State<FollowerMemberPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final firestore = FirebaseFirestore.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 名前検索 ──
        TextField(
          controller: _searchController,
          onChanged: (v) => setState(() => _query = normalizeForSearch(v.trim())),
          decoration: InputDecoration(
            hintText: '名前で検索',
            hintStyle: const TextStyle(fontSize: 13),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                  )
                : null,
            filled: true,
            fillColor: AppTheme.backgroundColor,
            isDense: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot>(
          stream: firestore
              .collection('users')
              .doc(widget.uid)
              .collection('following')
              .snapshots(),
          builder: (context, followSnap) {
            if (!followSnap.hasData) {
              return const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryColor));
            }
            final followings = followSnap.data!.docs;
            if (followings.isEmpty) {
              return _emptyBox('フォロー中のユーザーがいません');
            }
            return FutureBuilder<List<dynamic>>(
              future: Future.wait([
                Future.wait(followings
                    .map((f) => firestore.collection('users').doc(f.id).get())),
                FollowerMemberPicker.loadTeammateCounts(widget.uid),
                widget.tournamentId != null
                    ? FollowerMemberPicker.loadTakenMap(widget.tournamentId!,
                        excludeEntryId: widget.excludeEntryId)
                    : Future.value(<String, String>{}),
              ]),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(
                      child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(
                              color: AppTheme.primaryColor)));
                }
                final userDocs = snap.data![0] as List<DocumentSnapshot>;
                final counts = snap.data![1] as Map<String, int>;
                final taken = snap.data![2] as Map<String, String>;

                // 表示リストを構築（検索フィルタ → よく組む人順）
                final items = <_PickerItem>[];
                for (int i = 0; i < followings.length; i++) {
                  final doc = userDocs[i];
                  if (!doc.exists) continue;
                  final data = doc.data() as Map<String, dynamic>? ?? {};
                  final name = (data['nickname'] ?? '名前なし').toString();
                  if (_query.isNotEmpty &&
                      !normalizeForSearch(name).contains(_query)) {
                    continue;
                  }
                  // 同じ名前の別アカウントを誤って招待しないよう、
                  // 見分けの手がかりとして都道府県を表示する
                  final rawArea = data['area'];
                  final area = rawArea is String
                      ? rawArea
                      : rawArea is Map
                          ? '${rawArea['prefecture'] ?? ''}${rawArea['city'] ?? ''}'
                          : '';
                  items.add(_PickerItem(
                    uid: followings[i].id,
                    name: name,
                    area: area,
                    avatarUrl: (data['avatarUrl'] ?? '').toString(),
                    teammateCount: counts[followings[i].id] ?? 0,
                    takenByTeamName: taken[followings[i].id],
                  ));
                }
                items.sort((a, b) {
                  final c = b.teammateCount.compareTo(a.teammateCount);
                  return c != 0 ? c : a.name.compareTo(b.name);
                });

                if (items.isEmpty) {
                  return _emptyBox(_query.isNotEmpty
                      ? '「${_searchController.text}」に一致する人がいません'
                      : 'フォロー中のユーザーがいません');
                }

                return Container(
                  constraints: const BoxConstraints(maxHeight: 250),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[200]!),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final isSelected =
                          widget.selectedMembers.containsKey(item.uid);
                      // 既に選択中（このエントリー自身のメンバー）なら、他で
                      // 使用中でも選択解除できるよう通常表示のままにする
                      final isTaken = item.takenByTeamName != null && !isSelected;
                      return ListTile(
                        dense: item.teammateCount == 0,
                        enabled: !isTaken,
                        leading: Opacity(
                          opacity: isTaken ? 0.4 : 1,
                          child: item.avatarUrl.isNotEmpty
                              ? CircleAvatar(
                                  backgroundImage: NetworkImage(item.avatarUrl),
                                  radius: 18)
                              : CircleAvatar(
                                  radius: 18,
                                  backgroundColor: AppTheme.primaryColor
                                      .withValues(alpha: 0.1),
                                  child: Text(
                                      item.name.isNotEmpty ? item.name[0] : '?',
                                      style: const TextStyle(
                                          color: AppTheme.primaryColor))),
                        ),
                        title: Row(children: [
                          Flexible(
                            child: Text(item.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: isTaken ? Colors.grey[400] : null)),
                          ),
                          if (item.area.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Text('（${item.area}）',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: isTaken ? Colors.grey[400] : AppTheme.textHint)),
                          ],
                        ]),
                        subtitle: isTaken
                            ? Text('「${item.takenByTeamName}」に招待中/エントリー済み',
                                style: TextStyle(fontSize: 11, color: Colors.grey[400]))
                            : item.teammateCount > 0
                                ? Text('一緒にエントリー ${item.teammateCount}回',
                                    style: TextStyle(
                                        fontSize: 11, color: AppTheme.accentColor))
                                : null,
                        trailing: isTaken
                            ? Icon(Icons.block, color: Colors.grey[400], size: 20)
                            : isSelected
                                ? const Icon(Icons.check_circle,
                                    color: AppTheme.primaryColor)
                                : Icon(Icons.circle_outlined,
                                    color: Colors.grey[400]),
                        onTap: isTaken ? null : () => widget.onToggle(item.uid, item.name),
                      );
                    },
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _emptyBox(String message) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppTheme.backgroundColor,
          borderRadius: BorderRadius.circular(12)),
      child: Center(
          child:
              Text(message, style: const TextStyle(color: AppTheme.textHint))),
    );
  }
}

class _PickerItem {
  final String uid;
  final String name;
  final String area;
  final String avatarUrl;
  final int teammateCount;
  final String? takenByTeamName;
  _PickerItem({
    required this.uid,
    required this.name,
    required this.area,
    required this.avatarUrl,
    required this.teammateCount,
    this.takenByTeamName,
  });
}
