import 'package:flutter/material.dart';

import 'common.dart';
part 'service_statistics.dart';

enum ServiceStatus {
  unknown('UNKNOWN', '알 수 없는 상태', Color(0xFF64748B)),
  received('RECEIVED', '접수', Color(0xFF94A3B8)),
  assigned('ASSIGNED', '배정', Color(0xFF60A5FA)),
  inProgress('IN_PROGRESS', '진행중', Color(0xFF3B82F6)),
  pendingParts('PENDING_PARTS', '부품대기', Color(0xFFF59E0B)),
  completed('COMPLETED', '종결', Color(0xFF10B981)),
  canceled('CANCELED', '취소', Color(0xFFEF4444));

  const ServiceStatus(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  static ServiceStatus parse(String? v) => ServiceStatus.values.firstWhere(
    (s) => s.value == v,
    orElse: () => ServiceStatus.unknown,
  );

  bool get isOpen =>
      this != ServiceStatus.unknown &&
      this != ServiceStatus.completed &&
      this != ServiceStatus.canceled;

  /// Moves the UI offers from the current state. The server accepts any
  /// transition, but showing every option makes the workflow meaningless.
  List<ServiceStatus> get nextOptions => switch (this) {
    ServiceStatus.unknown => const [],
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

  static ServicePriority parse(String? v) => ServicePriority.values.firstWhere(
    (p) => p.value == v,
    orElse: () => ServicePriority.normal,
  );
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

  static ServiceChannel parse(String? v) => ServiceChannel.values.firstWhere(
    (c) => c.value == v,
    orElse: () => ServiceChannel.phone,
  );
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
    this.author,
  });

  final String id;
  final String? content;
  final ServiceStatus? fromStatus;
  final ServiceStatus? toStatus;
  final int? workMinutes;
  final DateTime? createdAt;
  final UserBrief? author;

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
    author: j['author'] is Map ? UserBrief.fromJson(asMap(j['author'])) : null,
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
    this.contactName,
    this.contactPhone,
    this.siteAddress,
    this.productName,
    this.modelName,
    this.serialNo,
    this.workTypeId,
    this.workType,
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
    this.legacyNo,
    this.storeId,
    this.storeName,
    this.brandName,
    this.faultId,
    this.fault,
    this.causes = const [],
    this.causeLabels = const [],
    this.responders = const [],
    this.responderNames = const [],
    this.isRental = false,
    this.rentalTypeId,
    this.rentalType,
    this.rentalSerials,
    this.rentalDueDate,
    this.rentalReturned = false,
    this.rentalReturnDate,
    this.attachmentCount = 0,
    this.logCount = 0,
    this.notices = const [],
    this.store,
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
  final String? contactName;
  final String? contactPhone;
  final String? siteAddress;
  final String? productName;
  final String? modelName;
  final String? serialNo;
  final String? workTypeId;
  final CodeItem? workType;
  String get workTypeLabel =>
      workType == null ? '미분류' : '${workType!.code} · ${workType!.name}';
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
  final int? legacyNo;
  final String? storeId;
  final String? storeName;
  final String? brandName;
  final String? faultId;
  final CodeItem? fault;
  final List<CauseRow> causes;
  final List<String> causeLabels;
  final List<CodeItem> responders;
  final List<String> responderNames;
  final bool isRental;
  final String? rentalTypeId;
  final CodeItem? rentalType;
  final String? rentalSerials;
  final DateTime? rentalDueDate;
  final bool rentalReturned;
  final DateTime? rentalReturnDate;
  final int attachmentCount;
  final int logCount;
  final List<String> notices;
  final StoreRef? store;

  String get displayNo => ticketNo;

