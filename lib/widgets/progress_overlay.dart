import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// 通信に数秒かかる操作（エントリー・招待の送信や承認など）を、
/// 「送信中…」のくるくる表示を出しながら実行する。
///
/// - ボタンを押した瞬間に表示されるので「反応していない？」と不安にならない
/// - 表示中は画面全体をふさぐので、二度押しで同じ処理が重複しない
/// - 処理が終わる（成功・失敗どちらでも）と自動で閉じる
Future<T> runWithProgress<T>(
  BuildContext context,
  Future<T> Function() task, {
  String message = '送信中…',
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black38,
    builder: (_) => PopScope(
      canPop: false,
      child: Center(
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 3, color: AppTheme.primaryColor),
                ),
                const SizedBox(height: 14),
                Text(message, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  navigator.push(route);
  try {
    return await task();
  } finally {
    if (route.isActive) navigator.removeRoute(route);
  }
}
