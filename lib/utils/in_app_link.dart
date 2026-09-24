import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../screens/tournament/tournament_detail_screen.dart';
import 'tournament_checkin_link.dart';

/// sofvo.com の大会URLから大会IDを取り出す。
///
/// 対応形式:
/// - `https://sofvo.com/?t={id}`（大会共有リンク）
/// - `https://sofvo.com/tournament/{id}`
/// - `sofvo://…?t={id}`
String? parseSofvoTournamentIdFromUri(Uri uri) {
  if (uri.scheme != 'sofvo') {
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final host = uri.host.toLowerCase();
    if (host != 'sofvo.com' && host != 'www.sofvo.com') return null;
  }
  final t = uri.queryParameters['t']?.trim();
  if (t != null && t.isNotEmpty) return t;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length >= 2 && segs[0] == 'tournament') return segs[1];
  return null;
}

/// チャット等のリンクをタップしたときの共通処理。
/// Sofvo の大会リンクはアプリ内の大会詳細を開き、それ以外は外部ブラウザで開く。
Future<void> openLinkInAppOrExternal(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;

  final checkInId = parseCheckInTournamentIdFromDeepLinkUri(uri);
  final tournamentId = checkInId ?? parseSofvoTournamentIdFromUri(uri);
  if (tournamentId != null && tournamentId.isNotEmpty) {
    final navigator = Navigator.of(context);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('tournaments')
          .doc(tournamentId)
          .get();
      if (doc.exists) {
        final data = doc.data()!;
        data['id'] = doc.id;
        navigator.push(MaterialPageRoute(
          builder: (_) => TournamentDetailScreen(
            tournament: data,
            autoCheckIn: checkInId != null,
          ),
        ));
        return;
      }
    } catch (e) {
      debugPrint('大会リンクのアプリ内遷移に失敗: $e');
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('大会が見つかりませんでした')),
      );
    }
    return;
  }

  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
