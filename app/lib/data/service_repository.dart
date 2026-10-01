import '../core/api_client.dart';
import '../models/common.dart';
import '../models/service.dart';
import '../models/service_filter.dart';
export '../models/service_filter.dart';

class ServiceRepository {
  ServiceRepository(this._api);
  final ApiClient _api;
  Future<List<int>> exportAllStats(Map<String, dynamic> filters) =>
      _api.getBytes(_downloadPath('/service/stats/all.xlsx', filters));

  Future<void> updateLog(
    String id,
    String logId,
    String content,
    int minutes,
  ) async {
    await _api.patch(
      '/service/tickets/$id/logs/$logId',
      body: {'content': content, 'work_minutes': minutes},
    );
  }

  Future<void> deleteLog(String id, String logId) async {
    await _api.delete('/service/tickets/$id/logs/$logId');
  }

  Future<void> addPart(
    String id,
    String name,
    double quantity,
    double price, {
    String? assetId,
  }) async {
    await _api.post(
      '/service/tickets/$id/parts',
      body: {
        'part_name': name,
        'quantity': quantity,
        'unit_price': price,
        'asset_id': assetId,
      },
    );
  }

  Future<void> removePart(String id, String partId) async {
    await _api.delete('/service/tickets/$id/parts/$partId');
  }

  Future<PagedList<ServiceTicket>> list({
    int page = 1,
    int size = 20,
    String? query,
    ServiceStatus? status,
    ServicePriority? priority,
    String? assigneeId,
    String? customerId,
    String? workTypeId,
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
    final res = await _api.get(
      '/service/tickets',
      query: {
        'page': page,
        'size': size,
        'q': query,
        'status': status?.value,
        'priority': priority?.value,
        'assignee_id': assigneeId,
        'customer_id': customerId,
        'work_type_id': workTypeId,
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
      },
    );
    return PagedList.fromJson(res, ServiceTicket.fromJson);
  }

  Future<ServiceTicket> get(String id) async =>
      ServiceTicket.fromJson(asMap(await _api.get('/service/tickets/$id')));

  Future<ServiceTicket> create({
    ServiceStatus? initialStatus,
    String? note,
    String? resultNote,
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
    String? contactName,
    String? contactPhone,
    String? siteAddress,
    String? productName,
    String? modelName,
    String? serialNo,
    String? workTypeId,
    String? categoryId,
    String? symptomId,
    String? assigneeId,
    ServicePriority priority = ServicePriority.normal,
    ServiceChannel channel = ServiceChannel.phone,
    bool isWarranty = true,
    String? description,
  }) async {
    final res = await _api.post(
      '/service/tickets',
      body: {
        'initial_status': initialStatus?.value,
        'note': note,
        'result_note': resultNote,
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
        'contact_name': contactName,
        'contact_phone': contactPhone,
        'site_address': siteAddress,
        'product_name': productName,
        'model_name': modelName,
        'serial_no': serialNo,
        'work_type_id': workTypeId,
        'category_id': categoryId,
        'symptom_id': symptomId,
        'assignee_id': assigneeId,
        'priority': priority.value,
        'channel': channel.value,
        'is_warranty': isWarranty,
        'description': description,
      }..removeWhere((_, v) => v == null),
    );
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
      body['received_at'] = (body['received_at'] as DateTime)
          .toUtc()
          .toIso8601String();
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
    final res = await _api.post(
      '/service/tickets/$id/status',
      body: {
        'status': status.value,
        if (responderIds != null) 'responder_ids': responderIds,
        if (completedAt != null)
          'completed_at': completedAt.toUtc().toIso8601String(),
        if (note != null) 'note': note,
        if (resultNote != null) 'result_note': resultNote,
        if (workMinutes != null) 'work_minutes': workMinutes,
      },
    );
    return ServiceTicket.fromJson(asMap(res));
  }

  Future<void> addLog(String id, String content, {int? workMinutes}) =>
      _api.post(
        '/service/tickets/$id/logs',
        body: {
          'content': content,
          if (workMinutes != null) 'work_minutes': workMinutes,
        },
      );

  Future<void> delete(String id) => _api.delete('/service/tickets/$id');

  Future<PagedList<Customer>> customers({String? query, int size = 50}) async {
    final res = await _api.get(
      '/service/customers',
      query: {'q': query, 'size': size, 'page': 1},
    );
    return PagedList.fromJson(res, Customer.fromJson);
  }

  Future<Customer> createCustomer({
    required String name,
    String? phone,
    String? address,
  }) async {
    final res = await _api.post(
      '/service/customers',
      body: {
        'name': name,
        if (phone?.isNotEmpty == true) 'phone': phone,
        if (address?.isNotEmpty == true) 'address': address,
      },
    );
    return Customer.fromJson(asMap(res));
  }

  Future<ServiceSummary> summary({
    ServiceFilter filter = const ServiceFilter(),
    Map<String, dynamic> filters = const {},
  }) async => ServiceSummary.fromJson(
    asMap(
      await _api.get('/service/stats/summary', query: filter.toQuery(filters)),
    ),
  );

  Future<ServiceGrouped> grouped(
    StatAxis axis, {
    ServiceFilter filter = const ServiceFilter(),
    Map<String, dynamic> filters = const {},
  }) async => ServiceGrouped.fromJson(
    asMap(
      await _api.get(
        '/service/stats/grouped',
        query: {...filter.toQuery(filters), 'group_by': axis.value},
      ),
    ),
  );

  Future<ServiceTrend> trend({
    String interval = 'day',
    ServiceFilter filter = const ServiceFilter(),
    Map<String, dynamic> filters = const {},
  }) async => ServiceTrend.fromJson(
    asMap(
      await _api.get(
        '/service/stats/trend',
        query: {...filter.toQuery(filters), 'interval': interval},
      ),
    ),
  );

  static String titleFromDescription(String description) {
    final line = description.trim().split(RegExp(r'[\r\n]')).first;
    return String.fromCharCodes(line.runes.take(250));
  }

  static String? dateOnly(DateTime? date) => date == null
      ? null
      : '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<ServiceDashboard> dashboard({int limit = 10}) async =>
      ServiceDashboard.fromJson(
        asMap(await _api.get('/service/dashboard', query: {'limit': limit})),
      );

  Future<StoreYears> storeYears() async =>
      StoreYears.fromJson(asMap(await _api.get('/service/stats/store-years')));

  Future<Crosstab> crosstab(
    String rows,
    String cols, {
    ServiceFilter filter = const ServiceFilter(),
    Map<String, dynamic> filters = const {},
  }) async => Crosstab.fromJson(
    asMap(
      await _api.get(
        '/service/stats/crosstab',
        query: {...filter.toQuery(filters), 'rows': rows, 'cols': cols},
      ),
    ),
  );

  Future<List<int>> exportXlsx({
    ServiceFilter filter = const ServiceFilter(),
    Map<String, dynamic> filters = const {},
  }) => _api.getBytes(
    _downloadPath('/service/tickets/export.xlsx', filter.toQuery(filters)),
  );

  Future<List<int>> crosstabXlsx(
    String rows,
    String cols, {
    ServiceFilter filter = const ServiceFilter(),
    Map<String, dynamic> filters = const {},
  }) => _api.getBytes(
    _downloadPath('/service/stats/crosstab.xlsx', {
      ...filter.toQuery(filters),
      'rows': rows,
      'cols': cols,
    }),
  );

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
