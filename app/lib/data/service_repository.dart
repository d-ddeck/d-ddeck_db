import '../core/api_client.dart';
import '../models/common.dart';
import '../models/service.dart';

class ServiceRepository {
  ServiceRepository(this._api);
  final ApiClient _api;

  Future<PagedList<ServiceTicket>> list({
    int page = 1,
    int size = 20,
    String? query,
    ServiceStatus? status,
    ServicePriority? priority,
    String? assigneeId,
    String? customerId,
    String? categoryId,
    bool onlyOpen = false,
    DateTime? dateFrom,
    DateTime? dateTo,
    String sort = 'received_desc',
    int? year,
    int? month,
    String? brandId,
    String? storeId,
    String? symptomId,
    String? makerId,
    String? faultId,
    String? responderId,
    bool? isRental,
    bool rentalUnreturned = false,
    Map<String, dynamic> filters = const {},
  }) async {
    final res = await _api.get('/service/tickets', query: {
      'page': page,
      'size': size,
      'q': query,
      'status': status?.value,
      'priority': priority?.value,
      'assignee_id': assigneeId,
      'customer_id': customerId,
      'category_id': categoryId,
      'only_open': onlyOpen ? true : null,
      'date_from': dateFrom,
      'date_to': dateTo,
      'sort': sort,
      'year': year,
      'month': month,
      'brand_id': brandId,
      'store_id': storeId,
      'symptom_id': symptomId,
      'maker_id': makerId,
      'fault_id': faultId,
      'responder_id': responderId,
      'is_rental': isRental,
      'rental_unreturned': rentalUnreturned ? true : null,
      ...filters,
    });
    return PagedList.fromJson(res, ServiceTicket.fromJson);
  }

  Future<ServiceTicket> get(String id) async =>
      ServiceTicket.fromJson(asMap(await _api.get('/service/tickets/$id')));

  Future<ServiceTicket> create({
    String? title,
    String? storeId,
    String? faultId,
    DateTime? receivedAt,
    List<Map<String, dynamic>>? causes,
    List<String>? responderIds,
    bool isRental = false,
    String? rentalTypeId,
    String? rentalSerials,
    DateTime? rentalDueDate,
    bool rentalReturned = false,
    DateTime? rentalReturnDate,
    String? customerId,
    String? customerName,
    String? contactPhone,
    String? siteAddress,
    String? productName,
    String? modelName,
    String? serialNo,
    String? categoryId,
    String? symptomId,
    String? assigneeId,
    ServicePriority priority = ServicePriority.normal,
    ServiceChannel channel = ServiceChannel.phone,
    bool isWarranty = true,
    String? description,
  }) async {
    final res = await _api.post('/service/tickets', body: {
      'title': titleFromDescription(description ?? title ?? ''),
      'store_id': storeId,
      'fault_id': faultId,
      'received_at': receivedAt?.toUtc().toIso8601String(),
      'causes': causes,
      'responder_ids': responderIds,
      'is_rental': isRental,
      'rental_type_id': rentalTypeId,
      'rental_serials': rentalSerials,
      'rental_due_date': dateOnly(rentalDueDate),
      'rental_returned': rentalReturned,
      'rental_return_date': dateOnly(rentalReturnDate),
      'customer_id': customerId,
      'customer_name': customerName,
      'contact_phone': contactPhone,
      'site_address': siteAddress,
      'product_name': productName,
      'model_name': modelName,
      'serial_no': serialNo,
      'category_id': categoryId,
      'symptom_id': symptomId,
      'assignee_id': assigneeId,
      'priority': priority.value,
      'channel': channel.value,
      'is_warranty': isWarranty,
      'description': description,
    }..removeWhere((_, v) => v == null));
    return ServiceTicket.fromJson(asMap(res));
  }

  Future<ServiceTicket> update(String id, Map<String, dynamic> changes) async {
    final body = Map<String, dynamic>.from(changes);
    if (body.containsKey('description')) {
      body['title'] = titleFromDescription(asString(body['description']));
    }
    for (final key in ['rental_due_date', 'rental_return_date']) {
      if (body[key] is DateTime) body[key] = dateOnly(body[key] as DateTime);
    }
    if (body['received_at'] is DateTime) {
      body['received_at'] = (body['received_at'] as DateTime).toUtc().toIso8601String();
    }
    final res = await _api.patch('/service/tickets/$id', body: body);
    return ServiceTicket.fromJson(asMap(res));
  }

  /// The only way status moves. The server keeps the timeline fields and the
  /// work log in sync, which a plain PATCH would not.
  Future<ServiceTicket> changeStatus(
    String id,
    ServiceStatus status, {
    String? note,
    String? resultNote,
    int? workMinutes,
    List<String>? responderIds,
    DateTime? completedAt,
  }) async {
    final res = await _api.post('/service/tickets/$id/status', body: {
      'status': status.value,
      if (responderIds != null) 'responder_ids': responderIds,
      if (completedAt != null) 'completed_at': completedAt.toUtc().toIso8601String(),
      if (note != null) 'note': note,
      if (resultNote != null) 'result_note': resultNote,
      if (workMinutes != null) 'work_minutes': workMinutes,
    });
    return ServiceTicket.fromJson(asMap(res));
  }

