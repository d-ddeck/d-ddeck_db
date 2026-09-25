import 'package:flutter/material.dart';

import '../theme.dart';

/// Explicit applied labels avoid guessing values from controllers or widgets.
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.children, this.onReset,
    this.horizontalOnPhone = false, this.appliedFilters = const []});
  final List<Widget> children;
  final bool horizontalOnPhone;
  final VoidCallback? onReset;
  final List<String> appliedFilters;

  @override
  Widget build(BuildContext context) {
    final reset = onReset == null ? null : TextButton.icon(
      onPressed: onReset, icon: const Icon(Icons.restart_alt), label: const Text('초기화'));
    if (AppTheme.isWide(context)) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Wrap(spacing: AppSpace.md, runSpacing: AppSpace.md,
          crossAxisAlignment: WrapCrossAlignment.center, children: children)),
        if (reset != null) reset,
      ]);
    }
    if (horizontalOnPhone) {
      return SingleChildScrollView(scrollDirection: Axis.horizontal,
      child: Row(children: [for (final child in children) Padding(
        padding: const EdgeInsets.only(right: AppSpace.sm), child: child), if (reset != null) reset]));
    }
    return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ExpansionTile(
        title: Text('검색 조건 ${appliedFilters.length}개 적용'),
        childrenPadding: const EdgeInsets.all(AppSpace.lg),
        children: [ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
          child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final child in children) Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md), child: child),
              if (reset != null) Align(alignment: Alignment.centerRight, child: reset)],
          )),
        )],
      ),
      if (appliedFilters.isNotEmpty) Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.xs,
          children: [for (final label in appliedFilters) Chip(label: Text(label))]),
      ),
    ]));
  }
}
