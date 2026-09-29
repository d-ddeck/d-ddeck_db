part of 'service.dart';

class ServiceSummary {
  const ServiceSummary({
    required this.total,
    required this.openCount,
    required this.completedCount,
    required this.canceledCount,
    required this.overdueCount,
    required this.completionRate,
    required this.byStatus,
    required this.byPriority,
    this.avgResolutionMinutes,
    this.avgSatisfaction,
    this.totalCost,
  });

  final int total;
  final int openCount;
  final int completedCount;
  final int canceledCount;
  final int overdueCount;
  final double completionRate;
  final List<StatBucket> byStatus;
  final List<StatBucket> byPriority;
  final double? avgResolutionMinutes;
  final double? avgSatisfaction;
  final double? totalCost;

  factory ServiceSummary.fromJson(Map<String, dynamic> j) => ServiceSummary(
    total: asInt(j['total']),
    openCount: asInt(j['open_count']),
    completedCount: asInt(j['completed_count']),
    canceledCount: asInt(j['canceled_count']),
    overdueCount: asInt(j['overdue_count']),
    completionRate: asDouble(j['completion_rate']) ?? 0,
    avgResolutionMinutes: asDouble(j['avg_resolution_minutes']),
    avgSatisfaction: asDouble(j['avg_satisfaction']),
    totalCost: asDouble(j['total_cost']),
    byStatus: asList(j['by_status'], StatBucket.fromJson),
    byPriority: asList(j['by_priority'], StatBucket.fromJson),
  );

  static ServiceSummary empty() => const ServiceSummary(
    total: 0,
    openCount: 0,
    completedCount: 0,
    canceledCount: 0,
    overdueCount: 0,
    completionRate: 0,
    byStatus: [],
    byPriority: [],
  );
}

class ServiceGrouped {
  const ServiceGrouped({
    required this.groupBy,
    required this.total,
    required this.buckets,
    this.totalCauses,
    this.ticketsWithoutCause = 0,
  });

  final String groupBy;
  final int total;
  final int? totalCauses;
  final int ticketsWithoutCause;
  final List<StatBucket> buckets;

  factory ServiceGrouped.fromJson(Map<String, dynamic> j) => ServiceGrouped(
    groupBy: asString(j['group_by']),
    total: asInt(j['total']),
    ticketsWithoutCause: asInt(j['tickets_without_cause']),
    totalCauses: j['total_causes'] == null ? null : asInt(j['total_causes']),
    buckets: asList(j['buckets'], StatBucket.fromJson),
  );
}

class TrendPoint {
  const TrendPoint({
    required this.period,
    required this.received,
    required this.completed,
  });

  final String period;
  final int received;
  final int completed;

  factory TrendPoint.fromJson(Map<String, dynamic> j) => TrendPoint(
    period: asString(j['period']),
    received: asInt(j['received']),
    completed: asInt(j['completed']),
  );
}

class ServiceTrend {
  const ServiceTrend({required this.interval, required this.points});

  final String interval;
  final List<TrendPoint> points;

  factory ServiceTrend.fromJson(Map<String, dynamic> j) => ServiceTrend(
    interval: asString(j['interval']),
    points: asList(j['points'], TrendPoint.fromJson),
  );
}

/// The statistics axes the server supports, with their Korean labels.
enum StatAxis {
  workType('work_type', '업무 구분'),
  category('category', '서비스 분류'),
  symptom('symptom', '증상'),
  cause('cause', '원인'),
  action('action', '조치'),
  maker('maker', '제조사'),
  fault('fault', '과실'),
  store('store', '매장'),
  brand('brand', '브랜드'),
  responder('responder', '서비스인원'),
  assignee('assignee', '담당자'),
  status('status', '상태'),
  priority('priority', '우선순위'),
  channel('channel', '접수 경로');

  bool get isMultiValue =>
      this == category || this == symptom || this == maker || this == responder;

  const StatAxis(this.value, this.label);
  final String value;
  final String label;
}

class AxisKey {
  const AxisKey({required this.key, required this.label, this.color});

  final String key;
  final String label;
  final String? color;

  factory AxisKey.fromJson(Map<String, dynamic> j) => AxisKey(
    key: asString(j['key']),
    label: asString(j['label']),
    color: j['color'] as String?,
  );
}

class CrosstabRow {
  const CrosstabRow({
    required this.key,
    required this.label,
    this.color,
    required this.cells,
    required this.total,
    required this.ticketCount,
    required this.ratio,
  });

  final String key;
  final String label;
  final String? color;
  final Map<String, int> cells;
  final int total;
  final int ticketCount;
  final double ratio;

