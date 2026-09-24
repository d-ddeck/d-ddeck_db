import '../core/api_client.dart';
import '../models/common.dart';
import '../models/store.dart';

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
    String? gripperType,
    String? note,
  }) async {
    final res = await _api.post('/stores', body: {
      'name': name,
      if (brandId != null) 'brand_id': brandId,
      if (gripperType != null) 'gripper_type': gripperType,
      if (note?.isNotEmpty == true) 'note': note,
    });
    return Store.fromJson(asMap(res));
  }

  Future<Store> update(String id, Map<String, dynamic> changes) async =>
      Store.fromJson(asMap(await _api.patch('/stores/$id', body: changes)));

  Future<void> delete(String id) => _api.delete('/stores/$id');
}
