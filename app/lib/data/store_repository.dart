import '../core/api_client.dart';
import '../models/common.dart';
import '../models/store.dart';
import 'service_repository.dart';

/// 매장과 "그 매장에 나가 있는 우리 장비".
///
/// 재고(`InventoryRepository`)와 같은 `assets` 행을 읽지만 축이 다르다.
/// 재고는 창고 기준, 이쪽은 고객 사이트 기준이다.
class StoreRepository {
  StoreRepository(this._api);
  final ApiClient _api;

  /// 브랜드별 매장·자산 현황. 매장 화면의 첫 단계.
  Future<List<BrandSummary>> brands() async {
    final res = await _api.get('/stores/brands');
    return (res as List? ?? [])
        .map((e) => BrandSummary.fromJson(asMap(e)))
        .toList();
  }

  Future<PagedList<Store>> list({
    int page = 1,
    int size = 50,
    String? query,
    String? brandId,
    bool includeClosed = false,
  }) async {
    final res = await _api.get('/stores', query: {
      'page': page,
      'size': size,
      'q': query,
      'brand_id': brandId,
      // 기본이 false 라 켤 때만 보낸다.
      'include_closed': includeClosed ? true : null,
    });
    return PagedList.fromJson(res, Store.fromJson);
  }

  /// 매장 하나 + 보유 장비(종류별로 묶여서) + 납품 세트.
  Future<Store> get(String id) async =>
      Store.fromJson(asMap(await _api.get('/stores/$id')));

  Future<Store> create({
    required String name,
    String? brandId,
    DateTime? openDate,
    String? gripperType,
    String? note,
  }) async {
    final res = await _api.post('/stores', body: {
      'name': name,
      if (openDate != null) 'open_date': ServiceRepository.dateOnly(openDate),
      if (brandId != null) 'brand_id': brandId,
      if (gripperType != null) 'gripper_type': gripperType,
      if (note?.isNotEmpty == true) 'note': note,
    });
    return Store.fromJson(asMap(res));
  }

  Future<Store> update(String id, Map<String, dynamic> changes) async =>
      Store.fromJson(asMap(await _api.patch('/stores/$id', body: changes)));

  Future<void> delete(String id) => _api.delete('/stores/$id');

  Future<StoreCloseResult> close(String id, {DateTime? closedDate,
    String? recoverToStatusItemId, String? note}) async =>
      StoreCloseResult.fromJson(asMap(await _api.post('/stores/$id/close', body: {
        'closed_date': ServiceRepository.dateOnly(closedDate),
        'recover_to_status_item_id': recoverToStatusItemId, 'note': note,
      })));

  Future<Store> addSet(String id, {String? name}) async =>
      Store.fromJson(asMap(await _api.post('/stores/$id/sets', body: {'name': name})));

  Future<Store> renameSet(String id, int setNo, String name) async =>
      Store.fromJson(asMap(await _api.patch('/stores/$id/sets/$setNo', body: {'name': name})));

  Future<Store> deleteSet(String id, int setNo) async =>
      Store.fromJson(asMap(await _api.delete('/stores/$id/sets/$setNo')));

  Future<EquipmentSetupResult> setupEquipment(String id, {DateTime? installDate,
    required List<Map<String, dynamic>> sets}) async =>
      EquipmentSetupResult.fromJson(asMap(await _api.post('/stores/$id/equipment', body: {
        'install_date': ServiceRepository.dateOnly(installDate), 'sets': sets,
      })));

  /// 선택 목록도 서버의 페이지 제한을 따라 끝까지 읽는다.
  Future<List<Store>> all({bool includeClosed = false}) async {
    final result = <Store>[];
    var page = 1;
    while (true) {
      final data = await list(page: page++, size: 200, includeClosed: includeClosed);
      result.addAll(data.items);
      if (!data.hasMore) return result;
    }
  }
}
