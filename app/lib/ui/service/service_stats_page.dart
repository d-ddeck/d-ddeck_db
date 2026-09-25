import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/service_repository.dart';
import '../common/download.dart';
import 'service_page.dart';
import '../../models/calendar.dart' show parseHexColor;
import '../../models/common.dart';
import '../../models/service.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';

class ServiceStatsTab extends StatefulWidget {
  const ServiceStatsTab({super.key});

  @override
  State<ServiceStatsTab> createState() => _ServiceStatsTabState();
}

class _ServiceStatsTabState extends State<ServiceStatsTab> {
  final _viewKey = GlobalKey<AsyncViewState<_StatsData>>();

  CodeItem? _category;
  String? _brandId;
  StatAxis _axis = StatAxis.category;
  String _interval = 'month';

  Map<String, dynamic> get _filters => {
    if (_category != null) 'category_id': _category!.id,
    if (_brandId != null) 'brand_id': _brandId,
  };

  List<(String, String, String)> get _tables => [
    ('연도별 발생 빈도', 'year', 'category'),
    ('연도별 브랜드별', 'brand', 'year'),
    ('연도별 매장별', 'store', 'year'),
    ('브랜드별 세부 구분별', 'brand', _category == null ? 'category' : 'symptom'),
    ('매장별 세부 구분별', 'store', _category == null ? 'category' : 'symptom'),
    if (_category == null ||
        const ['ROBOT_ARM', 'CONTROL_BOX', 'E_GRIPPER'].contains(_category!.code) ||
        const ['로봇팔', '제어박스', '전동 그리퍼'].contains(_category!.name)) ...[
      ('제조사별 연도별', 'maker', 'year'),
      if (_category != null) ('제조사별 세부 구분별', 'maker', 'symptom'),
    ],
  ];

  void _refresh() => _viewKey.currentState?.reload();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ServiceRepository>();

