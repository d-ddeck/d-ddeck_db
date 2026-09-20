import 'package:flutter/material.dart';

import 'common.dart';

enum ServiceStatus {
  received('RECEIVED', '접수', Color(0xFF94A3B8)),
  assigned('ASSIGNED', '배정', Color(0xFF60A5FA)),
  inProgress('IN_PROGRESS', '진행중', Color(0xFF3B82F6)),
  pendingParts('PENDING_PARTS', '부품대기', Color(0xFFF59E0B)),
  completed('COMPLETED', '완료', Color(0xFF10B981)),
  canceled('CANCELED', '취소', Color(0xFFEF4444));

  const ServiceStatus(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  static ServiceStatus parse(String? v) => ServiceStatus.values
      .firstWhere((s) => s.value == v, orElse: () => ServiceStatus.received);

  bool get isOpen =>
      this != ServiceStatus.completed && this != ServiceStatus.canceled;

  /// Moves the UI offers from the current state. The server accepts any
  /// transition, but showing every option makes the workflow meaningless.
  List<ServiceStatus> get nextOptions => switch (this) {
        ServiceStatus.received => const [assigned, inProgress, canceled],
        ServiceStatus.assigned => const [inProgress, pendingParts, canceled],
        ServiceStatus.inProgress => const [pendingParts, completed, canceled],
        ServiceStatus.pendingParts => const [inProgress, completed, canceled],
        ServiceStatus.completed => const [inProgress],
        ServiceStatus.canceled => const [received],
      };
}

enum ServicePriority {
  low('LOW', '낮음', Color(0xFF94A3B8)),
  normal('NORMAL', '보통', Color(0xFF3B82F6)),
  high('HIGH', '높음', Color(0xFFF59E0B)),
  urgent('URGENT', '긴급', Color(0xFFEF4444));

  const ServicePriority(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  static ServicePriority parse(String? v) => ServicePriority.values
      .firstWhere((p) => p.value == v, orElse: () => ServicePriority.normal);
}

enum ServiceChannel {
  phone('PHONE', '전화'),
  email('EMAIL', '이메일'),
  visit('VISIT', '방문'),
  web('WEB', '웹'),
  internal('INTERNAL', '사내');

  const ServiceChannel(this.value, this.label);
  final String value;
  final String label;

  static ServiceChannel parse(String? v) => ServiceChannel.values
      .firstWhere((c) => c.value == v, orElse: () => ServiceChannel.phone);
}

class Customer {
  const Customer({
    required this.id,
    required this.name,
    this.phone,
    this.address,
    this.contactName,
    this.isActive = true,
  });

  final String id;
  final String name;
  final String? phone;
  final String? address;
  final String? contactName;
  final bool isActive;

  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: asString(j['id']),
        name: asString(j['name']),
        phone: j['phone'] as String?,
        address: j['address'] as String?,
        contactName: j['contact_name'] as String?,
        isActive: asBool(j['is_active'], true),
      );
}

class ServicePart {
  const ServicePart({
    required this.id,
    required this.partName,
    required this.quantity,
    this.unitPrice,
  });

  final String id;
  final String partName;
  final double quantity;
  final double? unitPrice;

  double get lineTotal => quantity * (unitPrice ?? 0);

  factory ServicePart.fromJson(Map<String, dynamic> j) => ServicePart(
        id: asString(j['id']),
        partName: asString(j['part_name']),
        quantity: asDouble(j['quantity']) ?? 0,
        unitPrice: asDouble(j['unit_price']),
      );
}

class ServiceLog {
  const ServiceLog({
    required this.id,
    this.content,
    this.fromStatus,
    this.toStatus,
    this.workMinutes,
    this.createdAt,
  });

  final String id;
  final String? content;
  final ServiceStatus? fromStatus;
  final ServiceStatus? toStatus;
  final int? workMinutes;
  final DateTime? createdAt;

  factory ServiceLog.fromJson(Map<String, dynamic> j) => ServiceLog(
        id: asString(j['id']),
        content: j['content'] as String?,
        fromStatus: j['from_status'] == null
            ? null
            : ServiceStatus.parse(j['from_status'] as String?),
        toStatus: j['to_status'] == null
            ? null
            : ServiceStatus.parse(j['to_status'] as String?),
        workMinutes: j['work_minutes'] == null ? null : asInt(j['work_minutes']),
        createdAt: asDate(j['created_at']),
      );
}

class ServiceTicket {
  const ServiceTicket({
    required this.id,
    required this.ticketNo,
    required this.title,
    required this.status,
    required this.priority,
    required this.channel,
    required this.receivedAt,
    this.customerId,
    this.customerName,
    this.contactPhone,
    this.siteAddress,
    this.productName,
    this.modelName,
    this.serialNo,
    this.categoryId,
    this.symptomId,
    this.causeId,
    this.actionId,
    this.assigneeId,
    this.assignee,
    this.customer,
    this.startedAt,
    this.completedAt,
    this.dueAt,
    this.isWarranty = true,
    this.workMinutes,
    this.laborCost,
    this.partsCost,
    this.totalCost,
    this.description,
    this.resultNote,
    this.satisfaction,
    this.resolutionMinutes,
    this.parts = const [],
    this.logs = const [],
  });

