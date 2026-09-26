import 'package:flutter/material.dart';

import '../../core/api_exception.dart';
import '../theme.dart';

abstract final class AppSnack {
  static void saved(
    BuildContext context, {
    required String label,
    required Widget Function() detail,
  }) {
    final navigator = Navigator.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label 저장되었습니다.'),
        action: SnackBarAction(
          label: '상세 보기',
          onPressed: () {
            if (navigator.mounted) {
              navigator.push(MaterialPageRoute<void>(builder: (_) => detail()));
            }
          },
        ),
      ),
    );
  }

  static void show(BuildContext context, String message, {bool error = false}) {
    if (!context.mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            color: error ? scheme.onError : scheme.onInverseSurface,
          ),
        ),
        backgroundColor: error
            ? AppColors.danger(context)
            : scheme.inverseSurface,
      ),
    );
  }
}

/// Shared error reporting; loads retain their error for AsyncView's retry UI.
Future<T> guardedLoad<T>(
  BuildContext context,
  Future<T> Function() load,
) async {
  try {
    return await load();
  } on ApiException catch (error) {
    AppSnack.show(context, error.message, error: true);
    rethrow;
  }
}

Future<bool> runGuarded(
  BuildContext context,
  Future<void> Function() action, {
  String? successMessage,
}) async {
  try {
    await guardedLoad(context, action);
    if (context.mounted && successMessage != null) {
      AppSnack.show(context, successMessage);
    }
    return true;
  } on ApiException {
    return false;
  } catch (error) {
    if (context.mounted) {
      AppSnack.show(context, '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.', error: true);
    }
    return false;
  }
}

class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog.form({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.destructive = false,
    this.constraints,
  });
  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final bool destructive;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    constraints: constraints,
    title: title,
    content: content,
    actions: [
      for (final action in actions)
        destructive
            ? Theme(
                data: Theme.of(context).copyWith(
                  filledButtonTheme: FilledButtonThemeData(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger(context),
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                  ),
                ),
                child: action,
              )
            : action,
    ],
  );

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = '확인',
    bool destructive = false,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => ConfirmDialog.form(
            title: Text(title),
            content: SingleChildScrollView(child: Text(message)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: AppColors.danger(context),
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      )
                    : null,
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }
}

Future<DateTime?> pickDate(
  BuildContext context,
  DateTime? initial, {
  DateTime? firstDate,
  DateTime? lastDate,
}) {
  final first = firstDate ?? DateTime(2000),
      last = lastDate ?? DateTime(2100, 12, 31);
  final date = DateUtils.dateOnly(initial ?? DateTime.now());
  return showDatePicker(
    context: context,
    locale: const Locale('ko', 'KR'),
    initialDate: date.isBefore(first)
        ? first
        : date.isAfter(last)
        ? last
        : date,
    firstDate: first,
    lastDate: last,
  );
}
