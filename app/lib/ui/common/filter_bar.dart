import 'package:flutter/material.dart';

import '../theme.dart';
import 'layout.dart';

/// Explicit applied labels avoid guessing values from controllers or widgets.
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.children,
    this.onReset,
    this.horizontalOnPhone = false,
    this.appliedFilters = const [],
    this.trailing = const [],
    this.onRemoveFilter,
  });
  final List<Widget> children;
  final List<Widget> trailing;
  final bool horizontalOnPhone;
  final VoidCallback? onReset;
  final List<String> appliedFilters;
  final ValueChanged<int>? onRemoveFilter;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _controls(context),
      if (appliedFilters.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 112),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  for (final entry in appliedFilters.indexed)
                    InputChip(
                      label: Text(entry.$2),
                      deleteButtonTooltipMessage: '${entry.$2} 조건 해제',
                      onDeleted: onRemoveFilter == null
                          ? null
                          : () => onRemoveFilter!(entry.$1),
                    ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget _controls(BuildContext context) {
    final reset = onReset == null
        ? null
        : TextButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.restart_alt),
            label: const Text('초기화'),
          );
    if (AppTheme.isWide(context)) {
      return Padding(
        padding: fieldLabelInsets(context),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: AppSpace.md,
                runSpacing: AppSpace.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: children,
              ),
            ),
            for (final child in trailing)
              Padding(
                padding: const EdgeInsets.only(left: AppSpace.md),
                child: child,
              ),
            if (reset != null) reset,
          ],
        ),
      );
    }
    if (horizontalOnPhone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: fieldLabelInsets(context),
            child: Row(
              children: [
                for (final child in children)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpace.sm),
                    child: child,
                  ),
                if (trailing.isEmpty && reset != null) reset,
              ],
            ),
          ),
          if (trailing.isNotEmpty) ...[
            const SizedBox(height: AppSpace.md),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpace.md,
              runSpacing: AppSpace.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [...trailing, if (reset != null) reset],
            ),
          ],
        ],
      );
    }
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExpansionTile(
            title: Text('검색 조건 ${appliedFilters.length}개 적용'),
            childrenPadding: const EdgeInsets.all(AppSpace.lg),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                ),
                child: SingleChildScrollView(
                  // Leave room inside the scroll clip for floating labels.
                  padding: fieldLabelInsets(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final child in [...children, ...trailing])
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpace.md),
                          child: child,
                        ),
                      if (reset != null)
                        Align(alignment: Alignment.centerRight, child: reset),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
