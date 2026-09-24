import '../core/api_client.dart';
import '../models/common.dart';
import '../models/inventory.dart';

class InventoryRepository {
  InventoryRepository(this._api);
  final ApiClient _api;

  Future<List<StorageLocation>> tree() async {
    final res = await _api.get('/inventory/locations/tree');
    return (res as List? ?? [])
        .map((e) => StorageLocation.fromJson(asMap(e)))
        .toList();
  }

  Future<List<StorageLocation>> locations() async {
    final res = await _api.get('/inventory/locations');
    return (res as List? ?? [])
        .map((e) => StorageLocation.fromJson(asMap(e)))
        .toList();
  }

  Future<StorageLocation> createLocation({
    required String code,
    required String name,
    required LocationType type,
    String? parentId,
  }) async {
    final res = await _api.post('/inventory/locations', body: {
      'code': code,
      'name': name,
      'type': type.value,
      if (parentId != null) 'parent_id': parentId,
    });
    return StorageLocation.fromJson(asMap(res));
  }

  Future<PagedList<Asset>> list({
    int page = 1,
    int size = 20,
    String? query,
    AssetStatus? status,
    String? categoryId,
    String? locationId,
    String? storeId,
    String? brandId,
    bool includeSublocations = true,
    bool belowMinOnly = false,
  }) async {
    final res = await _api.get('/inventory/assets', query: {
      'page': page,
      'size': size,
      'q': query,
      'status': status?.value,
      'category_id': categoryId,
      'location_id': locationId,
      'store_id': storeId,
      'brand_id': brandId,
      // Only send when it changes the default, to keep the URL readable.
      'include_sublocations': includeSublocations ? null : false,
      'below_min_only': belowMinOnly ? true : null,
    });
    return PagedList.fromJson(res, Asset.fromJson);
  }

  Future<Asset> get(String id) async =>
      Asset.fromJson(asMap(await _api.get('/inventory/assets/$id')));

  /// 자산 한 대 등록.
  ///
  /// 서버는 위치와 매장 중 **하나**를 요구한다. 매장에 설치된 장비는 창고
  /// 위치가 없는 것이 정상이라, 둘 다 비면 거절당한다.
  Future<Asset> create({
    required String name,
    String? categoryId,
    String? locationId,
    String? storeId,
    String? statusItemId,
    int setNo = 0,
    AssetStatus? status,
    String? manufacturer,
    String? modelName,
    String? serialNo,
    double quantity = 1,
    String unit = 'EA',
    double? minQuantity,
    double? purchasePrice,
    String? note,
  }) async {
    final res = await _api.post('/inventory/assets', body: {
      'name': name,
      'category_id': categoryId,
      'location_id': locationId,
      'store_id': storeId,
      'status_item_id': statusItemId,
      'set_no': setNo == 0 ? null : setNo,
      'status': status?.value,
      'manufacturer': manufacturer,
      'model_name': modelName,
      'serial_no': serialNo,
      'quantity': quantity,
      'unit': unit,
      'min_quantity': minQuantity,
      'purchase_price': purchasePrice,
      'note': note,
    }..removeWhere((_, v) => v == null));
    return Asset.fromJson(asMap(res));
  }

  Future<Asset> update(String id, Map<String, dynamic> changes) async {
    final res = await _api.patch('/inventory/assets/$id', body: changes);
    return Asset.fromJson(asMap(res));
  }

  /// The single write path for location, holder and status.
  ///
  /// PATCH deliberately cannot change these - going through /move is what
  /// guarantees the movement history stays complete.
  Future<Asset> move(
    String id, {
    required MovementType type,
    String? toLocationId,
    String? toHolderId,
    String? toStoreId,
    String? toStatusItemId,
    int? toSetNo,
    AssetStatus? toStatus,
    bool clearStore = false,
    double? quantity,
    String? reason,
  }) async {
    final res = await _api.post('/inventory/assets/$id/move', body: {
      'movement_type': type.value,
      if (toLocationId != null) 'to_location_id': toLocationId,
      if (toHolderId != null) 'to_holder_id': toHolderId,
      if (toStoreId != null) 'to_store_id': toStoreId,
      if (toStatusItemId != null) 'to_status_item_id': toStatusItemId,
      if (toSetNo != null) 'to_set_no': toSetNo,
      if (toStatus != null) 'to_status': toStatus.value,
      if (clearStore) 'clear_store': true,
      if (quantity != null) 'quantity': quantity,
      if (reason?.isNotEmpty == true) 'reason': reason,
    });
    return Asset.fromJson(asMap(res));
  }

  Future<PagedList<AssetMovement>> movements(String id,
      {int page = 1, int size = 30}) async {
    final res = await _api.get('/inventory/assets/$id/movements',
        query: {'page': page, 'size': size});
    return PagedList.fromJson(res, AssetMovement.fromJson);
  }

  Future<void> delete(String id) => _api.delete('/inventory/assets/$id');

  Future<InventorySummary> summary() async =>
      InventorySummary.fromJson(asMap(await _api.get('/inventory/summary')));
}