  final String id;
  final String ticketNo;
  final String title;
  final ServiceStatus status;
  final ServicePriority priority;
  final ServiceChannel channel;
  final DateTime receivedAt;
  final String? customerId;
  final String? customerName;
  final String? contactPhone;
  final String? siteAddress;
  final String? productName;
  final String? modelName;
  final String? serialNo;
  final String? categoryId;
  final String? symptomId;
  final String? causeId;
  final String? actionId;
  final String? assigneeId;
  final UserBrief? assignee;
  final Customer? customer;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? dueAt;
  final bool isWarranty;
  final int? workMinutes;
  final double? laborCost;
  final double? partsCost;
  final double? totalCost;
  final String? description;
  final String? resultNote;
  final int? satisfaction;
  final int? resolutionMinutes;
  final List<ServicePart> parts;
  final List<ServiceLog> logs;

  /// Display name regardless of whether the ticket points at a customer row.
  String get customerLabel =>
      customer?.name ?? customerName ?? '거래처 미지정';

  bool get isOverdue =>
      dueAt != null && status.isOpen && dueAt!.isBefore(DateTime.now());

  factory ServiceTicket.fromJson(Map<String, dynamic> j) => ServiceTicket(
        id: asString(j['id']),
        ticketNo: asString(j['ticket_no']),
        title: asString(j['title']),
        status: ServiceStatus.parse(j['status'] as String?),
        priority: ServicePriority.parse(j['priority'] as String?),
        channel: ServiceChannel.parse(j['channel'] as String?),
        receivedAt: asDate(j['received_at']) ?? DateTime.now(),
        customerId: j['customer_id'] as String?,
        customerName: j['customer_name'] as String?,
        contactPhone: j['contact_phone'] as String?,
        siteAddress: j['site_address'] as String?,
        productName: j['product_name'] as String?,
        modelName: j['model_name'] as String?,
        serialNo: j['serial_no'] as String?,
        categoryId: j['category_id'] as String?,
        symptomId: j['symptom_id'] as String?,
        causeId: j['cause_id'] as String?,
        actionId: j['action_id'] as String?,
        assigneeId: j['assignee_id'] as String?,
        assignee: j['assignee'] is Map
            ? UserBrief.fromJson(asMap(j['assignee']))
            : null,
        customer:
            j['customer'] is Map ? Customer.fromJson(asMap(j['customer'])) : null,
        startedAt: asDate(j['started_at']),
        completedAt: asDate(j['completed_at']),
        dueAt: asDate(j['due_at']),
        isWarranty: asBool(j['is_warranty'], true),
        workMinutes: j['work_minutes'] == null ? null : asInt(j['work_minutes']),
        laborCost: asDouble(j['labor_cost']),
        partsCost: asDouble(j['parts_cost']),
        totalCost: asDouble(j['total_cost']),
        description: j['description'] as String?,
        resultNote: j['result_note'] as String?,
        satisfaction:
            j['satisfaction'] == null ? null : asInt(j['satisfaction']),
        resolutionMinutes: j['resolution_minutes'] == null
            ? null
            : asInt(j['resolution_minutes']),
        parts: asList(j['parts'], ServicePart.fromJson),
        logs: asList(j['logs'], ServiceLog.fromJson),
      );
}

// ------------------------------------------------------------------ stats

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
  });

  final String groupBy;
  final int total;
  final List<StatBucket> buckets;

  factory ServiceGrouped.fromJson(Map<String, dynamic> j) => ServiceGrouped(
        groupBy: asString(j['group_by']),
        total: asInt(j['total']),
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
  category('category', '서비스 분류'),
  symptom('symptom', '증상'),
  cause('cause', '원인'),
  action('action', '조치'),
  assignee('assignee', '담당자'),
  status('status', '상태'),
  priority('priority', '우선순위'),
  channel('channel', '접수 경로');

  const StatAxis(this.value, this.label);
  final String value;
  final String label;
}
