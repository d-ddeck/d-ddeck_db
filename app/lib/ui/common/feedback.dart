import 'package:flutter/material.dart';

import '../../core/api_exception.dart';
import '../theme.dart';

abstract final class AppSnack {
  static void show(BuildContext context, String message, {bool error = false}) {
    if (!context.mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message, style: TextStyle(color: error ? scheme.onError : scheme.onInverseSurface)),
      backgroundColor: error ? AppColors.danger(context) : scheme.inverseSurface,
    ));
  }
}

/// Shared error reporting; loads retain their error for AsyncView's retry UI.
Future<T> guardedLoad<T>(BuildContext context, Future<T> Function() load) async {
  try {
    return await load();
  } on ApiException catch (error) {
    AppSnack.show(context, error.message, error: true);
    rethrow;
  }
}

Future<bool> runGuarded(BuildContext context, Future<void> Function() action,
    {String? successMessage}) async {
  try {
    await guardedLoad(context, action);
    if (context.mounted && successMessage != null) AppSnack.show(context, successMessage);
    return true;
  } on ApiException {
    return false;
  } catch (error) {
    if (context.mounted) AppSnack.show(context, '오류가 발생했습니다: $error', error: true);
    return false;
  }
}

abstract final class ConfirmDialog {
  static Future<bool> show(BuildContext context, {required String title,
    required String message, String confirmLabel = '확인', bool destructive = false}) async {
    return await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(
            backgroundColor: AppColors.danger(context),
            foregroundColor: Theme.of(context).colorScheme.onError) : null,
          onPressed: () => Navigator.pop(context, true), child: Text(confirmLabel)),
      ],
    )) ?? false;
  }
}

Future<DateTime?> pickDate(BuildContext context, DateTime? initial) {
  final first = DateTime(2000), last = DateTime(2100, 12, 31);
  final date = DateUtils.dateOnly(initial ?? DateTime.now());
  return showDatePicker(context: context, locale: const Locale('ko', 'KR'),
    initialDate: date.isBefore(first) ? first : date.isAfter(last) ? last : date,
    firstDate: first, lastDate: last);
}
