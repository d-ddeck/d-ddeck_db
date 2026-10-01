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

part 'service_stats_widgets.dart';

class ServiceStatsTab extends StatefulWidget {
  const ServiceStatsTab({super.key});

  @override
  State<ServiceStatsTab> createState() => _ServiceStatsTabState();
}

class _ServiceStatsTabState extends State<ServiceStatsTab> {
  final _viewKey = GlobalKey<AsyncViewState<_StatsData>>();

  CodeItem? _category;
  String? _workTypeId;
  String? _brandId;
  StatAxis _axis = StatAxis.category;
  String _interval = 'month';
  String _section = '요약';

  Map<String, dynamic> get _filters => {
    if (_workTypeId == '-') 'missing': 'work_type',
    if (_workTypeId != null && _workTypeId != '-') 'work_type_id': _workTypeId,
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
        const [
          'ROBOT_ARM',
          'CONTROL_BOX',
          'E_GRIPPER',
        ].contains(_category!.code) ||
        const ['로봇팔', '제어박스', '전동 그리퍼'].contains(_category!.name)) ...[
      ('제조사별 연도별', 'maker', 'year'),
      if (_category != null) ('제조사별 세부 구분별', 'maker', 'symptom'),
    ],
  ];

  void _refresh() => _viewKey.currentState?.reload();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ServiceRepository>();

    return PageBody(
      child: AsyncView<_StatsData>(
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
              Future.wait([
                for (final t in tables)
                  repo.crosstab(t.$2, t.$3, filters: filters),
              ]),
              admin.codeGroup('SERVICE_WORK_TYPE'),
              if (_category == null && _workTypeId == null) repo.storeYears(),
            ]);
            return _StatsData(
              summary: results[0] as ServiceSummary,
              grouped: results[1] as ServiceGrouped,
              trend: results[2] as ServiceTrend,
              categories: (results[3] as CodeGroup).selectable,
              brands: (results[4] as CodeGroup).selectable,
              tables: tables,
              crosses: results[5] as List<Crosstab>,
              workTypes: (results[6] as CodeGroup).items,
              stores: results.length > 7 ? results[7] as StoreYears : null,
            );
          } on ApiException catch (e) {
            if (context.mounted) AppSnack.show(context, e.message, error: true);
            rethrow;
          }
        },
        builder: (context, data, reload) {
          final wide = AppTheme.isWide(context);
          return Column(
            children: [
              Text(
                '조회 기간: 전 기간 · ${_category?.name ?? '전체 서비스구분'} · ${_brandId == null ? '전체 브랜드' : data.brands.where((b) => b.id == _brandId).firstOrNull?.name ?? '선택 브랜드'}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 12),
                  children: [
                    FilterBar(
                      appliedFilters: [
                        if (_workTypeId != null)
                          _workTypeId == '-'
                              ? '업무 구분 미분류'
                              : data.workTypes
                                        .where((c) => c.id == _workTypeId)
                                        .firstOrNull
                                        ?.name ??
                                    '업무 구분',
                        if (_brandId != null)
                          data.brands
                                  .where((b) => b.id == _brandId)
                                  .firstOrNull
                                  ?.name ??
                              '브랜드',
                        if (_category != null) _category!.name,
                      ],
                      onReset: () {
                        setState(() {
                          _brandId = null;
                          _category = null;
                          _workTypeId = null;
                        });
                        _refresh();
                      },
                      children: [
                        SizedBox(
                          width: wide ? 260 : double.infinity,
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('work-type:$_workTypeId'),
                            initialValue: _workTypeId ?? '',
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '업무 구분',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('전체 업무'),
                              ),
                              const DropdownMenuItem(
                                value: '-',
                                child: Text('미분류'),
                              ),
                              for (final c in data.workTypes)
                                DropdownMenuItem(
                                  value: c.id,
                                  child: Text('${c.code} · ${c.name}'),
                                ),
                            ],
                            onChanged: (v) {
                              setState(() => _workTypeId = v == '' ? null : v);
                              _refresh();
                            },
                          ),
                        ),
                        SizedBox(
                          width: wide ? 280 : double.infinity,
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(_brandId),
                            initialValue: _brandId ?? '',
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '브랜드 · 전 기간',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('전체 브랜드'),
                              ),
                              for (final b in data.brands)
                                DropdownMenuItem(
                                  value: b.id,
                                  child: Text(b.name),
                                ),
                            ],
                            onChanged: (v) {
                              setState(() => _brandId = v == '' ? null : v);
                              _refresh();
                            },
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.download),
                        label: const Text('전체 통계 Excel'),
                        onPressed: () => runGuarded(context, () async {
                          final bytes = await repo.exportAllStats(_filters);
                          await saveAndOpenDownload(bytes, '전체통계.xlsx');
                        }),
                      ),
                    ),
                    const FormGap(),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final section in ['요약', '추이', '분류 분석', '원본 검증'])
                          ChoiceChip(
                            label: Text(section),
                            selected: _section == section,
                            onSelected: (_) =>
                                setState(() => _section = section),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('화면과 전체 통계 Excel은 같은 조건으로 집계합니다.'),
                    const FormGap(),
                    DropdownButtonFormField<String>(
                      initialValue: _category?.id ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '서비스구분'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('전체')),
                        for (final category in data.categories)
                          DropdownMenuItem(
                            value: category.id,
                            child: Text(category.name),
                          ),
                      ],
                      onChanged: (id) {
                        setState(
                          () => _category = data.categories
                              .where((c) => c.id == id)
                              .firstOrNull,
                        );
                        _refresh();
                      },
                    ),
                    const SizedBox(height: 16),
                    if (_section == '원본 검증') ...[
                      for (var i = 0; i < data.crosses.length; i++) ...[
                        _crossTable(
                          data.tables[i].$1,
                          data.crosses[i],
                          frequency: i == 0,
                        ),
                        if (i == 2) ...[
                          const SizedBox(height: AppSpace.lg),
                          _storeBars(data.crosses[i]),
                        ],
                        const SizedBox(height: AppSpace.md),
                      ],
                    ],
                    if (_section == '요약') ...[
                      const Text(
                        '요약 · 전 기간',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: AppSpace.md),
                      GridView.count(
                        crossAxisCount: wide ? 4 : 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        mainAxisExtent:
                            160 *
                            MediaQuery.textScalerOf(context).scale(14) /
                            14,
                        children: [
                          StatTile(
                            label: '총 접수',
                            value: '${data.summary.total}건',
                            hint:
                                '종결 ${data.summary.completedCount} / '
                                '진행 ${data.summary.openCount}',
                            icon: Icons.assignment_outlined,
                          ),
                          StatTile(
                            label: '종결률',
                            value: Fmt.percent(
                              data.summary.completionRate,
                              digits: 1,
                            ),
                            hint: '취소 ${data.summary.canceledCount}건',
                            color: const Color(0xFF10B981),
                            icon: Icons.check_circle_outline,
                          ),
                          StatTile(
                            label: '평균 처리시간',
                            value: Fmt.duration(
                              data.summary.avgResolutionMinutes,
                            ),
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
                      const SizedBox(height: AppSpace.lg),
                    ],
                    if (_section == '분류 분석') ...[
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
                                child: Text(
                                  a == StatAxis.symptom ? '세부분류' : a.label,
                                  style: const TextStyle(fontSize: 13),
                                ),
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
                                '서비스 ${data.grouped.total}건 · 원인 미입력 ${data.grouped.ticketsWithoutCause}건',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '한 서비스에 여러 원인이 포함될 수 있으며, 차트와 비율은 전체 원인 수 기준입니다.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
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
                                _BucketRow(
                                  bucket: b,
                                  isMultiValue: _axis.isMultiValue,
                                ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                    ],
                    if (_section == '추이') ...[
                      _ChartCard(
                        title: '접수 / 종결 추이',
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
                      const SizedBox(height: AppSpace.md),
                    ],
                    if (_section == '요약') ...[
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
                      const SizedBox(height: AppSpace.md),

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
                    ],
                    if (_section == '원본 검증' && data.stores != null)
                      ..._storeTables(data.stores!),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _drill(Map<String, dynamic> axes) {
    final filters = {..._filters, ...axes};
    final missing = <String>[];
    filters.removeWhere((key, value) {
      if (value != '-' && value != 'UNASSIGNED') return false;
      missing.add(key.replaceFirst(RegExp(r'_id$'), ''));
      return true;
    });
    if (missing.isNotEmpty) filters['missing'] = missing.join(',');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('통계 조건의 접수 목록')),
          body: ServiceListTab(initialFilters: filters),
        ),
      ),
    );
  }

  String _filterKey(String axis) => axis == 'year' ? 'year' : '${axis}_id';

  Widget _number(int value, Map<String, dynamic> filters, {String? label}) =>
      InkWell(
        onTap: () => _drill(filters),
        child: Container(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: value >= 5
              ? Theme.of(context).colorScheme.tertiaryContainer
              : value >= 2
              ? Theme.of(context).colorScheme.secondaryContainer
              : value >= 1
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : null,
          child: Text(
            label ?? '$value',
            style: TextStyle(
              color: value == 0
                  ? Theme.of(context).colorScheme.onSurface
                  : value >= 5
                  ? Theme.of(context).colorScheme.onTertiaryContainer
                  : value >= 2
                  ? Theme.of(context).colorScheme.onSecondaryContainer
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      );

  Widget _crossTable(String title, Crosstab data, {bool frequency = false}) {
    final rows = [...data.rows];
    if (data.rowsAxis == 'store') {
      rows.sort((a, b) => b.total.compareTo(a.total));
    }
    return _ChartCard(
      title: title,
      trailing: TextButton(
        onPressed: () => runGuarded(context, () async {
          final bytes = await context.read<ServiceRepository>().crosstabXlsx(
            data.rowsAxis,
            data.colsAxis,
            filters: _filters,
          );
          await saveAndOpenDownload(
            bytes,
            '${title}_${DateTime.now().millisecondsSinceEpoch}.xlsx',
          );
        }),
        child: const Text('엑셀'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '원인 수 기준 · 서비스 건수는 괄호 · 원인 미입력 ${data.ticketsWithoutCause}건',
            style: const TextStyle(fontSize: 12),
          ),
          const FormGap(),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(
                  label: Text(
                    frequency
                        ? '연도'
                        : switch (data.rowsAxis) {
                            'brand' => '브랜드',
                            'store' => '매장',
                            'maker' => '제조사',
                            _ => data.rowsAxis,
                          },
                  ),
                ),
                if (!frequency)
                  for (final c in data.cols)
                    DataColumn(label: Text(c.label), numeric: true),
                const DataColumn(label: Text('원인 수'), numeric: true),
                const DataColumn(label: Text('서비스 건수'), numeric: true),
                const DataColumn(label: Text('비율%'), numeric: true),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(r.label)),
                      if (!frequency)
                        for (final c in data.cols)
                          DataCell(
                            _number(r.cells[c.key] ?? 0, {
                              _filterKey(data.rowsAxis): r.key,
                              _filterKey(data.colsAxis): c.key,
                            }),
                          ),
                      DataCell(
                        _number(r.total, {_filterKey(data.rowsAxis): r.key}),
                      ),
                      DataCell(
                        _number(r.ticketCount, {
                          _filterKey(data.rowsAxis): r.key,
                        }, label: '(${Fmt.number(r.ticketCount)})'),
                      ),
                      DataCell(
                        InkWell(
                          onTap: () =>
                              _drill({_filterKey(data.rowsAxis): r.key}),
                          child: Text(Fmt.percent(r.ratio, digits: 1)),
                        ),
                      ),
                    ],
                  ),
                DataRow(
                  cells: [
                    const DataCell(Text('합계')),
                    if (!frequency)
                      for (final c in data.cols)
                        DataCell(
                          _number(data.colTotals[c.key] ?? 0, {
                            _filterKey(data.colsAxis): c.key,
                          }),
                        ),
                    DataCell(_number(data.totalCauses, {})),
                    DataCell(
                      _number(
                        data.totalTickets,
                        {},
                        label: '(${Fmt.number(data.totalTickets)})',
                      ),
                    ),
                    DataCell(Text(data.totalCauses == 0 ? '0%' : '100%')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _storeBars(Crosstab data) {
    final rows = [...data.rows]..sort((a, b) => b.total.compareTo(a.total));
    final max = rows.isEmpty || rows.first.total == 0 ? 1 : rows.first.total;
    return _ChartCard(
      title: '매장별 원인 수 · 상위 15',
      child: Column(
        children: [
          for (final r in rows.take(15))
            InkWell(
              onTap: () => _drill({'store_id': r.key}),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(r.label, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: LinearProgressIndicator(
                        value: r.total / max,
                        minHeight: 8,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${r.total} (${r.ticketCount})'),
                  ],
                ),
              ),
            ),
          if (rows.isEmpty) const _NoData(),
        ],
      ),
    );
  }

  // store-years has no workbook endpoint. Export the displayed data as an
  // Excel-readable UTF-8 CSV, preserving numeric cells and neutralizing formulas.
  Widget _storeExport(String title, List<List<Object?>> rows) => TextButton(
    child: const Text('엑셀 (CSV)'),
    onPressed: () => runGuarded(context, () async {
      String cell(Object? value) {
        var text = value?.toString() ?? '';
        if (value is String && RegExp(r'^\s*[=+@-]').hasMatch(text)) {
          text = "'$text";
        }
        return '"${text.replaceAll('"', '""')}"';
      }

      final csv =
          '\uFEFF${rows.map((r) => r.map(cell).join(',')).join('\r\n')}';
      await saveAndOpenDownload(
        utf8.encode(csv),
        '${title}_${DateTime.now().millisecondsSinceEpoch}.csv',
      );
    }),
  );

  List<Widget> _storeTables(StoreYears data) => [
    const SizedBox(height: AppSpace.md),
    Text('운영 매장 · 전체 브랜드 기준 · 총 ${data.totalStores} / 미운영 ${data.closedStores}'),
    const Text('개점일이 없으면 첫 서비스·장비 설치일로 추정합니다.', style: TextStyle(fontSize: 12)),
    if (data.unknownOpen.isNotEmpty)
      Text('개점 연도 미상: ${data.unknownOpen.join(', ')}'),
    const SizedBox(height: AppSpace.md),
    _ChartCard(
      title: '연도별 운영 매장',
      trailing: _storeExport('연도별 운영 매장', [
        ['연도', '운영', '개점', '미운영', '연말 운영', '서비스 매장', '서비스 건수', '매장당 건수'],
        for (final r in data.rows)
          [
            r.year,
            r.operating,
            r.opened,
            r.closed,
            r.yearEnd,
            r.active,
            r.tickets,
            r.perStore,
          ],
      ]),
      child: ResponsiveTable.fromDataRows(
        columns: [
          for (final h in [
            '연도',
            '운영',
            '개점',
            '미운영',
            '연말 운영',
            '서비스 매장',
            '서비스 건수',
            '매장당 건수',
          ])
            DataColumn(label: Text(h)),
        ],
        rows: [
          for (final r in data.rows)
            DataRow(
              cells: [
                DataCell(Text(r.year)),
                for (final v in [
                  r.operating,
                  r.opened,
                  r.closed,
                  r.yearEnd,
                  r.active,
                ])
                  DataCell(Text(Fmt.number(v))),
                DataCell(
                  InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: Text('${r.year}년 접수 목록')),
                          body: ServiceListTab(
                            initialFilters: {'year': r.year},
                          ),
                        ),
                      ),
                    ),
                    child: Text('(${Fmt.number(r.tickets)})'),
                  ),
                ),
                DataCell(Text(r.perStore?.toStringAsFixed(1) ?? '-')),
              ],
            ),
        ],
      ),
    ),
    const SizedBox(height: AppSpace.md),
    _ChartCard(
      title: '브랜드별 운영 매장',
      trailing: _storeExport('브랜드별 운영 매장', [
        ['브랜드', ...data.years],
        for (final b in data.byBrand)
          [b.brand, for (final y in data.years) b.counts[y] ?? 0],
      ]),
      child: ResponsiveTable.fromDataRows(
        columns: [
          const DataColumn(label: Text('브랜드')),
          for (final y in data.years) DataColumn(label: Text(y), numeric: true),
        ],
        rows: [
          for (final b in data.byBrand)
            DataRow(
              cells: [
                DataCell(Text(b.brand)),
                for (final y in data.years)
                  DataCell(Text(Fmt.number(b.counts[y] ?? 0))),
              ],
            ),
        ],
      ),
    ),
  ];
}
