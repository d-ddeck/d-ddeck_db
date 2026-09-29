import 'package:flutter/material.dart';

/// Reports whether a section is showing its first tab to the outer shell.
class SectionMainNotification extends Notification {
  const SectionMainNotification(this.isMain);
  final bool isMain;
}

class SectionMainReporter extends StatefulWidget {
  const SectionMainReporter({super.key, this.controller, required this.child});
  final TabController? controller;
  final Widget child;

  @override
  State<SectionMainReporter> createState() => _SectionMainReporterState();
}

class _SectionMainReporterState extends State<SectionMainReporter> {
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attach();
  }

  @override
  void didUpdateWidget(SectionMainReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _attach();
  }

  void _attach() {
    final controller = widget.controller ?? DefaultTabController.of(context);
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_report);
    _controller = controller;
    controller.addListener(_report);
    _report();
  }

  void _report() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        SectionMainNotification(_controller!.index == 0).dispatch(context);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _controller?.removeListener(_report);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