    return PageBody(child: AsyncView<_StatsData>(
      key: _viewKey,
      load: () async {
        try {
          final filters = _filters;
          final tables = _tables;
          final admin = context.read<AdminRepository>();
          final results = await Future.wait<dynamic>([
            repo.summary(filters: filters),
            repo.grouped(_axis, filters: filters),
            repo.trend(interval: _interval, filters: filters),
            admin.codeGroup('SERVICE_CATEGORY'),
            admin.codeGroup('STORE_BRAND'),
            Future.wait([for (final t in tables) repo.crosstab(t.$2, t.$3, filters: filters)]),
            if (_category == null) repo.storeYears(),
          ]);
          return _StatsData(
            summary: results[0] as ServiceSummary,
            grouped: results[1] as ServiceGrouped,
            trend: results[2] as ServiceTrend,
            categories: (results[3] as CodeGroup).selectable,
            brands: (results[4] as CodeGroup).selectable,
            tables: tables,
            crosses: results[5] as List<Crosstab>,
            stores: results.length > 6 ? results[6] as StoreYears : null,
          );
        } on ApiException catch (e) {
          if (context.mounted) AppSnack.show(context, e.message, error: true);
          rethrow;
        }
      },
      builder: (context, data, reload) {
        final wide = AppTheme.isWide(context);
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            FilterBar(
              appliedFilters: [if (_brandId != null) data.brands.where((b) => b.id == _brandId).firstOrNull?.name ?? '브랜드',
                if (_category != null) _category!.name],
              onReset: () { setState(() { _brandId = null; _category = null; }); _refresh(); },
              children: [SizedBox(width: wide ? 280 : double.infinity, child: DropdownButtonFormField<String>(
              key: ValueKey(_brandId), initialValue: _brandId ?? '', isExpanded: true,
              decoration: const InputDecoration(labelText: '브랜드 · 전 기간'),
              items: [const DropdownMenuItem(value: '', child: Text('전체 브랜드')),
                for (final b in data.brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
              onChanged: (v) { setState(() => _brandId = v == '' ? null : v); _refresh(); },
            ))],
            ),
            const FormGap(),
            DefaultTabController(
              length: data.categories.length + 1,
              initialIndex: _category == null ? 0 : data.categories.indexWhere((c) => c.id == _category!.id) + 1,
              child: TabBar(isScrollable: true, tabAlignment: TabAlignment.start,
                tabs: [const Tab(text: '메인(전체)'), for (final c in data.categories) Tab(text: c.name)],
                onTap: (i) { setState(() => _category = i == 0 ? null : data.categories[i - 1]); _refresh(); },
              ),
            ),
            const SizedBox(height: 12),

            const SizedBox(height: 14),
            for (var i = 0; i < data.crosses.length; i++) ...[
              _crossTable(data.tables[i].$1, data.crosses[i], frequency: i == 0),
              if (i == 2) _storeBars(data.crosses[i]),
              const SizedBox(height: 14),
            ],
            const Text('기존 집계 · 전 기간', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: wide ? 4 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              mainAxisExtent: 160 * MediaQuery.textScalerOf(context).scale(14) / 14,
              children: [
                StatTile(
                  label: '총 접수',
                  value: '${data.summary.total}건',
                  hint: '완료 ${data.summary.completedCount} / '
                      '진행 ${data.summary.openCount}',
                  icon: Icons.assignment_outlined,
                ),
                StatTile(
                  label: '완료율',
                  value: Fmt.percent(data.summary.completionRate, digits: 1),
                  hint: '취소 ${data.summary.canceledCount}건',
                  color: const Color(0xFF10B981),
                  icon: Icons.check_circle_outline,
                ),
                StatTile(
                  label: '평균 처리시간',
                  value: Fmt.duration(data.summary.avgResolutionMinutes),
                  hint: '지연 ${data.summary.overdueCount}건',
                  color: const Color(0xFF3B82F6),
                  icon: Icons.timer_outlined,
                ),
                StatTile(
                  label: '총 비용',
                  value: Fmt.money(data.summary.totalCost),
                  hint: data.summary.avgSatisfaction == null
                      ? null
                      : '만족도 ${data.summary.avgSatisfaction!.toStringAsFixed(2)}',
                  color: const Color(0xFF8B5CF6),
                  icon: Icons.payments_outlined,
                ),
              ],
            ),
            const SizedBox(height: 18),

            _ChartCard(
              title: '분류별 집계',
              trailing: DropdownButton<StatAxis>(
                value: _axis,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final a in StatAxis.values)
                    DropdownMenuItem(
                      value: a,
                      child: Text(a == StatAxis.symptom ? '세부분류' : a.label, style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _axis = v ?? _axis;
                  _refresh();
                }),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_axis.isMultiValue) ...[
                    Text(
                      '원인 ${data.grouped.totalCauses ?? '-'}개 / '
                      '대응 ${data.grouped.total}건',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '한 대응에 여러 원인이 포함될 수 있으며, 차트와 비율은 전체 원인 수 기준입니다.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (data.grouped.buckets.isEmpty)
                    const _NoData()
                  else ...[
                    SizedBox(
                      height: 180,
                      child: _PieChart(buckets: data.grouped.buckets),
                    ),
                    const SizedBox(height: 12),
                    for (final b in data.grouped.buckets)
                      _BucketRow(bucket: b, isMultiValue: _axis.isMultiValue),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            _ChartCard(
              title: '접수 / 완료 추이',
              trailing: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'day', label: Text('일')),
                  ButtonSegment(value: 'week', label: Text('주')),
                  ButtonSegment(value: 'month', label: Text('월')),
                ],
                selected: {_interval},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                onSelectionChanged: (s) => setState(() {
                  _interval = s.first;
                  _refresh();
                }),
              ),
              child: data.trend.points.isEmpty
                  ? const _NoData()
                  : SizedBox(
                      height: 220,
                      child: _TrendChart(points: data.trend.points),
                    ),
            ),
            const SizedBox(height: 14),

            _ChartCard(
              title: '상태별 분포',
              child: data.summary.byStatus.isEmpty
                  ? const _NoData()
                  : Column(
                      children: [
                        for (final b in data.summary.byStatus)
                          _BucketRow(bucket: b),
                      ],
                    ),
            ),
            const SizedBox(height: 14),

            _ChartCard(
              title: '우선순위별 분포',
              child: data.summary.byPriority.isEmpty
                  ? const _NoData()
                  : Column(
                      children: [
                        for (final b in data.summary.byPriority)
                          _BucketRow(bucket: b),
                      ],
                    ),
            ),
            if (data.stores != null) ..._storeTables(data.stores!),
            const SizedBox(height: 24),
          ],
        );
      },
    ));
  }
  void _drill(Map<String, dynamic> axes) {
    // '-' is a display bucket, not a UUID accepted by the list API.
    if (axes.values.contains('-')) {
      AppSnack.show(context, '미분류·미상 항목의 목록 필터는 서버에서 지원하지 않습니다.');
      return;
    }
    final filters = {..._filters, ...axes};
    Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('통계 조건의 접수 목록')),
      body: ServiceListTab(initialFilters: filters),
    )));
  }

  String _filterKey(String axis) => axis == 'year' ? 'year' : '${axis}_id';

  Widget _number(int value, Map<String, dynamic> filters, {String? label}) => InkWell(
    onTap: () => _drill(filters),
    child: Container(
      constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: value >= 5 ? const Color(0xFFFFE0B2)
          : value >= 2 ? const Color(0xFFFFF59D)
          : value >= 1 ? const Color(0xFFFFFDE7) : null,
      child: Text(label ?? '$value', style: const TextStyle(color: Colors.black87)),
    ),
  );

  Widget _crossTable(String title, Crosstab data, {bool frequency = false}) {
    final rows = [...data.rows];
    if (data.rowsAxis == 'store') rows.sort((a, b) => b.total.compareTo(a.total));
    return _ChartCard(
      title: title,
      trailing: TextButton(onPressed: () => runGuarded(context, () async {
        final bytes = await context.read<ServiceRepository>().crosstabXlsx(
          data.rowsAxis, data.colsAxis, filters: _filters);
        await saveAndOpenDownload(bytes, '${title}_${DateTime.now().millisecondsSinceEpoch}.xlsx');
      }), child: const Text('엑셀')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('원인 수 기준 · 대응 건수는 괄호', style: TextStyle(fontSize: 12)),
        ResponsiveTable.fromDataRows(
          columns: [
            DataColumn(label: Text(frequency ? '연도' : switch (data.rowsAxis) {
              'brand' => '브랜드', 'store' => '매장', 'maker' => '제조사', _ => data.rowsAxis,
            })),
            if (!frequency) for (final c in data.cols) DataColumn(label: Text(c.label), numeric: true),
            const DataColumn(label: Text('원인 수'), numeric: true),
            const DataColumn(label: Text('대응 건수'), numeric: true),
            const DataColumn(label: Text('비율%'), numeric: true),
          ],
          rows: [
            for (final r in rows) DataRow(cells: [
              DataCell(Text(r.label)),
              if (!frequency) for (final c in data.cols) DataCell(_number(r.cells[c.key] ?? 0,
                {_filterKey(data.rowsAxis): r.key, _filterKey(data.colsAxis): c.key})),
              DataCell(_number(r.total, {_filterKey(data.rowsAxis): r.key})),
              DataCell(_number(r.ticketCount, {_filterKey(data.rowsAxis): r.key}, label: '(${Fmt.number(r.ticketCount)})')),
              DataCell(InkWell(onTap: () => _drill({_filterKey(data.rowsAxis): r.key}),
                child: Text(Fmt.percent(r.ratio, digits: 1)))),
            ]),
            DataRow(cells: [
              const DataCell(Text('합계')),
              if (!frequency) for (final c in data.cols) DataCell(_number(data.colTotals[c.key] ?? 0,
                {_filterKey(data.colsAxis): c.key})),
              DataCell(_number(data.totalCauses, {})),
              DataCell(_number(data.totalTickets, {}, label: '(${Fmt.number(data.totalTickets)})')),
              DataCell(Text(data.totalCauses == 0 ? '0%' : '100%')),
            ]),
          ],
        ),
      ]),
    );
  }

  Widget _storeBars(Crosstab data) {
    final rows = [...data.rows]..sort((a, b) => b.total.compareTo(a.total));
    final max = rows.isEmpty || rows.first.total == 0 ? 1 : rows.first.total;
    return _ChartCard(title: '매장별 원인 수 · 상위 15', child: Column(children: [
      for (final r in rows.take(15)) InkWell(onTap: () => _drill({'store_id': r.key}),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
          Expanded(flex: 3, child: Text(r.label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: LinearProgressIndicator(value: r.total / max, minHeight: 8)),
          const SizedBox(width: 8), Text('${r.total} (${r.ticketCount})'),
        ]))),
      if (rows.isEmpty) const _NoData(),
    ]));
  }

  // store-years has no workbook endpoint. Export the displayed data as an
  // Excel-readable UTF-8 CSV, preserving numeric cells and neutralizing formulas.
  Widget _storeExport(String title, List<List<Object?>> rows) => TextButton(
    child: const Text('엑셀 (CSV)'),
    onPressed: () => runGuarded(context, () async {
      String cell(Object? value) {
        var text = value?.toString() ?? '';
        if (value is String && RegExp(r'^\s*[=+@-]').hasMatch(text)) text = "'$text";
        return '"${text.replaceAll('"', '""')}"';
      }
      final csv = '\uFEFF${rows.map((r) => r.map(cell).join(',')).join('\r\n')}';
      await saveAndOpenDownload(utf8.encode(csv), '${title}_${DateTime.now().millisecondsSinceEpoch}.csv');
    }),
  );

  List<Widget> _storeTables(StoreYears data) => [
    const SizedBox(height: 14),
    Text('운영 매장 · 전체 브랜드 기준 · 총 ${data.totalStores} / 폐점 ${data.closedStores}'),
    const Text('개점일이 없으면 첫 대응·장비 설치일로 추정합니다.', style: TextStyle(fontSize: 12)),
    if (data.unknownOpen.isNotEmpty) Text('개점 연도 미상: ${data.unknownOpen.join(', ')}'),
    _ChartCard(title: '연도별 운영 매장', trailing: _storeExport('연도별 운영 매장', [
      ['연도', '운영', '개점', '폐점', '연말 운영', '대응 매장', '대응 건수', '매장당 건수'],
      for (final r in data.rows) [r.year, r.operating, r.opened, r.closed, r.yearEnd, r.active, r.tickets, r.perStore],
    ]), child: ResponsiveTable.fromDataRows(
        columns: [for (final h in ['연도', '운영', '개점', '폐점', '연말 운영', '대응 매장', '대응 건수', '매장당 건수']) DataColumn(label: Text(h))],
        rows: [for (final r in data.rows) DataRow(cells: [
          DataCell(Text(r.year)),
          for (final v in [r.operating, r.opened, r.closed, r.yearEnd, r.active]) DataCell(Text(Fmt.number(v))),
          DataCell(InkWell(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: Text('${r.year}년 접수 목록')),
            body: ServiceListTab(initialFilters: {'year': r.year}),
          ))), child: Text('(${Fmt.number(r.tickets)})'))),
          DataCell(Text(r.perStore?.toStringAsFixed(1) ?? '-')),
        ])],
      )),
    _ChartCard(title: '브랜드별 운영 매장', trailing: _storeExport('브랜드별 운영 매장', [
      ['브랜드', ...data.years],
      for (final b in data.byBrand) [b.brand, for (final y in data.years) b.counts[y] ?? 0],
    ]), child: ResponsiveTable.fromDataRows(
        columns: [const DataColumn(label: Text('브랜드')), for (final y in data.years) DataColumn(label: Text(y), numeric: true)],
        rows: [for (final b in data.byBrand) DataRow(cells: [
          DataCell(Text(b.brand)), for (final y in data.years) DataCell(Text(Fmt.number(b.counts[y] ?? 0))),
        ])],
      )),
  ];

}

