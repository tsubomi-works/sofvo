import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/app_theme.dart';
import '../../utils/official_permissions.dart';
import 'recruitment_edit_sheet.dart';

class RecruitmentManagementScreen extends StatefulWidget {
  const RecruitmentManagementScreen({super.key});

  @override
  State<RecruitmentManagementScreen> createState() =>
      _RecruitmentManagementScreenState();
}

class _RecruitmentManagementScreenState
    extends State<RecruitmentManagementScreen> {
  User? get _currentUser => FirebaseAuth.instance.currentUser;
  bool _viewerIsOfficial = false;
  bool _officialLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadOfficialFlag();
  }

  Future<void> _loadOfficialFlag() async {
    final uid = _currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _officialLoaded = true);
      return;
    }
    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (mounted) {
        setState(() {
          _viewerIsOfficial = doc.data()?['isOfficial'] == true;
          _officialLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _officialLoaded = true);
    }
  }

  Query<Map<String, dynamic>> _recruitmentsQuery(String uid) {
    if (_viewerIsOfficial) {
      return FirebaseFirestore.instance
          .collection('recruitments')
          .orderBy('createdAt', descending: true)
          .limit(100);
    }
    return FirebaseFirestore.instance
        .collection('recruitments')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true);
  }

  @override
  Widget build(BuildContext context) {
    final uid = _currentUser?.uid;
    if (uid == null) {
      return Scaffold(
        backgroundColor: AppTheme.backgroundColor,
        appBar: AppBar(title: const Text('メンバー募集管理')),
        body: const Center(child: Text('ログインしてください')),
      );
    }

    if (!_officialLoaded) {
      return Scaffold(
        backgroundColor: AppTheme.backgroundColor,
        appBar: AppBar(title: const Text('メンバー募集管理')),
        body: const Center(
            child: CircularProgressIndicator(color: AppTheme.primaryColor)),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: Text(_viewerIsOfficial ? 'メンバー募集管理（全体）' : 'メンバー募集管理'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _recruitmentsQuery(uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _buildEmptyState();
          }

          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: AppTheme.primaryColor));
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return _buildEmptyState();
          }

          final active = docs.where((d) {
            final data = d.data() as Map<String, dynamic>;
            return data['status'] == '募集中';
          }).toList();

          final closed = docs.where((d) {
            final data = d.data() as Map<String, dynamic>;
            return data['status'] != '募集中';
          }).toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              ..._buildSection('募集中', active),
              if (active.isNotEmpty && closed.isNotEmpty)
                const SizedBox(height: 16),
              ..._buildSection('締切・終了', closed),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_search_outlined,
              size: 80, color: AppTheme.textHint),
          const SizedBox(height: 16),
          const Text('メンバー募集はありません',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const Text('大会詳細画面から\n「メンバー募集する」で作成できます',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  List<Widget> _buildSection(
      String title, List<QueryDocumentSnapshot> items) {
    if (items.isEmpty) return [];
    return [
      Row(
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
          const SizedBox(width: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('${items.length}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryColor)),
          ),
        ],
      ),
      const SizedBox(height: 10),
      ...items.map((doc) {
        final r = doc.data() as Map<String, dynamic>;
        r['docId'] = doc.id;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _buildRecruitmentCard(r),
        );
      }),
    ];
  }

  Widget _buildRecruitmentCard(Map<String, dynamic> r) {
    final status = (r['status'] as String?) ?? '募集中';
    final isActive = status == '募集中';
    final statusColor = isActive ? AppTheme.success : AppTheme.textSecondary;
    final needed = (r['needed'] as int?) ?? 0;
    final approved = (r['approvedCount'] as int?) ?? 0;
    final pending = (r['pendingCount'] as int?) ?? 0;

    return GestureDetector(
      onTap: () => _showRecruitmentDetail(r),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: pending > 0 && isActive
                  ? AppTheme.accentColor.withValues(alpha: 0.5)
                  : Colors.grey[200]!),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: isActive
                        ? AppTheme.accentColor.withValues(alpha: 0.12)
                        : Colors.grey[100],
                    child: Icon(Icons.person_search,
                        color: isActive
                            ? AppTheme.accentColor
                            : AppTheme.textSecondary,
                        size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            ((r['title'] as String?)?.isNotEmpty == true
                                    ? r['title']
                                    : r['tournamentName']) as String? ??
                                '',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textPrimary),
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Text(
                            (r['tournament'] as String?)?.isNotEmpty == true
                                ? r['tournament'] as String
                                : (r['tournamentName'] as String?) ?? '',
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary)),
                        if (_viewerIsOfficial &&
                            (r['userId'] as String?) !=
                                _currentUser?.uid) ...[
                          const SizedBox(height: 2),
                          Text(
                              '投稿: ${(r['nickname'] as String?) ?? 'ユーザー'}',
                              style: const TextStyle(
                                  fontSize: 11, color: AppTheme.textHint)),
                        ],
                      ],
                    ),
                  ),
                  _buildTag(status, statusColor),
                ],
              ),
              const SizedBox(height: 12),
              Row(children: [
                _buildInfoChip(Icons.groups_outlined, (r['team'] as String?) ?? ''),
                const SizedBox(width: 12),
                _buildInfoChip(Icons.people, '$needed人募集'),
              ]),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('承認 $approved/$needed人',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary)),
                            if (pending > 0 && isActive) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.accentColor
                                      .withValues(alpha: 0.12),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                ),
                                child: Text('$pending件 未対応',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: AppTheme.accentColor)),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: needed > 0 ? approved / needed : 0,
                            backgroundColor: Colors.grey[200],
                            color: approved >= needed
                                ? AppTheme.success
                                : AppTheme.primaryColor,
                            minHeight: 6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('締切',
                          style: TextStyle(
                              fontSize: 10,
                              color: AppTheme.textSecondary)),
                      Text((r['deadline'] as String?) ?? '',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openEditRecruitment(String docId, Map<String, dynamic> data) {
    Navigator.of(context)
        .push<bool>(
      MaterialPageRoute(
        builder: (_) => RecruitmentEditSheet(docId: docId, initial: data),
      ),
    );
  }

  void _showRecruitmentDetail(Map<String, dynamic> r) {
    final docId = r['docId'] as String?;
    if (docId == null) return;
    final uid = _currentUser?.uid ?? '';

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: false,
      builder: (routeContext) {
        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            title: const Text('募集詳細', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            centerTitle: true,
            actions: [
              StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('recruitments')
                    .doc(docId)
                    .snapshots(),
                builder: (context, snap) {
                  final data =
                      snap.data?.data() as Map<String, dynamic>? ?? r;
                  final ownerId = (data['userId'] as String?) ?? '';
                  if (!canEditRecruitment(
                    uid: uid,
                    recruitmentUserId: ownerId,
                    viewerIsOfficial: _viewerIsOfficial,
                  )) {
                    return const SizedBox.shrink();
                  }
                  return IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: '編集',
                    onPressed: () => _openEditRecruitment(docId, data),
                  );
                },
              ),
            ],
          ),
          body: StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('recruitments')
                .doc(docId)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
              }
              final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};
              final isActive = data['status'] == '募集中';
              final ownerId = (data['userId'] as String?) ?? '';
              final canManage = canEditRecruitment(
                uid: uid,
                recruitmentUserId: ownerId,
                viewerIsOfficial: _viewerIsOfficial,
              );

              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        ((data['title'] as String?)?.isNotEmpty == true
                                ? data['title']
                                : data['tournamentName']) as String? ??
                            'メンバー募集',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(children: [
                        _buildTag((data['status'] as String?) ?? '',
                            isActive ? AppTheme.success : AppTheme.textSecondary),
                      ]),
                      if (_viewerIsOfficial && ownerId != uid) ...[
                        const SizedBox(height: 8),
                        _buildDetailRow(Icons.person_outline, '投稿者',
                            (data['nickname'] as String?) ?? ownerId),
                      ],
                      const SizedBox(height: 16),
                      _buildDetailRow(Icons.emoji_events, '大会',
                          (data['tournament'] as String?)?.isNotEmpty == true
                              ? data['tournament'] as String
                              : (data['tournamentName'] as String?) ?? ''),
                      _buildDetailRow(Icons.groups, 'チーム',
                          (data['team'] as String?) ?? ''),
                      _buildDetailRow(Icons.people, '募集人数',
                          '${data['needed'] ?? 0}人'),
                      _buildDetailRow(Icons.timer_outlined, '締切',
                          (data['deadline'] as String?) ?? ''),
                      if ((((data['message'] as String?) ?? '').isNotEmpty ||
                          ((data['comment'] as String?) ?? '').isNotEmpty)) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                              (data['message'] as String?)?.isNotEmpty == true
                                  ? data['message'] as String
                                  : (data['comment'] as String?) ?? '',
                              style: const TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.textPrimary,
                                  height: 1.5)),
                        ),
                      ],
                      if (canManage) ...[
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                _openEditRecruitment(docId, data),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('募集内容を編集',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primaryColor,
                              side: const BorderSide(
                                  color: AppTheme.primaryColor, width: 2),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      // 応募者一覧（サブコレクション）
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('recruitments')
                            .doc(docId)
                            .collection('applicants')
                            .orderBy('createdAt', descending: true)
                            .snapshots(),
                        builder: (context, appSnap) {
                          final applicants = appSnap.data?.docs ?? [];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text('応募者',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text('${applicants.length}人',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: AppTheme.primaryColor)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (applicants.isEmpty)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(20),
                                  decoration: BoxDecoration(
                                    color: AppTheme.backgroundColor,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text('まだ応募はありません',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: AppTheme.textSecondary)),
                                )
                              else
                                ...applicants.map((aDoc) {
                                  final a = aDoc.data() as Map<String, dynamic>;
                                  final aStatus = (a['status'] as String?) ?? '承認待ち';
                                  Color aBadgeColor;
                                  switch (aStatus) {
                                    case '承認済':
                                      aBadgeColor = AppTheme.success;
                                      break;
                                    case '拒否':
                                      aBadgeColor = AppTheme.error;
                                      break;
                                    default:
                                      aBadgeColor = AppTheme.accentColor;
                                  }
                                  final name = (a['name'] as String?) ?? 'ユーザー';

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: aStatus == '承認待ち' && isActive
                                          ? AppTheme.accentColor.withValues(alpha: 0.04)
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color: aStatus == '承認待ち' && isActive
                                              ? AppTheme.accentColor.withValues(alpha: 0.3)
                                              : Colors.grey[200]!),
                                    ),
                                    child: Column(
                                      children: [
                                        Row(
                                          children: [
                                            CircleAvatar(
                                              radius: 20,
                                              backgroundColor: AppTheme.primaryColor
                                                  .withValues(alpha: 0.12),
                                              child: Text(
                                                  name.isNotEmpty ? name[0] : '?',
                                                  style: const TextStyle(
                                                      fontWeight: FontWeight.bold,
                                                      color: AppTheme.primaryColor)),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(name,
                                                      style: const TextStyle(
                                                          fontSize: 15,
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                      '競技歴 ${a['experience'] ?? ''}',
                                                      style: const TextStyle(
                                                          fontSize: 12,
                                                          color: AppTheme
                                                              .textSecondary)),
                                                ],
                                              ),
                                            ),
                                            _buildTag(aStatus, aBadgeColor),
                                          ],
                                        ),
                                        if (aStatus == '承認待ち' &&
                                            isActive &&
                                            canManage) ...[
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: OutlinedButton(
                                                  onPressed: () async {
                                                    try {
                                                      await aDoc.reference.update({'status': '拒否'});
                                                    } catch (e) {
                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                                            content: Text('操作に失敗しました'),
                                                            backgroundColor: AppTheme.error));
                                                      }
                                                    }
                                                  },
                                                  style: OutlinedButton.styleFrom(
                                                    foregroundColor: AppTheme.error,
                                                    side: BorderSide(
                                                        color: AppTheme.error
                                                            .withValues(alpha: 0.5)),
                                                  ),
                                                  child: const Text('見送り'),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: ElevatedButton(
                                                  onPressed: () async {
                                                    try {
                                                      await aDoc.reference.update({'status': '承認済'});
                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(context)
                                                            .showSnackBar(SnackBar(
                                                                content: Text(
                                                                    '$nameさんを承認しました！'),
                                                                backgroundColor:
                                                                    AppTheme.success));
                                                      }
                                                    } catch (e) {
                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                                            content: Text('操作に失敗しました'),
                                                            backgroundColor: AppTheme.error));
                                                      }
                                                    }
                                                  },
                                                  child: const Text('承認する'),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  );
                                }),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      if (canManage && data['status'] == '募集中')
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () async {
                              try {
                                await FirebaseFirestore.instance
                                    .collection('recruitments')
                                    .doc(docId)
                                    .update({'status': '締切'});
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(
                                          content: Text('募集を締め切りました'),
                                          backgroundColor: AppTheme.success));
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                      content: Text('操作に失敗しました'),
                                      backgroundColor: AppTheme.error));
                                }
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.error,
                              side: BorderSide(
                                  color: AppTheme.error.withValues(alpha: 0.5)),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text('募集を締め切る',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ),
                        ),
                      const SizedBox(height: 16),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.primaryColor),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _buildInfoChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppTheme.textSecondary),
        const SizedBox(width: 4),
        Text(text,
            style: const TextStyle(
                fontSize: 13, color: AppTheme.textSecondary)),
      ],
    );
  }
}
