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
  T? _data;
  bool _hasData = false, _loading = true;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> reload() => _fetch();

  Future<void> _fetch() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _hasData = true;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        // Do not retain records after access was revoked or the target deleted.
        if (error is ApiException &&
            [401, 403, 404].contains(error.statusCode)) {
          _data = null;
          _hasData = false;
        }
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String get _message => _error is ApiException
      ? (_error as ApiException).message
      : '데이터를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.';

  @override
  Widget build(BuildContext context) {
    if (!_hasData) {
      if (_error != null) return ErrorState(message: _message, onRetry: reload);
      return const LoadingState();
    }
    final data = _data as T;
    final empty = widget.emptyCheck?.call(data) == true;
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: reload,
          child: empty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    EmptyState(
                      icon: widget.emptyIcon,
                      message: widget.emptyMessage ?? '아직 등록된 항목이 없습니다',
                      action: OutlinedButton.icon(
                        onPressed: reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('새로고침'),
                      ),
                    ),
                  ],
                )
              : widget.builder(context, data, reload),
        ),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(semanticsLabel: '기존 자료를 표시하며 갱신 중'),
          ),
        if (_error != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      '갱신 실패 · 이전 자료입니다. $_message',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    TextButton(onPressed: reload, child: const Text('다시 시도')),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
