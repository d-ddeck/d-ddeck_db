import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/service_repository.dart';
import '../../models/calendar.dart' show parseHexColor;
import '../../models/common.dart';
import '../../models/service.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';

/// Automatic AS statistics.
///
/// The three server endpoints (summary / grouped / trend) take the same filter
/// parameters, so the one filter row at the top is applied to all of them and
/// the numbers on the screen always describe the same set of tickets.
class ServiceStatsTab extends StatefulWidget {
  const ServiceStatsTab({super.key});

  @override
  State<ServiceStatsTab> createState() => _ServiceStatsTabState();
}

class _ServiceStatsTabState extends State<ServiceStatsTab> {
  final _viewKey = GlobalKey<AsyncViewState<_StatsData>>();

  _Period _period = _Period.month3;
  StatAxis _axis = StatAxis.category;
  String _interval = 'day';

  DateTime get _from => _period.from();

  void _refresh() => _viewKey.currentState?.reload();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ServiceRepository>();

    return AsyncView<_StatsData>(
      key: _viewKey,
      load: () async {
        final from = _from;
        final results = await Future.wait([
          repo.summary(dateFrom: from),
          repo.grouped(_axis, dateFrom: from),
          repo.trend(interval: _interval, dateFrom: from),
        ]);
        return _StatsData(
          summary: results[0] as ServiceSummary,
          grouped: results[1] as ServiceGrouped,
          trend: results[2] as ServiceTrend,
        );
      },
      builder: (context, data, reload) {
        final wide = AppTheme.isWide(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _PeriodSelector(
              period: _period,
              onChanged: (p) => setState(() {
                _period = p;
                // A long window with daily buckets produces an unreadable
                // chart, so widen the bucket along with the range.
                _interval = switch (p) {
                  _Period.week => 'day',
                  _Period.month => 'day',
                  _Period.month3 => 'week',
                  _Period.year => 'month',
                };
                _refresh();
              }),
            ),
            const SizedBox(height: 14),

            GridView.count(
              crossAxisCount: wide ? 4 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: wide ? 1.9 : 1.5,
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
                      child: Text(a.label, style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _axis = v ?? _axis;
                  _refresh();
                }),
              ),
              child: data.grouped.buckets.isEmpty
                  ? const _NoData()
                  : Column(
                      children: [
                        SizedBox(
                          height: 180,
                          child: _PieChart(buckets: data.grouped.buckets),
                        ),
                        const SizedBox(height: 12),
                        for (final b in data.grouped.buckets)
                          _BucketRow(bucket: b),
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
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

class _StatsData {
  const _StatsData({
    required this.summary,
    required this.grouped,
    required this.trend,
  });

  final ServiceSummary summary;
  final ServiceGrouped grouped;
  final ServiceTrend trend;
}

enum _Period {
  week('최근 7일'),
  month('최근 30일'),
  month3('최근 90일'),
  year('최근 1년');

  const _Period(this.label);
  final String label;

  DateTime from() {
    final now = DateTime.now();
    return switch (this) {
      _Period.week => now.subtract(const Duration(days: 7)),
      _Period.month => now.subtract(const Duration(days: 30)),
      _Period.month3 => now.subtract(const Duration(days: 90)),
      _Period.year => DateTime(now.year - 1, now.month, now.day),
    };
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.period, required this.onChanged});

  final _Period period;
  final ValueChanged<_Period> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final p in _Period.values) ...[
            ChoiceChip(
              label: Text(p.label),
              selected: period == p,
              onSelected: (_) => onChanged(p),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            '해당 기간에 데이터가 없습니다.',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      );
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
                  style: TextStyle(fontSize: 10, color: scheme.outline),
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
                    style: TextStyle(fontSize: 9, color: scheme.outline),
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
  const _BucketRow({required this.bucket});
  final StatBucket bucket;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _bucketColor(bucket, bucket.label.hashCode.abs(), scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
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
          SizedBox(
            width: 46,
            child: Text(
              '${bucket.count}건',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              Fmt.percent(bucket.ratio, digits: 0),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ),
          SizedBox(
            width: 62,
            child: Text(
              Fmt.duration(bucket.avgResolutionMinutes),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}
