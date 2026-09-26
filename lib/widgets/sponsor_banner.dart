import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';

/// 表示位置ごとのスポンサー画像の基本高さ（px）
///
/// 位置によって存在感を変えるため意図的に異なる高さを返す。
/// 管理画面プレビューやバナー本体表示で共通利用する。
double sponsorImageHeightFor(String placement) {
  switch (placement) {
    case 'home_top':
      return 100;
    case 'home_bottom':
      return 90;
    case 'tournament_list':
      return 80;
    case 'chat_list':
      return 60;
    case 'all':
    default:
      return 80;
  }
}

/// 表示位置ごとに制作すべき画像の推奨サイズ（px, 幅×高さ）
///
/// どの機種でも綺麗に表示されるよう 3x 相当の高解像度を指定。
/// アップロードする画像はこの比率で用意するとトリミングなしで表示される。
({int width, int height}) sponsorRecommendedSizeFor(String placement) {
  switch (placement) {
    case 'home_top':
      return (width: 1080, height: 300); // 3.6:1
    case 'home_bottom':
      return (width: 1080, height: 270); // 4:1
    case 'tournament_list':
      return (width: 1080, height: 240); // 4.5:1
    case 'chat_list':
      return (width: 1080, height: 180); // 6:1
    case 'all':
    default:
      return (width: 1080, height: 240); // 4.5:1
  }
}

/// スポンサー画像URL正規化（Googleドライブ等を直リンクに変換）
///
/// 対応パターン:
///   - https://drive.google.com/file/d/FILE_ID/view?usp=sharing
///   - https://drive.google.com/open?id=FILE_ID
///   - https://drive.google.com/uc?id=FILE_ID&export=view
/// いずれも `https://lh3.googleusercontent.com/d/FILE_ID` に変換する。
/// （`lh3.googleusercontent.com` は CORS / Flutter の CachedNetworkImage と相性が良い）
String normalizeSponsorImageUrl(String url) {
  if (url.isEmpty) return url;
  final trimmed = url.trim();
  if (!trimmed.contains('drive.google.com')) return trimmed;

  String? fileId;
  // /file/d/FILE_ID/...
  final fileDMatch = RegExp(r'/file/d/([a-zA-Z0-9_-]+)').firstMatch(trimmed);
  if (fileDMatch != null) {
    fileId = fileDMatch.group(1);
  }
  // ?id=FILE_ID
  if (fileId == null) {
    final idMatch = RegExp(r'[?&]id=([a-zA-Z0-9_-]+)').firstMatch(trimmed);
    if (idMatch != null) fileId = idMatch.group(1);
  }
  if (fileId == null || fileId.isEmpty) return trimmed;
  return 'https://lh3.googleusercontent.com/d/$fileId';
}

/// スポンサーバナーウィジェット
///
/// [placement] に一致する（または "all" の）アクティブなスポンサーを表示。
/// 日付範囲フィルタ、優先度ソート、セグメント（エリア/年齢/性別）フィルタ、
/// インプレッション/クリック計測に対応。
class SponsorBanner extends StatefulWidget {
  /// 表示位置: "home_top", "home_bottom", "tournament_list", "chat_list"
  final String placement;

  /// 左右の余白。親リストがすでに左右パディングを持つ場合は 0 を渡す
  final double horizontalPadding;

  const SponsorBanner({
    super.key,
    this.placement = 'home_top',
    this.horizontalPadding = 16,
  });

  @override
  State<SponsorBanner> createState() => _SponsorBannerState();
}

class _SponsorBannerState extends State<SponsorBanner> {
  final PageController _pageController = PageController();
  Timer? _autoScrollTimer;
  int _currentPage = 0;
  int _totalPages = 0;

  /// Track which sponsor IDs have already been counted for impressions
  /// in this widget session to avoid duplicate counting.
  final Set<String> _impressionTracked = {};

