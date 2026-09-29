part of 'service_stats_page.dart';

class _StatsData {
  const _StatsData({
    required this.summary,
    required this.grouped,
    required this.trend,
    required this.categories,
    required this.workTypes,
    required this.brands,
    required this.tables,
    required this.crosses,
    this.stores,
  });

  final ServiceSummary summary;
  final ServiceGrouped grouped;
  final ServiceTrend trend;
  final List<CodeItem> categories, brands, workTypes;
  final List<(String, String, String)> tables;
  final List<Crosstab> crosses;
  final StoreYears? stores;
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: title,
      padding: const EdgeInsets.all(AppSpace.lg),
      actions: [if (trailing != null) trailing!],
      child: child,
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) =>
      EmptyState(message: '아직 등록된 통계 기록이 없습니다');
}

/// Uses each bucket's server-provided colour, falling back to a generated hue
/// only when the code master has none set.
Color _bucketColor(StatBucket bucket, int index, ColorScheme scheme) {
  if (bucket.color != null && bucket.color!.isNotEmpty) {
    return parseHexColor(bucket.color!, scheme.primary);
  }
  return HSLColor.fromAHSL(1, (index * 47) % 360, 0.55, 0.55).toColor();
}

class _PieChart extends StatefulWidget {
  const _PieChart({required this.buckets});
  final List<StatBucket> buckets;
  @override
  State<_PieChart> createState() => _PieChartState();
}

class _PieChartState extends State<_PieChart> {
  int? _touched;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final buckets = widget.buckets;
    final selected = _touched != null && _touched! < buckets.length
        ? buckets[_touched!]
        : null;
    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: 42,
            pieTouchData: PieTouchData(
              touchCallback: (event, response) {
                final index = response?.touchedSection?.touchedSectionIndex;
                final next =
                    event.isInterestedForInteractions &&
                        index != null &&
                        index >= 0
                    ? index
                    : null;
                if (next != _touched) setState(() => _touched = next);
              },
            ),
            sections: [
              for (var i = 0; i < buckets.length; i++)
                PieChartSectionData(
                  value: buckets[i].count.toDouble(),
                  color: _bucketColor(buckets[i], i, scheme),
                  radius: _touched == i ? 50 : 44,
                  title: buckets[i].ratio >= .06
                      ? Fmt.percent(buckets[i].ratio, digits: 0)
                      : '',
                  titleStyle: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color:
                        _bucketColor(buckets[i], i, scheme).computeLuminance() >
                            0.179
                        ? Colors.black
                        : Colors.white,
                  ),
                ),
            ],
          ),
        ),
        if (selected != null)
          IgnorePointer(
            child: SizedBox(
              width: 80,
              child: Text(
                '${selected.label}\n${selected.count}건\n${Fmt.percent(selected.ratio)}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: scheme.onSurface),
              ),
            ),
          ),
      ],
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
              getTitlesWidget: (value, meta) {
                if (value != value.roundToDouble()) {
                  return const SizedBox.shrink();
                }
                return Text(
                  value.toInt().toString(),
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
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
                    style: TextStyle(
                      fontSize: 9,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) {
              final label = s.barIndex == 0 ? '접수' : '종결';
              return LineTooltipItem(
                '$label ${s.y.toInt()}건',
                const TextStyle(fontSize: 11, color: Colors.white),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          _line(
            points.map((p) => p.received).toList(),
            AppColors.info(context),
          ),
          _line(
            points.map((p) => p.completed).toList(),
            AppColors.success(context),
          ),
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
    belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.10)),
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
                  bucket.key == 'COMPLETED' && bucket.label == '완료'
                      ? '종결'
                      : bucket.label,
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
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                width: 62,
                child: Text(
                  Fmt.duration(bucket.avgResolutionMinutes),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (isMultiValue) ...[
            const SizedBox(height: 4),
            Text(
              '원인 ${bucket.count}개'
              '${bucket.ticketCount == null ? '' : ' · 서비스 ${bucket.ticketCount}건'}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}
