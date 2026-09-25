import 'package:flutter/material.dart';

import '../theme.dart';
import 'states.dart';

class TableColumn<T> {
  const TableColumn({required this.label, required this.cell,
    this.numeric = false, this.flex = 1}) : assert(flex > 0);
  final String label;
  final Widget Function(T row) cell;
  final bool numeric;
  final int flex;
}

class ResponsiveTable<T> extends StatelessWidget {
  const ResponsiveTable({super.key, required this.columns, required this.rows,
    this.onTap}) : assert(columns.length > 0);
  final List<TableColumn<T>> columns;
  final List<T> rows;
  final ValueChanged<T>? onTap;

  /// Keep cell actions when migrating existing reports to phone cards.
  static Widget fromDataRows({required List<DataColumn> columns, required List<DataRow> rows}) =>
      ResponsiveTable<DataRow>(
        columns: [for (final entry in columns.indexed) TableColumn<DataRow>(
          label: (entry.$2.label as Text).data ?? '',
          numeric: entry.$2.numeric,
          cell: (row) {
            final cell = row.cells[entry.$1];
            if (cell.onTap == null) return cell.child;
            return InkWell(onTap: cell.onTap, child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Align(alignment: entry.$2.numeric ? Alignment.centerRight : Alignment.centerLeft,
                child: cell.child),
            ));
          },
        )],
        rows: rows,
      );

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const EmptyState(message: '아직 등록된 항목이 없습니다');
    if (AppTheme.isWide(context)) {
      return LayoutBuilder(builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0),
          child: DataTable(
            showCheckboxColumn: false,
            border: TableBorder(horizontalInside: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
            columns: [for (final column in columns) DataColumn(
              label: Text(column.label), numeric: column.numeric,
              columnWidth: IntrinsicColumnWidth(flex: column.flex.toDouble()),
            )],
            rows: [for (final row in rows) DataRow(
              onSelectChanged: onTap == null ? null : (_) => onTap!(row),
              cells: [for (final column in columns) DataCell(column.cell(row))],
            )],
          ),
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final row in rows) Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.md),
        child: Card(child: InkWell(
          onTap: onTap == null ? null : () => onTap!(row),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(padding: const EdgeInsets.all(AppSpace.lg), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(child: DefaultTextStyle.merge(style: const TextStyle(fontWeight: FontWeight.w700), child: columns.first.cell(row))),
                if (onTap != null) const Icon(Icons.chevron_right),
              ]),
              for (final column in columns.skip(1)) Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Text('${column.label}:', style: TextStyle(color: AppColors.muted(context)))),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(flex: column.flex, child: Align(
                    alignment: column.numeric ? Alignment.centerRight : Alignment.centerLeft,
                    child: column.cell(row))),
                ]),
              ),
            ],
          )),
        )),
      ),
    ]);
  }
}