  Future<void> addLog(String id, String content, {int? workMinutes}) =>
      _api.post('/service/tickets/$id/logs', body: {
        'content': content,
        if (workMinutes != null) 'work_minutes': workMinutes,
      });

  Future<void> delete(String id) => _api.delete('/service/tickets/$id');

  Future<PagedList<Customer>> customers({String? query, int size = 50}) async {
    final res = await _api.get('/service/customers',
        query: {'q': query, 'size': size, 'page': 1});
    return PagedList.fromJson(res, Customer.fromJson);
  }

  Future<Customer> createCustomer({
    required String name,
    String? phone,
    String? address,
  }) async {
    final res = await _api.post('/service/customers', body: {
      'name': name,
      if (phone?.isNotEmpty == true) 'phone': phone,
      if (address?.isNotEmpty == true) 'address': address,
    });
    return Customer.fromJson(asMap(res));
  }

  // ---------------------------------------------------------- statistics
  // All three take the same filters, so passing the screen's filter bar to
  // each keeps the numbers consistent across summary, breakdown and trend.

  Future<ServiceSummary> summary({
    DateTime? dateFrom,
    DateTime? dateTo,
    String? assigneeId,
    String? categoryId,
    int? year,
    int? month,
    String? brandId,
    String? storeId,
    String? symptomId,
    String? makerId,
    String? faultId,
    String? responderId,
    bool? isRental,
    bool rentalUnreturned = false,
    Map<String, dynamic> filters = const {},
  }) async {
    final res = await _api.get('/service/stats/summary', query: {
      'date_from': dateFrom,
      'date_to': dateTo,
      'assignee_id': assigneeId,
      'category_id': categoryId,
      'year': year,
      'month': month,
      'brand_id': brandId,
      'store_id': storeId,
      'symptom_id': symptomId,
      'maker_id': makerId,
      'fault_id': faultId,
      'responder_id': responderId,
      'is_rental': isRental,
      'rental_unreturned': rentalUnreturned ? true : null,
      ...filters,
    });
    return ServiceSummary.fromJson(asMap(res));
  }

  Future<ServiceGrouped> grouped(
    StatAxis axis, {
    DateTime? dateFrom,
    DateTime? dateTo,
    String? assigneeId,
    String? categoryId,
    int? year,
    int? month,
    String? brandId,
    String? storeId,
    String? symptomId,
    String? makerId,
    String? faultId,
    String? responderId,
    bool? isRental,
    bool rentalUnreturned = false,
    Map<String, dynamic> filters = const {},
  }) async {
    final res = await _api.get('/service/stats/grouped', query: {
      'group_by': axis.value,
      'date_from': dateFrom,
      'date_to': dateTo,
      'assignee_id': assigneeId,
      'category_id': categoryId,
      'year': year,
      'month': month,
      'brand_id': brandId,
      'store_id': storeId,
      'symptom_id': symptomId,
      'maker_id': makerId,
      'fault_id': faultId,
      'responder_id': responderId,
      'is_rental': isRental,
      'rental_unreturned': rentalUnreturned ? true : null,
      ...filters,
    });
    return ServiceGrouped.fromJson(asMap(res));
  }

  Future<ServiceTrend> trend({
    String interval = 'day',
    DateTime? dateFrom,
    DateTime? dateTo,
    String? assigneeId,
    String? categoryId,
    int? year,
    int? month,
    String? brandId,
    String? storeId,
    String? symptomId,
    String? makerId,
    String? faultId,
    String? responderId,
    bool? isRental,
    bool rentalUnreturned = false,
    Map<String, dynamic> filters = const {},
  }) async {
    final res = await _api.get('/service/stats/trend', query: {
      'interval': interval,
      'date_from': dateFrom,
      'date_to': dateTo,
      'assignee_id': assigneeId,
      'category_id': categoryId,
      'year': year,
      'month': month,
      'brand_id': brandId,
      'store_id': storeId,
      'symptom_id': symptomId,
      'maker_id': makerId,
      'fault_id': faultId,
      'responder_id': responderId,
      'is_rental': isRental,
      'rental_unreturned': rentalUnreturned ? true : null,
      ...filters,
    });
    return ServiceTrend.fromJson(asMap(res));
  }

  static String titleFromDescription(String description) {
    final line = description.trim().split(RegExp(r'[\r\n]')).first;
    return String.fromCharCodes(line.runes.take(250));
  }

  static String? dateOnly(DateTime? date) => date == null ? null
      : '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<ServiceDashboard> dashboard({int limit = 10}) async =>
      ServiceDashboard.fromJson(asMap(await _api.get('/service/dashboard', query: {'limit': limit})));

