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
    });
    return PagedList.fromJson(res, ServiceTicket.fromJson);
  }

  Future<ServiceTicket> get(String id) async =>
      ServiceTicket.fromJson(asMap(await _api.get('/service/tickets/$id')));

  Future<ServiceTicket> create({
    required String title,
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
      'title': title,
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
    final res = await _api.patch('/service/tickets/$id', body: changes);
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
  }) async {
    final res = await _api.post('/service/tickets/$id/status', body: {
      'status': status.value,
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
  }) async {
    final res = await _api.get('/service/stats/summary', query: {
      'date_from': dateFrom,
      'date_to': dateTo,
      'assignee_id': assigneeId,
      'category_id': categoryId,
    });
    return ServiceSummary.fromJson(asMap(res));
  }

  Future<ServiceGrouped> grouped(
    StatAxis axis, {
    DateTime? dateFrom,
    DateTime? dateTo,
    String? assigneeId,
    String? categoryId,
  }) async {
    final res = await _api.get('/service/stats/grouped', query: {
      'group_by': axis.value,
      'date_from': dateFrom,
      'date_to': dateTo,
      'assignee_id': assigneeId,
      'category_id': categoryId,
    });
    return ServiceGrouped.fromJson(asMap(res));
  }

  Future<ServiceTrend> trend({
    String interval = 'day',
    DateTime? dateFrom,
    DateTime? dateTo,
    String? assigneeId,
    String? categoryId,
  }) async {
    final res = await _api.get('/service/stats/trend', query: {
      'interval': interval,
      'date_from': dateFrom,
      'date_to': dateTo,
      'assignee_id': assigneeId,
      'category_id': categoryId,
    });
    return ServiceTrend.fromJson(asMap(res));
  }
}