  factory CrosstabRow.fromJson(Map<String, dynamic> j) => CrosstabRow(
    key: asString(j['key']),
    label: asString(j['label']),
    color: j['color'] as String?,
    cells: asMap(j['cells']).map((key, value) => MapEntry(key, asInt(value))),
    total: asInt(j['total']),
    ticketCount: asInt(j['ticket_count']),
    ratio: asDouble(j['ratio']) ?? 0,
  );
}

class Crosstab {
  const Crosstab({
    required this.rowsAxis,
    required this.colsAxis,
    required this.cols,
    required this.rows,
    required this.colTotals,
    required this.totalCauses,
    required this.totalTickets,
    this.ticketsWithoutCause = 0,
  });

  final String rowsAxis;
  final String colsAxis;
  final List<AxisKey> cols;
  final List<CrosstabRow> rows;
  final Map<String, int> colTotals;
  final int totalCauses;
  final int totalTickets;
  final int ticketsWithoutCause;

  factory Crosstab.fromJson(Map<String, dynamic> j) => Crosstab(
    rowsAxis: asString(j['rows_axis']),
    colsAxis: asString(j['cols_axis']),
    cols: asList(j['cols'], AxisKey.fromJson),
    rows: asList(j['rows'], CrosstabRow.fromJson),
    colTotals: asMap(j['col_totals'])
        .map((key, value) => MapEntry(key, asInt(value))),
    totalCauses: asInt(j['total_causes']),
    totalTickets: asInt(j['total_tickets']),
    ticketsWithoutCause: asInt(j['tickets_without_cause']),
  );
}

class StoreYearRow {
  const StoreYearRow({
    required this.year,
    required this.operating,
    required this.opened,
    required this.closed,
    required this.yearEnd,
    required this.active,
    required this.tickets,
    this.perStore,
  });

  final String year;
  final int operating;
  final int opened;
  final int closed;
  final int yearEnd;
  final int active;
  final int tickets;
  final double? perStore;

  factory StoreYearRow.fromJson(Map<String, dynamic> j) => StoreYearRow(
    year: asString(j['year']),
    operating: asInt(j['operating']),
    opened: asInt(j['opened']),
    closed: asInt(j['closed']),
    yearEnd: asInt(j['year_end']),
    active: asInt(j['active']),
    tickets: asInt(j['tickets']),
    perStore: asDouble(j['per_store']),
  );
}

class BrandYearRow {
  const BrandYearRow({required this.brand, required this.counts});

  final String brand;
  final Map<String, int> counts;

  factory BrandYearRow.fromJson(Map<String, dynamic> j) => BrandYearRow(
    brand: asString(j['brand']),
    counts: asMap(j['counts']).map((key, value) => MapEntry(key, asInt(value))),
  );
}

class StoreYears {
  const StoreYears({
    required this.years,
    required this.rows,
    required this.byBrand,
    required this.totalStores,
    required this.closedStores,
    required this.unknownOpen,
  });

  final List<String> years;
  final List<StoreYearRow> rows;
  final List<BrandYearRow> byBrand;
  final int totalStores;
  final int closedStores;
  final List<String> unknownOpen;

  factory StoreYears.fromJson(Map<String, dynamic> j) => StoreYears(
    years: (j['years'] as List? ?? []).map((v) => asString(v)).toList(),
    rows: asList(j['rows'], StoreYearRow.fromJson),
    byBrand: asList(j['by_brand'], BrandYearRow.fromJson),
    totalStores: asInt(j['total_stores']),
    closedStores: asInt(j['closed_stores']),
    unknownOpen: (j['unknown_open'] as List? ?? [])
        .map((v) => asString(v))
        .toList(),
  );
}

class YearCount {
  const YearCount({required this.year, required this.count});

  final String year;
  final int count;

  factory YearCount.fromJson(Map<String, dynamic> j) =>
      YearCount(year: asString(j['year']), count: asInt(j['count']));
}

class ServiceDashboard {
  const ServiceDashboard({
    required this.total,
    required this.thisYear,
    required this.openCount,
    required this.openTickets,
    required this.unreturnedRentals,
    required this.recent,
    required this.byYear,
  });

  final int total;
  final int thisYear;
  final int openCount;
  final List<TicketBrief> openTickets;
  final List<RentalRow> unreturnedRentals;
  final List<ServiceTicket> recent;
  final List<YearCount> byYear;

  factory ServiceDashboard.fromJson(Map<String, dynamic> j) => ServiceDashboard(
    total: asInt(j['total']),
    thisYear: asInt(j['this_year']),
    openCount: asInt(j['open_count']),
    openTickets: asList(j['open_tickets'], TicketBrief.fromJson),
    unreturnedRentals: asList(j['unreturned_rentals'], RentalRow.fromJson),
    recent: asList(j['recent'], ServiceTicket.fromJson),
    byYear: asList(j['by_year'], YearCount.fromJson),
  );
}
