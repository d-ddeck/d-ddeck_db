import 'package:flutter/material.dart';
import '../theme.dart';
import 'responsive_table.dart';

/// A shared vertical scroll area keeps the pinned identifier and data rows in
/// sync. Only the remaining columns scroll horizontally.
class PinnedTable<T> extends StatefulWidget {
  const PinnedTable({
    super.key,
    required this.rows,
    required this.columns,
    required this.onTap,
    required this.isSelected,
  });
  final List<T> rows;
  final List<TableColumn<T>> columns;
  final ValueChanged<T> onTap;
  final bool Function(T) isSelected;
  @override
  State<PinnedTable<T>> createState() => _PinnedTableState<T>();
}

class _PinnedTableState<T> extends State<PinnedTable<T>> {
  final _horizontal = ScrollController();
  int? _hovered;
  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppTheme.isWide(context)) {
      return ResponsiveTable<T>(
        rows: widget.rows,
        columns: widget.columns,
        onTap: widget.onTap,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final rowHeight =
        (Theme.of(context).visualDensity == VisualDensity.compact
            ? 64.0
            : 76.0) *
        (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.5);
    Widget cell(int rowIndex, int columnIndex) {
      final column = widget.columns[columnIndex];
      final row = rowIndex < 0 ? null : widget.rows[rowIndex];
      final selected =
          rowIndex >= 0 && widget.isSelected(widget.rows[rowIndex]);
      return MouseRegion(
        onEnter: (_) {
          if (rowIndex >= 0) setState(() => _hovered = rowIndex);
        },
        onExit: (_) {
          if (_hovered == rowIndex) setState(() => _hovered = null);
        },
        child: Material(
          color: rowIndex < 0
              ? scheme.surfaceContainerLow
              : selected
              ? scheme.secondaryContainer
              : _hovered == rowIndex
              ? scheme.surfaceContainerHighest
              : scheme.surface,
          child: InkWell(
            onTap: rowIndex < 0
                ? null
                : () => widget.onTap(widget.rows[rowIndex]),
            child: Container(
              height: rowHeight,
              alignment: column.numeric
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: rowIndex < 0
                  ? (column.header ??
                        Text(
                          column.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ))
                  : column.cell(row as T),
            ),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 280,
          child: Column(
            children: [
              for (var i = -1; i < widget.rows.length; i++) cell(i, 0),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: _horizontal,
            thumbVisibility: true,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var col = 1; col < widget.columns.length; col++)
                    SizedBox(
                      width: widget.columns[col].label == '작업'
                          ? 80
                          : widget.columns[col].numeric
                          ? 88
                          : 240,
                      child: Column(
                        children: [
                          for (var i = -1; i < widget.rows.length; i++)
                            cell(i, col),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
