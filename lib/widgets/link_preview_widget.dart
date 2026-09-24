import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../config/app_theme.dart';
import '../utils/in_app_link.dart';
import '../utils/tournament_checkin_link.dart';

/// OGPメタデータ
class OgpData {
  final String title;
  final String description;
  final String? imageUrl;
  final String siteName;
  final String url;

  OgpData({
    required this.title,
    required this.description,
    this.imageUrl,
    required this.siteName,
    required this.url,
  });
}

/// URLからOGPデータを取得
Future<OgpData?> fetchOgpData(String url) async {
  try {
    final uri = Uri.parse(url);
    final response = await http.get(uri, headers: {
      'User-Agent': 'Mozilla/5.0 (compatible; SofvoBot/1.0)',
    }).timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) return null;

    final html = response.body;
    final title = _extractMeta(html, 'og:title') ??
        _extractTitle(html) ??
        uri.host;
    final description = _extractMeta(html, 'og:description') ??
        _extractMeta(html, 'description', useProperty: false) ??
        '';
    final imageUrl = _extractMeta(html, 'og:image');
    final siteName = _extractMeta(html, 'og:site_name') ?? uri.host;

    return OgpData(
      title: title,
      description: description,
      imageUrl: imageUrl != null ? _resolveUrl(imageUrl, uri) : null,
      siteName: siteName,
      url: url,
    );
  } catch (_) {
    return null;
  }
}

String? _extractMeta(String html, String name, {bool useProperty = true}) {
  // og:xxx は property 属性、description は name 属性
  final attr = useProperty ? 'property' : 'name';
  final patterns = [
    RegExp('<meta\\s+$attr=["\']$name["\']\\s+content=["\']([^"\']*)["\']',
        caseSensitive: false),
    RegExp('<meta\\s+content=["\']([^"\']*)["\']\\s+$attr=["\']$name["\']',
        caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(html);
    if (match != null) {
      final value = match.group(1)?.trim();
      if (value != null && value.isNotEmpty) return _decodeHtmlEntities(value);
    }
  }
  // og:description がなければ name="description" もチェック
  if (useProperty && name == 'og:description') {
    return _extractMeta(html, 'description', useProperty: false);
  }
  return null;
}

String? _extractTitle(String html) {
  final match =
      RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true)
          .firstMatch(html);
  if (match != null) {
    final value = match.group(1)?.trim();
    if (value != null && value.isNotEmpty) return _decodeHtmlEntities(value);
  }
  return null;
}

String _resolveUrl(String url, Uri base) {
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  if (url.startsWith('//')) return '${base.scheme}:$url';
  return base.resolve(url).toString();
}

String _decodeHtmlEntities(String text) {
  return text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
}

/// URLプレビューカード（LINEのようなOGP表示）
class LinkPreviewWidget extends StatefulWidget {
  final String url;
  final bool isMe;

  const LinkPreviewWidget({
    super.key,
    required this.url,
    required this.isMe,
  });

  @override
  State<LinkPreviewWidget> createState() => _LinkPreviewWidgetState();
}

class _LinkPreviewWidgetState extends State<LinkPreviewWidget> {
  OgpData? _ogpData;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    final data =
        await _fetchSofvoTournamentPreview() ?? await fetchOgpData(widget.url);
    if (!mounted) return;
    setState(() {
      _ogpData = data;
      _loading = false;
      _error = data == null;
    });
  }

  /// Sofvo の大会リンクは OGP ではなく大会情報（大会名・日付・会場）でプレビューする
  Future<OgpData?> _fetchSofvoTournamentPreview() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return null;
    final tid = parseCheckInTournamentIdFromDeepLinkUri(uri) ??
        parseSofvoTournamentIdFromUri(uri);
    if (tid == null || tid.isEmpty) return null;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('tournaments')
          .doc(tid)
          .get();
      if (!doc.exists) return null;
      final d = doc.data()!;
      final title = (d['title'] ?? d['name'] ?? '大会').toString();
      final details = [
        d['date'] is String ? d['date'] as String : '',
        (d['location'] ?? d['venue'] ?? '').toString(),
      ].where((s) => s.isNotEmpty).join(' / ');
      return OgpData(
        title: title,
        description: details,
        siteName: 'Sofvo 大会',
        url: widget.url,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: _boxDecoration(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: widget.isMe ? Colors.white70 : AppTheme.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'リンクを読み込み中...',
              style: TextStyle(
                fontSize: 12,
                color: widget.isMe ? Colors.white70 : AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    if (_error || _ogpData == null) return const SizedBox.shrink();

    final ogp = _ogpData!;
    return GestureDetector(
      onTap: () => openLinkInAppOrExternal(context, widget.url),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        constraints: const BoxConstraints(maxWidth: 260),
        decoration: _boxDecoration(),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // OGP画像
            if (ogp.imageUrl != null)
              Image.network(
                ogp.imageUrl!,
                width: double.infinity,
                height: 130,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            // タイトル・説明・サイト名
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ogp.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: widget.isMe ? Colors.white : AppTheme.textPrimary,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (ogp.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      ogp.description,
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.isMe
                            ? Colors.white70
                            : AppTheme.textSecondary,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.link,
                        size: 12,
                        color: widget.isMe
                            ? Colors.white54
                            : AppTheme.textHint,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          ogp.siteName,
                          style: TextStyle(
                            fontSize: 10,
                            color: widget.isMe
                                ? Colors.white54
                                : AppTheme.textHint,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _boxDecoration() {
    return BoxDecoration(
      color: widget.isMe
          ? Colors.white.withValues(alpha: 0.15)
          : Colors.grey[100],
      borderRadius: BorderRadius.circular(10),
      border: widget.isMe
          ? Border.all(color: Colors.white.withValues(alpha: 0.2))
          : Border.all(color: Colors.grey[300]!),
    );
  }
}