  // ━━━ セグメント判定用の現在ユーザー情報 ━━━
  String? _userArea; // "東京都" などの都道府県文字列
  String? _userGender; // "男性" / "女性" / "その他"
  int? _userAge;
  bool _profileLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadUserSegment();
  }

  Future<void> _loadUserSegment() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        if (mounted) setState(() => _profileLoaded = true);
        return;
      }
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = userDoc.data();
      if (data != null) {
        final rawArea = data['area'];
        if (rawArea is String) {
          _userArea = rawArea;
        } else if (rawArea is Map) {
          _userArea = (rawArea['prefecture'] as String?) ?? '';
        }
      }

      // gender / birthDate は private/info に入っている
      final privateDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('private')
          .doc('info')
          .get();
      final pd = privateDoc.data();
      if (pd != null) {
        _userGender = pd['gender'] as String?;
        final bd = pd['birthDate'];
        if (bd is Timestamp) {
          final date = bd.toDate();
          final now = DateTime.now();
          int age = now.year - date.year;
          if (now.month < date.month ||
              (now.month == date.month && now.day < date.day)) {
            age -= 1;
          }
          _userAge = age;
        }
      }
    } catch (_) {
      // 失敗時は無視（フィルタ無しで全件表示）
    }
    if (mounted) setState(() => _profileLoaded = true);
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    if (_totalPages <= 1) return;
    _autoScrollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_pageController.hasClients) return;
      final next = (_currentPage + 1) % _totalPages;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });
  }

  Future<void> _openLink(String url, String docId) async {
    // Track click
    FirebaseFirestore.instance
        .collection('sponsors')
        .doc(docId)
        .update({'clickCount': FieldValue.increment(1)});

    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _trackImpression(String docId) {
    if (_impressionTracked.contains(docId)) return;
    _impressionTracked.add(docId);
    FirebaseFirestore.instance
        .collection('sponsors')
        .doc(docId)
        .update({'impressionCount': FieldValue.increment(1)});
  }

  /// セグメントマッチ判定（該当しないなら false）
  bool _matchesSegment(Map<String, dynamic> data) {
    // エリア: targetAreas が空なら全員対象
    final targetAreas = (data['targetAreas'] as List?)?.cast<String>() ?? [];
    if (targetAreas.isNotEmpty) {
      if (_userArea == null || _userArea!.isEmpty) return false;
      final matched = targetAreas.any((a) => _userArea!.contains(a));
      if (!matched) return false;
    }

    // 性別
    final targetGenders =
        (data['targetGenders'] as List?)?.cast<String>() ?? [];
    if (targetGenders.isNotEmpty) {
      if (_userGender == null || _userGender!.isEmpty) return false;
      if (!targetGenders.contains(_userGender)) return false;
    }

    // 年齢
    final minAge = (data['minAge'] as num?)?.toInt();
    final maxAge = (data['maxAge'] as num?)?.toInt();
    if (minAge != null || maxAge != null) {
      if (_userAge == null) return false;
      if (minAge != null && _userAge! < minAge) return false;
      if (maxAge != null && _userAge! > maxAge) return false;
    }

    return true;
  }

  /// Filter and sort sponsors by placement, date range, priority, segment
  List<QueryDocumentSnapshot> _filterAndSort(List<QueryDocumentSnapshot> docs) {
    final now = DateTime.now();
    final filtered = docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      // active フラグ（クエリ側で where を使うとインデックス要件が出るのでクライアント側で）
      if (data['active'] != true) return false;
      // Filter by placement
      final placement = data['placement'] as String? ?? 'home_top';
      if (placement != 'all' && placement != widget.placement) return false;
      // Filter by date range
      final startDate = (data['startDate'] as Timestamp?)?.toDate();
      final endDate = (data['endDate'] as Timestamp?)?.toDate();
      if (startDate != null && now.isBefore(startDate)) return false;
      if (endDate != null && now.isAfter(endDate)) return false;
      // セグメントフィルタ
      if (!_matchesSegment(data)) return false;
      return true;
    }).toList();

    // Sort by priority descending, then shuffle within same priority
    filtered.sort((a, b) {
      final pa = ((a.data() as Map<String, dynamic>)['priority'] as num?)?.toInt() ?? 0;
      final pb = ((b.data() as Map<String, dynamic>)['priority'] as num?)?.toInt() ?? 0;
      if (pa != pb) return pb.compareTo(pa);
      // Random tiebreak for same priority
      return Random().nextInt(3) - 1;
    });

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    // プロフィール読み込み完了前はセグメントフィルタが未確定のため描画しない
    if (!_profileLoaded) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      // where/orderBy を使わず全件取得 → クライアント側でフィルタ
      // （複合インデックスが無いとクエリが失敗してバナーが表示されなかったバグの対策）
      stream: FirebaseFirestore.instance.collection('sponsors').snapshots(),
      builder: (context, snapshot) {
        final allDocs = snapshot.data?.docs ?? [];
        final docs = _filterAndSort(allDocs);
        if (docs.isEmpty) return const SizedBox.shrink();

        // Track impressions for visible sponsors
        for (final doc in docs) {
          _trackImpression(doc.id);
        }

        // Update total pages and restart auto-scroll when data changes
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_totalPages != docs.length) {
            _totalPages = docs.length;
            _startAutoScroll();
          }
        });
        _totalPages = docs.length;

        // バナー総高さは表示位置ごとに完全固定（コメント有無で変動させない）
        //   home_top        : 100   home_bottom     : 90
        //   tournament_list : 80    chat_list       : 60    all : 80
        // コメントがある場合は同じ枠内で画像を縮めて余白を作る
        final pagerHeight = sponsorImageHeightFor(widget.placement);
        final hasAnyComment = docs.any((doc) {
          final d = doc.data() as Map<String, dynamic>;
          return (d['comment'] as String? ?? '').trim().isNotEmpty;
        });
        // コメント行に必要な高さ（text ~14 + 余白 4）
        const commentAreaHeight = 18.0;
        final imageHeight = hasAnyComment
            ? (pagerHeight - commentAreaHeight).clamp(32.0, pagerHeight)
            : pagerHeight;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              SizedBox(
                height: pagerHeight,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: docs.length,
                  onPageChanged: (page) {
                    setState(() => _currentPage = page);
                  },
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final imageUrl = normalizeSponsorImageUrl(
                        data['imageUrl'] as String? ?? '');
                    final linkUrl = data['linkUrl'] as String? ?? '';
                    final comment = (data['comment'] as String? ?? '').trim();

                    return GestureDetector(
                      onTap: linkUrl.isNotEmpty
                          ? () => _openLink(linkUrl, doc.id)
                          : null,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CachedNetworkImage(
                              imageUrl: imageUrl,
                              width: double.infinity,
                              height: imageHeight,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                color: Colors.grey[100],
                                child: const Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppTheme.primaryColor,
                                    ),
                                  ),
                                ),
                              ),
                              errorWidget: (_, __, ___) => Container(
                                color: Colors.grey[100],
                                child: Center(
                                  child: Icon(Icons.broken_image,
                                      color: AppTheme.textHint, size: 28),
                                ),
                              ),
                            ),
                          ),
                          if (comment.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              comment,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
              if (docs.length > 1) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(docs.length, (i) {
                    final isActive = i == _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: isActive ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isActive
                            ? AppTheme.primaryColor
                            : Colors.grey[300],
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
