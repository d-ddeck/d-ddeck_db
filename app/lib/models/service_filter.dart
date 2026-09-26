import 'service.dart';

/// Shared immutable criteria for lists, statistics and exports.
class ServiceFilter {
  const ServiceFilter({
    this.dateFrom,
    this.dateTo,
    this.year,
    this.month,
    this.brandId,
    this.storeId,
    this.symptomId,
    this.makerId,
    this.faultId,
    this.responderId,
    this.categoryId,
    this.workTypeId,
    this.assigneeId,
    this.customerId,
    this.departmentId,
    this.query,
    this.missing,
    this.isRental,
    this.isWarranty,
    this.onlyOpen,
    this.rentalUnreturned,
    this.status,
    this.priority,
    this.channel,
  });
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final int? year;
  final int? month;
  final String? brandId;
  final String? storeId;
  final String? symptomId;
  final String? makerId;
  final String? faultId;
  final String? responderId;
  final String? categoryId;
  final String? workTypeId;
  final String? assigneeId;
  final String? customerId;
  final String? departmentId;
  final String? query;
  final String? missing;
  final bool? isRental;
  final bool? isWarranty;
  final bool? onlyOpen;
  final bool? rentalUnreturned;
  final ServiceStatus? status;
  final ServicePriority? priority;
  final ServiceChannel? channel;
  Map<String, dynamic> toQuery([Map<String, dynamic> overrides = const {}]) => {
    'date_from': dateFrom,
    'date_to': dateTo,
    'year': year,
    'month': month,
    'brand_id': brandId,
    'store_id': storeId,
    'symptom_id': symptomId,
    'maker_id': makerId,
    'fault_id': faultId,
    'responder_id': responderId,
    'category_id': categoryId,
    'work_type_id': workTypeId,
    'assignee_id': assigneeId,
    'customer_id': customerId,
    'department_id': departmentId,
    'q': query,
    'missing': missing,
    'is_rental': isRental,
    'is_warranty': isWarranty,
    'only_open': onlyOpen,
    'rental_unreturned': rentalUnreturned,
    'status': status?.value,
    'priority': priority?.value,
    'channel': channel?.value,
    ...overrides,
  }..removeWhere((_, value) => value == null);
}
