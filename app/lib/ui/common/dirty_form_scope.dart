import 'package:flutter/material.dart';
import 'feedback.dart';

/// Snapshot values are read at exit time, including controller text and dates.
/// Successful saves use Navigator.pop directly; user back uses maybePop.
class DirtyFormScope extends StatefulWidget {
  const DirtyFormScope({
    super.key,
    required this.child,
    this.snapshot,
    this.isDirty,
    this.ready = true,
    this.busy = false,
  });
  final Widget child;
  final String Function()? snapshot;
  final bool Function()? isDirty;
  final bool ready;
  final bool busy;
  @override
  State<DirtyFormScope> createState() => _DirtyFormScopeState();
}

class _DirtyFormScopeState extends State<DirtyFormScope> {
  String? _baseline;
  bool _confirming = false;
  bool _allowPop = false;
  @override
  Widget build(BuildContext context) {
    if (widget.ready) _baseline ??= widget.snapshot?.call();
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || widget.busy || _confirming) return;
        _confirming = true;
        final dirty =
            widget.isDirty?.call() ??
            (_baseline != null && _baseline != widget.snapshot?.call());
        final leave =
            !dirty ||
            await ConfirmDialog.show(
              context,
              title: '저장하지 않고 나가기',
              message: '변경 사항이 저장되지 않았습니다. 나가시겠습니까?',
              confirmLabel: '나가기',
            );
        if (!mounted) return;
        _confirming = false;
        if (!leave) return;
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop(result);
        });
      },
      child: widget.child,
    );
  }
}
