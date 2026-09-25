import '../core/api_client.dart';
import '../models/common.dart';
import '../models/worklog.dart';

class WorkLogRepository {
  WorkLogRepository(this._api);
  final ApiClient _api;

  Future<PagedList<WorkLog>> list({Map<String, dynamic> filters = const {},
      int page = 1, int size = 20}) async => PagedList.fromJson(
    await _api.get('/worklogs', query: {...filters, 'page': page, 'size': size}),
    WorkLog.fromJson);

  Future<WorkLog> get(String id) async =>
      WorkLog.fromJson(asMap(await _api.get('/worklogs/$id')));
  Future<WorkLog> create(Map<String, dynamic> data) async =>
      WorkLog.fromJson(asMap(await _api.post('/worklogs', body: data)));
  Future<WorkLog> update(String id, Map<String, dynamic> changes) async =>
      WorkLog.fromJson(asMap(await _api.patch('/worklogs/$id', body: changes)));
  Future<void> delete(String id) => _api.delete('/worklogs/$id');
  Future<WorkLogLookups> lookups({String scope = 'mine'}) async =>
      WorkLogLookups.fromJson(asMap(await _api.get('/worklogs/lookups', query: {'scope': scope})));
  Future<WorkLogDraft?> getDraft() async {
    final data = await _api.get('/worklogs/draft');
    return data == null ? null : WorkLogDraft.fromJson(asMap(data));
  }
  Future<WorkLogDraft> putDraft(Map<String, dynamic> data) async =>
      WorkLogDraft.fromJson(asMap(await _api.put('/worklogs/draft', body: {'data': data})));
  Future<void> deleteDraft() => _api.delete('/worklogs/draft');
  Future<List<int>> exportXlsx(Map<String, dynamic> filters) => _api.getBytes(
    Uri(path: '/worklogs/export.xlsx', queryParameters: {
      for (final entry in filters.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    }).toString());
}
