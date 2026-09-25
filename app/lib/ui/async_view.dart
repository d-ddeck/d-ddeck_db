import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import 'common/states.dart';

export 'common/feedback.dart' show runGuarded;

/// Load-once-with-retry wrapper.
///
/// Every module screen has the same three states (spinner / error+retry /
/// content); this keeps that from being re-implemented five times, and makes
/// sure an ApiException is shown with its Korean message instead of a
/// framework error box.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    required this.load,
    required this.builder,
    this.emptyCheck,
    this.emptyMessage,
    this.emptyIcon = Icons.inbox_outlined,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, VoidCallback reload)
      builder;

  /// Return true when [T] carries no rows, to show the empty placeholder.
  final bool Function(T data)? emptyCheck;
  final String? emptyMessage;
  final IconData emptyIcon;

  @override
  State<AsyncView<T>> createState() => AsyncViewState<T>();
}

class AsyncViewState<T> extends State<AsyncView<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void reload() => setState(() => _future = widget.load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingState();
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          return ErrorState(
            message: error is ApiException
                ? error.message
                : '데이터를 불러오지 못했습니다.\n$error',
            onRetry: reload,
          );
        }
        final data = snapshot.data as T;
        if (widget.emptyCheck?.call(data) == true) {
          return RefreshIndicator(
            onRefresh: () async => reload(),
            child: ListView(
              children: [
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.5,
                  child: EmptyState(
                    icon: widget.emptyIcon,
                    message: widget.emptyMessage ?? '아직 등록된 항목이 없습니다',
                    action: OutlinedButton.icon(onPressed: reload, icon: const Icon(Icons.refresh), label: const Text('새로고침')),
                  ),
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => reload(),
          child: widget.builder(context, data, reload),
        );
      },
    );
  }
}