class _StatsData {
  const _StatsData({
    required this.summary,
    required this.grouped,
    required this.trend,
    required this.categories, required this.brands, required this.tables,
    required this.crosses, this.stores,
  });

  final ServiceSummary summary;
  final ServiceGrouped grouped;
  final ServiceTrend trend;
  final List<CodeItem> categories, brands;
  final List<(String, String, String)> tables;
  final List<Crosstab> crosses;
  final StoreYears? stores;
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SectionCard(title: title,
      actions: [if (trailing != null) trailing!], child: child);
  }
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) => EmptyState(message: '아직 등록된 통계 기록이 없습니다');
}

/// Uses each bucket's server-provided colour, falling back to a generated hue
/// only when the code master has none set.
Color _bucketColor(StatBucket bucket, int index, ColorScheme scheme) {
  if (bucket.color != null && bucket.color!.isNotEmpty) {
    return parseHexColor(bucket.color!, scheme.primary);
  }
  return HSLColor.fromAHSL(1, (index * 47) % 360, 0.55, 0.55).toColor();
}

class _PieChart extends StatelessWidget {
  const _PieChart({required this.buckets});
  final List<StatBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PieChart(
      PieChartData(
        sectionsSpace: 2,
        centerSpaceRadius: 42,
        sections: [
          for (var i = 0; i < buckets.length; i++)
            PieChartSectionData(
              value: buckets[i].count.toDouble(),
              color: _bucketColor(buckets[i], i, scheme),
              radius: 44,
              // Slices under 6% have no room for a label.
              title: buckets[i].ratio >= 0.06
                  ? Fmt.percent(buckets[i].ratio, digits: 0)
                  : '',
              titleStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.points});
  final List<TrendPoint> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxY = points
        .map((p) => p.received > p.completed ? p.received : p.completed)
        .fold<int>(1, (a, b) => a > b ? a : b);

    // The server omits empty periods, so labels are spaced by index rather
    // than by date to keep them from overlapping on a long range.
    final labelEvery = (points.length / 6).ceil().clamp(1, 999);

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: (maxY * 1.2).ceilToDouble(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: scheme.outlineVariant, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              getTitlesWidget: (value, meta) {
                if (value != value.roundToDouble()) {
                  return const SizedBox.shrink();
                }
                return Text(
                  value.toInt().toString(),
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= points.length) {
                  return const SizedBox.shrink();
                }
                if (i % labelEvery != 0) return const SizedBox.shrink();
                final label = points[i].period;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    // Trim "2026-" so the labels fit on a phone.
                    label.length > 7 ? label.substring(5) : label,
                    style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) {
              final label = s.barIndex == 0 ? '접수' : '완료';
              return LineTooltipItem(
                '$label ${s.y.toInt()}건',
                const TextStyle(fontSize: 11, color: Colors.white),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          _line(points.map((p) => p.received).toList(), const Color(0xFF3B82F6)),
          _line(points.map((p) => p.completed).toList(), const Color(0xFF10B981)),
        ],
      ),
    );
  }

  LineChartBarData _line(List<int> values, Color color) => LineChartBarData(
        spots: [
          for (var i = 0; i < values.length; i++)
            FlSpot(i.toDouble(), values[i].toDouble()),
        ],
        isCurved: true,
        curveSmoothness: 0.25,
        color: color,
        barWidth: 2.5,
        dotData: FlDotData(show: values.length <= 20),
        belowBarData: BarAreaData(
          show: true,
          color: color.withValues(alpha: 0.10),
        ),
      );
}

class _BucketRow extends StatelessWidget {
  const _BucketRow({required this.bucket, this.isMultiValue = false});
  final StatBucket bucket;
  final bool isMultiValue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _bucketColor(bucket, bucket.label.hashCode.abs(), scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Text(
                  bucket.label,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Expanded(
                flex: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: bucket.ratio.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: color.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (!isMultiValue)
                SizedBox(
                  width: 46,
                  child: Text(
                    '${bucket.count}건',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              SizedBox(
                width: 44,
                child: Text(
                  Fmt.percent(bucket.ratio, digits: 0),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
              SizedBox(
                width: 62,
                child: Text(
                  Fmt.duration(bucket.avgResolutionMinutes),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (isMultiValue) ...[
            const SizedBox(height: 4),
            Text(
              '원인 ${bucket.count}개'
              '${bucket.ticketCount == null ? '' : ' · 대응 ${bucket.ticketCount}건'}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}