  /// Display name regardless of whether the ticket points at a customer row.
  String get customerLabel => customer?.name ?? customerName ?? '거래처 미지정';

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
    contactName: j['contact_name'] as String?,
    contactPhone: j['contact_phone'] as String?,
    siteAddress: j['site_address'] as String?,
    productName: j['product_name'] as String?,
    modelName: j['model_name'] as String?,
    serialNo: j['serial_no'] as String?,
    workTypeId: j['work_type_id'] as String?,
    workType: j['work_type'] is Map
        ? CodeItem.fromJson(asMap(j['work_type']))
        : null,
    categoryId: j['category_id'] as String?,
    symptomId: j['symptom_id'] as String?,
    causeId: j['cause_id'] as String?,
    actionId: j['action_id'] as String?,
    assigneeId: j['assignee_id'] as String?,
    assignee: j['assignee'] is Map
        ? UserBrief.fromJson(asMap(j['assignee']))
        : null,
    customer: j['customer'] is Map
        ? Customer.fromJson(asMap(j['customer']))
        : null,
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
    satisfaction: j['satisfaction'] == null ? null : asInt(j['satisfaction']),
    resolutionMinutes: j['resolution_minutes'] == null
        ? null
        : asInt(j['resolution_minutes']),
    parts: asList(j['parts'], ServicePart.fromJson),
    logs: asList(j['logs'], ServiceLog.fromJson),
    legacyNo: j['legacy_no'] == null ? null : asInt(j['legacy_no']),
    storeId: j['store_id'] as String?,
    storeName: j['store_name'] as String?,
    brandName: j['brand_name'] as String?,
    faultId: j['fault_id'] as String?,
    fault: j['fault'] is Map ? CodeItem.fromJson(asMap(j['fault'])) : null,
    causes: asList(j['causes'], CauseRow.fromJson),
    causeLabels: (j['cause_labels'] as List? ?? [])
        .map((v) => asString(v))
        .toList(),
    responders: asList(j['responders'], CodeItem.fromJson),
    responderNames: (j['responder_names'] as List? ?? [])
        .map((v) => asString(v))
        .toList(),
    isRental: asBool(j['is_rental']),
    rentalTypeId: j['rental_type_id'] as String?,
    rentalType: j['rental_type'] is Map
        ? CodeItem.fromJson(asMap(j['rental_type']))
        : null,
    rentalSerials: j['rental_serials'] as String?,
    rentalDueDate: asDate(j['rental_due_date']),
    rentalReturned: asBool(j['rental_returned']),
    rentalReturnDate: asDate(j['rental_return_date']),
    attachmentCount: asInt(j['attachment_count']),
    logCount: asInt(j['log_count']),
    notices: (j['notices'] as List? ?? []).map((v) => asString(v)).toList(),
    store: j['store'] is Map ? StoreRef.fromJson(asMap(j['store'])) : null,
  );
}

// ------------------------------------------------------------------ stats

class CauseRow {
  const CauseRow({
    required this.id,
    required this.seq,
    this.categoryId,
    this.symptomId,
    this.makerId,
    this.category,
    this.symptom,
    this.maker,
  });

  final String id;
  final int seq;
  final String? categoryId;
  final String? symptomId;
  final String? makerId;
  final CodeItem? category;
  final CodeItem? symptom;
  final CodeItem? maker;

  factory CauseRow.fromJson(Map<String, dynamic> j) => CauseRow(
    id: asString(j['id']),
    seq: asInt(j['seq']),
    categoryId: j['category_id'] as String?,
    symptomId: j['symptom_id'] as String?,
    makerId: j['maker_id'] as String?,
    category: j['category'] is Map
        ? CodeItem.fromJson(asMap(j['category']))
        : null,
    symptom: j['symptom'] is Map
        ? CodeItem.fromJson(asMap(j['symptom']))
        : null,
    maker: j['maker'] is Map ? CodeItem.fromJson(asMap(j['maker'])) : null,
  );
}

class StoreRef {
  const StoreRef({
    required this.id,
    required this.name,
    this.brandId,
    this.brandName,
    required this.isClosed,
  });

  final String id;
  final String name;
  final String? brandId;
  final String? brandName;
  final bool isClosed;

  factory StoreRef.fromJson(Map<String, dynamic> j) => StoreRef(
    id: asString(j['id']),
    name: asString(j['name']),
    brandId: j['brand_id'] as String?,
    brandName: j['brand_name'] as String?,
    isClosed: asBool(j['is_closed']),
  );
}

class TicketBrief {
  const TicketBrief({
    required this.id,
    required this.ticketNo,
    required this.title,
    this.storeName,
    this.brandName,
    required this.status,
    required this.receivedAt,
    this.daysOpen,
  });

  final String id;
  final String ticketNo;
  final String title;
  final String? storeName;
  final String? brandName;
  final ServiceStatus status;
  final DateTime receivedAt;
  final int? daysOpen;

  factory TicketBrief.fromJson(Map<String, dynamic> j) => TicketBrief(
    id: asString(j['id']),
    ticketNo: asString(j['ticket_no']),
    title: asString(j['title']),
    storeName: j['store_name'] as String?,
    brandName: j['brand_name'] as String?,
    status: ServiceStatus.parse(j['status'] as String?),
    receivedAt: asDate(j['received_at']) ?? DateTime.now(),
    daysOpen: j['days_open'] == null ? null : asInt(j['days_open']),
  );
}

class RentalRow {
  const RentalRow({
    required this.ticketId,
    required this.ticketNo,
    this.storeName,
    this.rentalType,
    this.serials,
    this.dueDate,
    this.dday,
  });

  final String ticketId;
  final String ticketNo;
  final String? storeName;
  final String? rentalType;
  final String? serials;
  final DateTime? dueDate;
  final int? dday;

  factory RentalRow.fromJson(Map<String, dynamic> j) => RentalRow(
    ticketId: asString(j['ticket_id']),
    ticketNo: asString(j['ticket_no']),
    storeName: j['store_name'] as String?,
    rentalType: j['rental_type'] as String?,
    serials: j['serials'] as String?,
    dueDate: asDate(j['due_date']),
    dday: j['dday'] == null ? null : asInt(j['dday']),
  );
}
