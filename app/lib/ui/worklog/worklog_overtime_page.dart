import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../data/worklog_repository.dart';
import '../../models/worklog.dart';
import '../common/common.dart';
import '../common/download.dart';
import '../theme.dart';
import 'worklog_detail_page.dart';

/// 내 일지의 한 달 연장 근무: 날짜별 연장 시간 차트, 사유 표, 총 연장 시간.
class WorkLogOvertimePage extends StatefulWidget {
  const WorkLogOvertimePage({super.key});

  @override
  State<WorkLogOvertimePage> createState() => _WorkLogOvertimePageState();
}

class _WorkLogOvertimePageState extends State<WorkLogOvertimePage> {
  late DateTime _month;
  OvertimeSummary? _data;
  String? _error;
  bool _loading = true, _busy = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<WorkLogRepository>().overtimeSummary(
        _month.year,
        _month.month,
      );
      if (mounted) setState(() => _data = data);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '오류가 발생했습니다: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _shift(int months) {
    setState(() => _month = DateTime(_month.year, _month.month + months));
    _load();
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _month,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12),
      initialDatePickerMode: DatePickerMode.year,
      helpText: '조회할 달 선택',
    );
    if (picked == null || !mounted) return;
    setState(() => _month = DateTime(picked.year, picked.month));
    _load();
  }

  Future<void> _pdf(bool save) async {
    final year = _month.year, month = _month.month;
    setState(() => _busy = true);
    await runGuarded(context, () async {
      final bytes = await context.read<ApiClient>().getBytes(
        '/worklogs/overtime-summary.pdf?year=$year&month=$month',
      );
      final name = '연장근무_$year-${month.toString().padLeft(2, '0')}.pdf';
      if (!save) {
        await saveAndOpenDownload(bytes, name);
      } else if (await savePdfAs(bytes, name, dialogTitle: '연장근무 종합 PDF 저장') &&
          mounted) {
        AppSnack.show(context, 'PDF를 저장했습니다.');
      }
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('연장근무 종합'),
        actions: [
          PopupMenuButton<bool>(
            tooltip: 'PDF',
            enabled: !_busy && !_loading && _error == null,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onSelected: _pdf,
            itemBuilder: (_) => const [
              PopupMenuItem(value: false, child: Text('PDF 열기')),
              PopupMenuItem(value: true, child: Text('PDF 저장')),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '이전 달',
                    onPressed: _loading ? null : () => _shift(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: _loading ? null : _pickMonth,
                    child: Text(
                      '${_month.year}년 ${_month.month}월',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '다음 달',
                    onPressed: _loading ? null : () => _shift(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const Spacer(),
                  Text(
                    '정규 09:00~18:00 · 18:00 이후 근무',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) ErrorState(message: _error!, onRetry: _load),
              if (data != null && _error == null) ...[
                SectionCard(
                  title: '총 연장근무 시간',
                  child: Text(
                    data.totalMinutes == 0
                        ? '없음'
                        : overtimeLabel(data.totalMinutes),
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                if (data.items.isEmpty)
                  const EmptyState(message: '이 달에는 연장 근무가 없습니다')
                else ...[
                  SectionCard(
                    title: '날짜별 연장근무 시간 (시간)',
                    child: SizedBox(
                      height: 240,
                      child: _OvertimeChart(items: data.items),
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  ResponsiveTable<OvertimeDay>(
                    rows: data.items,
                    onTap: (row) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => WorkLogDetailPage(id: row.id),
                      ),
                    ),
                    columns: [
                      TableColumn(label: '날짜', cell: (d) => Text(d.workDate)),
                      TableColumn(
                        label: '근무시간',
                        cell: (d) => Text('${d.workStart}~${d.workEnd}'),
                      ),
                      TableColumn(
                        label: '연장 시간',
                        numeric: true,
                        cell: (d) => Text(overtimeLabel(d.minutes)),
                      ),
                      TableColumn(
                        label: '사유',
                        flex: 3,
                        cell: (d) => Text(d.reason.isEmpty ? '-' : d.reason),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OvertimeChart extends StatelessWidget {
  const _OvertimeChart({required this.items});
  final List<OvertimeDay> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxHours = items
        .map((d) => d.minutes / 60)
        .fold<double>(1, (a, b) => a > b ? a : b);
    // Keep day labels from overlapping when most days of the month have overtime.
    final labelEvery = (items.length / 10).ceil().clamp(1, 999);
    final barWidth = (240 / items.length).clamp(6.0, 22.0);
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: (maxHours * 1.2).ceilToDouble(),
        alignment: BarChartAlignment.spaceAround,
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: scheme.outlineVariant, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              getTitlesWidget: (value, meta) => value != value.roundToDouble()
                  ? const SizedBox.shrink()
                  : Text(
                      '${value.toInt()}',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= items.length || i % labelEvery != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    // "2026-10-07" -> "10/07"
                    items[i].workDate.substring(5).replaceFirst('-', '/'),
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final d = items[group.x];
              return BarTooltipItem(
                '${d.workDate}\n${overtimeLabel(d.minutes)}'
                '${d.reason.isEmpty ? '' : '\n${d.reason}'}',
                const TextStyle(fontSize: 11, color: Colors.white),
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < items.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: items[i].minutes / 60,
                  width: barWidth,
                  color: scheme.primary,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