  Future<StoreYears> storeYears() async =>
      StoreYears.fromJson(asMap(await _api.get('/service/stats/store-years')));

  Future<Crosstab> crosstab(String rows, String cols, {
    int? year,
    int? month,
    String? brandId,
    String? storeId,
    String? symptomId,
    String? makerId,
    String? faultId,
    String? responderId,
    bool? isRental,
    bool rentalUnreturned = false,
    Map<String, dynamic> filters = const {},
    DateTime? dateFrom,
    DateTime? dateTo,
    String? categoryId,
    String? assigneeId,
    String? customerId,
    String? departmentId,
    ServiceStatus? status,
    bool onlyOpen = false,
    bool? isWarranty,
  }) async {
    final queryValues = <String, dynamic>{
      'year': year,
      'month': month,
      'brand_id': brandId,
      'store_id': storeId,
      'symptom_id': symptomId,
      'maker_id': makerId,
      'fault_id': faultId,
      'responder_id': responderId,
      'is_rental': isRental,
      'rental_unreturned': rentalUnreturned ? true : null,
      'date_from': dateFrom,
      'date_to': dateTo,
      'category_id': categoryId,
      'assignee_id': assigneeId,
      'customer_id': customerId,
      'department_id': departmentId,
      'status': status?.value,
      'only_open': onlyOpen ? true : null,
      'is_warranty': isWarranty,
      'rows': rows,
      'cols': cols,
      ...filters,
    };
    return Crosstab.fromJson(asMap(await _api.get('/service/stats/crosstab', query: queryValues)));
  }

  Future<List<int>> exportXlsx({
    int? year,
    int? month,
    String? brandId,
    String? storeId,
    String? symptomId,
    String? makerId,
    String? faultId,
    String? responderId,
    bool? isRental,
    bool rentalUnreturned = false,
    Map<String, dynamic> filters = const {},
    DateTime? dateFrom,
    DateTime? dateTo,
    String? categoryId,
    String? assigneeId,
    String? customerId,
    String? departmentId,
    ServiceStatus? status,
    bool onlyOpen = false,
    bool? isWarranty,
    String? query,
    ServicePriority? priority,
    ServiceChannel? channel,
  }) async {
    final queryValues = <String, dynamic>{
      'year': year,
      'month': month,
      'brand_id': brandId,
      'store_id': storeId,
      'symptom_id': symptomId,
      'maker_id': makerId,
      'fault_id': faultId,
      'responder_id': responderId,
      'is_rental': isRental,
      'rental_unreturned': rentalUnreturned ? true : null,
      'date_from': dateFrom,
      'date_to': dateTo,
      'category_id': categoryId,
      'assignee_id': assigneeId,
      'customer_id': customerId,
      'department_id': departmentId,
      'status': status?.value,
      'only_open': onlyOpen ? true : null,
      'is_warranty': isWarranty,
      'q': query,
      'priority': priority?.value,
      'channel': channel?.value,
      ...filters,
    };
    return _api.getBytes(_downloadPath('/service/tickets/export.xlsx', queryValues));
  }

  Future<List<int>> crosstabXlsx(String rows, String cols, {
    int? year,
    int? month,
    String? brandId,
    String? storeId,
    String? symptomId,
    String? makerId,
    String? faultId,
    String? responderId,
    bool? isRental,
    bool rentalUnreturned = false,
    Map<String, dynamic> filters = const {},
    DateTime? dateFrom,
    DateTime? dateTo,
    String? categoryId,
    String? assigneeId,
    String? customerId,
    String? departmentId,
    ServiceStatus? status,
    bool onlyOpen = false,
    bool? isWarranty,
  }) async {
    final queryValues = <String, dynamic>{
      'year': year,
      'month': month,
      'brand_id': brandId,
      'store_id': storeId,
      'symptom_id': symptomId,
      'maker_id': makerId,
      'fault_id': faultId,
      'responder_id': responderId,
      'is_rental': isRental,
      'rental_unreturned': rentalUnreturned ? true : null,
      'date_from': dateFrom,
      'date_to': dateTo,
      'category_id': categoryId,
      'assignee_id': assigneeId,
      'customer_id': customerId,
      'department_id': departmentId,
      'status': status?.value,
      'only_open': onlyOpen ? true : null,
      'is_warranty': isWarranty,
      'rows': rows,
      'cols': cols,
      ...filters,
    };
    return _api.getBytes(_downloadPath('/service/stats/crosstab.xlsx', queryValues));
  }

  String _downloadPath(String path, Map<String, dynamic> query) => Uri(
    path: path,
    queryParameters: {
      for (final entry in query.entries)
        if (entry.value != null)
          entry.key: entry.value is DateTime
              ? (entry.value as DateTime).toUtc().toIso8601String()
              : entry.value.toString(),
    },
  ).toString();
}
