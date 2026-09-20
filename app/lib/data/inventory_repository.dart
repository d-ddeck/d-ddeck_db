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
      // Only send when it changes the default, to keep the URL readable.
      'include_sublocations': includeSublocations ? null : false,
      'below_min_only': belowMinOnly ? true : null,
    });
    return PagedList.fromJson(res, Asset.fromJson);
  }

  Future<Asset> get(String id) async =>
      Asset.fromJson(asMap(await _api.get('/inventory/assets/$id')));

  Future<Asset> create({
    required String name,
    String? categoryId,
    String? locationId,
    String? manufacturer,
    String? modelName,
    String? serialNo,
    double quantity = 1,
    String unit = 'EA',
    double? minQuantity,
    double? purchasePrice,
  }) async {
    final res = await _api.post('/inventory/assets', body: {
      'name': name,
      'category_id': categoryId,
      'location_id': locationId,
      'manufacturer': manufacturer,
      'model_name': modelName,
      'serial_no': serialNo,
      'quantity': quantity,
      'unit': unit,
      'min_quantity': minQuantity,
      'purchase_price': purchasePrice,
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
    AssetStatus? toStatus,
    double? quantity,
    String? reason,
  }) async {
    final res = await _api.post('/inventory/assets/$id/move', body: {
      'movement_type': type.value,
      if (toLocationId != null) 'to_location_id': toLocationId,
      if (toHolderId != null) 'to_holder_id': toHolderId,
      if (toStatus != null) 'to_status': toStatus.value,
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
