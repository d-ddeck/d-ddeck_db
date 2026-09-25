import 'package:flutter/material.dart';

import 'common.dart';

enum AssetStatus {
  inStock('IN_STOCK', '재고', Color(0xFF10B981)),
  inUse('IN_USE', '사용중', Color(0xFF3B82F6)),
  repair('REPAIR', '수리중', Color(0xFFF59E0B)),
  loaned('LOANED', '대여중', Color(0xFF8B5CF6)),
  disposed('DISPOSED', '폐기', Color(0xFF94A3B8)),
  lost('LOST', '분실', Color(0xFFEF4444));

  const AssetStatus(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  static AssetStatus parse(String? v) => AssetStatus.values
      .firstWhere((s) => s.value == v, orElse: () => AssetStatus.inStock);
}

enum LocationType {
  site('SITE', '사업장', Icons.business),
  building('BUILDING', '건물', Icons.apartment),
  floor('FLOOR', '층', Icons.layers),
  room('ROOM', '실', Icons.meeting_room),
  rack('RACK', '랙/선반', Icons.shelves),
  vehicle('VEHICLE', '차량', Icons.local_shipping),
  etc('ETC', '기타', Icons.place);

  const LocationType(this.value, this.label, this.icon);
  final String value;
  final String label;
  final IconData icon;

  static LocationType parse(String? v) => LocationType.values
      .firstWhere((t) => t.value == v, orElse: () => LocationType.etc);
}

/// Movement kinds. The server derives the resulting status from these, so the
/// UI only has to pick the right verb.
enum MovementType {
  inbound('INBOUND', '입고', Icons.login),
  move('MOVE', '위치 이동', Icons.swap_horiz),
  assign('ASSIGN', '사용자 불출', Icons.person_add),
  returned('RETURN', '반납', Icons.assignment_return),
  repair('REPAIR', '수리 반출', Icons.build),
  dispose('DISPOSE', '폐기', Icons.delete_outline),
  stocktake('STOCKTAKE', '실사 조정', Icons.fact_check);

  const MovementType(this.value, this.label, this.icon);
  final String value;
  final String label;
  final IconData icon;

  static MovementType parse(String? v) => MovementType.values
      .firstWhere((t) => t.value == v, orElse: () => MovementType.move);

  /// Whether this move needs a destination location picked in the UI.
  bool get needsLocation => this == move || this == inbound;

  /// Whether this move needs a person picked in the UI.
  bool get needsHolder => this == assign;
}

class StorageLocation {
  const StorageLocation({
    required this.id,
    required this.code,
    required this.name,
    required this.type,
    this.parentId,
    this.path,
    this.isActive = true,
    this.assetCount = 0,
    this.children = const [],
  });

  final String id;
  final String code;
  final String name;
  final LocationType type;
  final String? parentId;
  final String? path;
  final bool isActive;
  final int assetCount;
  final List<StorageLocation> children;

  /// Full path when the server cached one, otherwise just the name.
  String get display => path ?? name;

  /// Deepest segment, for compact list rows.
  String get shortLabel =>
      path == null ? name : path!.split(' > ').last;

  factory StorageLocation.fromJson(Map<String, dynamic> j) => StorageLocation(
        id: asString(j['id']),
        code: asString(j['code']),
        name: asString(j['name']),
        type: LocationType.parse(j['type'] as String?),
        parentId: j['parent_id'] as String?,
        path: j['path'] as String?,
        isActive: asBool(j['is_active'], true),
        assetCount: asInt(j['asset_count']),
        children: asList(j['children'], StorageLocation.fromJson),
      );

  /// Flattens a tree into indented rows for a dropdown.
  static List<(StorageLocation, int)> flatten(
    List<StorageLocation> roots, [
    int depth = 0,
  ]) {
    final out = <(StorageLocation, int)>[];
    for (final node in roots) {
      out.add((node, depth));
      out.addAll(flatten(node.children, depth + 1));
    }
    return out;
  }
}

class Asset {
  const Asset({
    required this.id,
    required this.assetNo,
    required this.name,
    required this.status,
    required this.quantity,
    required this.unit,
    this.categoryId,
    this.category,
    this.modelName,
    this.manufacturer,
    this.serialNo,
    this.barcode,
    this.spec,
    this.locationId,
    this.location,
    this.holderId,
    this.holder,
    this.minQuantity,
    this.purchaseDate,
    this.purchasePrice,
    this.supplier,
    this.warrantyUntil,
    this.note,
    this.isBelowMin = false,
    this.storeId,
    this.storeName,
    this.setNo = 0,
    this.statusItemId,
    this.statusItem,
  });

  final String id;
  final String assetNo;
  final String name;
  final AssetStatus status;
  final double quantity;
  final String unit;
  final String? categoryId;
  final CodeItem? category;
  final String? modelName;
  final String? manufacturer;
  final String? serialNo;
  final String? barcode;
  final String? spec;
  final String? locationId;
  final StorageLocation? location;
  final String? holderId;
  final UserBrief? holder;
  final double? minQuantity;
  final DateTime? purchaseDate;
  final double? purchasePrice;
  final String? supplier;
  final DateTime? warrantyUntil;
  final String? note;
  final bool isBelowMin;

  /// 매장에 나가 있는 장비. location 과 둘 중 하나만 찬다 - 구 서버도 창고와
  /// 매장을 별개 칸으로 나눠 두었고, 그 구분이 재고 화면의 기본 축이다.
  final String? storeId;
  final String? storeName;

  /// 매장 납품 세트 번호. 0 이면 세트 미지정.
  final int setNo;

  /// 구 서버의 13종 상태(설치 / 렌탈 중 / AS 대기 / 바른 회수 …).
  /// AssetStatus 6종으로는 못 담는 구분이라 코드 항목으로 따로 남겼다.
  final String? statusItemId;
  final CodeItem? statusItem;

  /// 화면에 뿌릴 상태 이름. 세부 상태가 있으면 그쪽이 정확하다.
  String get statusLabel => statusItem?.name ?? status.label;

  /// 지금 어디에 있는지 한 줄로.
  String get placeLabel =>
      storeName ?? location?.shortLabel ?? '위치 미지정';

  bool get warrantyExpired =>
      warrantyUntil != null && warrantyUntil!.isBefore(DateTime.now());

  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
        id: asString(j['id']),
        assetNo: asString(j['asset_no']),
        name: asString(j['name']),
        status: AssetStatus.parse(j['status'] as String?),
        quantity: asDouble(j['quantity']) ?? 0,
        unit: asString(j['unit'], 'EA'),
        categoryId: j['category_id'] as String?,
        category:
            j['category'] is Map ? CodeItem.fromJson(asMap(j['category'])) : null,
        modelName: j['model_name'] as String?,
        manufacturer: j['manufacturer'] as String?,
        serialNo: j['serial_no'] as String?,
        barcode: j['barcode'] as String?,
        spec: j['spec'] as String?,
        locationId: j['location_id'] as String?,
        location: j['location'] is Map
            ? StorageLocation.fromJson(asMap(j['location']))
            : null,
        holderId: j['holder_id'] as String?,
        holder:
            j['holder'] is Map ? UserBrief.fromJson(asMap(j['holder'])) : null,
        storeId: j['store_id'] as String?,
        storeName: j['store'] is Map ? asString(asMap(j['store'])['name']) : null,
        setNo: asInt(j['set_no']),
        statusItemId: j['status_item_id'] as String? ?? (j['status_item'] is Map ? asString(asMap(j['status_item'])['id']) : null),
        statusItem: j['status_item'] is Map
            ? CodeItem.fromJson(asMap(j['status_item']))
            : null,
        minQuantity: asDouble(j['min_quantity']),
        purchaseDate: asDate(j['purchase_date']),
        purchasePrice: asDouble(j['purchase_price']),
        supplier: j['supplier'] as String?,
        warrantyUntil: asDate(j['warranty_until']),
        note: j['note'] as String?,
        isBelowMin: asBool(j['is_below_min']),
      );
}

class AssetMovement {
  const AssetMovement({
    required this.id,
    required this.movementType,
    required this.movedAt,
    this.fromLocationId,
    this.toLocationId,
    this.fromStatus,
    this.toStatus,
    this.quantity,
    this.fromStoreId,
    this.toStoreId,
    this.fromStatusItemId,
    this.toStatusItemId,
    this.reason,
  });

  final String id;
  final MovementType movementType;
  final DateTime movedAt;
  final String? fromLocationId;
  final String? toLocationId;
  final AssetStatus? fromStatus;
  final AssetStatus? toStatus;
  final double? quantity;
  final String? fromStoreId;
  final String? toStoreId;
  final String? fromStatusItemId;
  final String? toStatusItemId;
  final String? reason;

  factory AssetMovement.fromJson(Map<String, dynamic> j) => AssetMovement(
        id: asString(j['id']),
        movementType: MovementType.parse(j['movement_type'] as String?),
        movedAt: asDate(j['moved_at']) ?? DateTime.now(),
        fromLocationId: j['from_location_id'] as String?,
        toLocationId: j['to_location_id'] as String?,
        fromStatus: j['from_status'] == null
            ? null
            : AssetStatus.parse(j['from_status'] as String?),
        toStatus: j['to_status'] == null
            ? null
            : AssetStatus.parse(j['to_status'] as String?),
        quantity: asDouble(j['quantity']),
        fromStoreId: j['from_store_id'] as String?,
        toStoreId: j['to_store_id'] as String?,
        fromStatusItemId: j['from_status_item_id'] as String?,
        toStatusItemId: j['to_status_item_id'] as String?,
        reason: j['reason'] as String?,
      );
}

class CountBucket {
  const CountBucket({
    required this.key,
    required this.label,
    required this.count,
    this.quantity,
  });

  final String key;
  final String label;
  final int count;
  final double? quantity;

  factory CountBucket.fromJson(Map<String, dynamic> j) => CountBucket(
        key: asString(j['key']),
        label: asString(j['label']),
        count: asInt(j['count']),
        quantity: asDouble(j['quantity']),
      );
}

class InventorySummary {
  const InventorySummary({
    required this.totalAssets,
    required this.totalQuantity,
    required this.byStatus,
    required this.byCategory,
    required this.byLocation,
    required this.belowMinCount,
    required this.warrantyExpiringCount,
    this.totalValue,
  });

  final int totalAssets;
  final double totalQuantity;
  final List<CountBucket> byStatus;
  final List<CountBucket> byCategory;
  final List<CountBucket> byLocation;
  final int belowMinCount;
  final int warrantyExpiringCount;
  final double? totalValue;

  factory InventorySummary.fromJson(Map<String, dynamic> j) => InventorySummary(
        totalAssets: asInt(j['total_assets']),
        totalQuantity: asDouble(j['total_quantity']) ?? 0,
        totalValue: asDouble(j['total_value']),
        belowMinCount: asInt(j['below_min_count']),
        warrantyExpiringCount: asInt(j['warranty_expiring_count']),
        byStatus: asList(j['by_status'], CountBucket.fromJson),
        byCategory: asList(j['by_category'], CountBucket.fromJson),
        byLocation: asList(j['by_location'], CountBucket.fromJson),
      );

  static InventorySummary empty() => const InventorySummary(
        totalAssets: 0,
        totalQuantity: 0,
        byStatus: [],
        byCategory: [],
        byLocation: [],
        belowMinCount: 0,
        warrantyExpiringCount: 0,
      );
}

class OverviewRow {
  const OverviewRow({
    required this.key,
    required this.label,
    required this.color,
    required this.counts,
    required this.total,
  });
  final String key;
  final String label;
  final String? color;
  final Map<String, int> counts;
  final int total;
  factory OverviewRow.fromJson(Map<String, dynamic> j) => OverviewRow(
        key: asString(j['key']),
        label: asString(j['label']),
        color: j['color'] as String?,
        counts: asMap(j['counts']).map((k, v) => MapEntry(k, asInt(v))),
        total: asInt(j['total']),
      );
}

class AttentionAsset {
  const AttentionAsset({
    required this.id,
    required this.assetNo,
    required this.name,
    required this.categoryId,
    required this.categoryName,
    required this.serialNo,
    required this.statusName,
    required this.storeId,
    required this.storeName,
    required this.locationName,
    required this.note,
  });
  final String id;
  final String assetNo;
  final String name;
  final String? categoryId;
  final String? categoryName;
  final String? serialNo;
  final String? statusName;
  final String? storeId;
  final String? storeName;
  final String? locationName;
  final String? note;
  AttentionAsset.fromJson(Map<String, dynamic> j) :
        id = asString(j['id']),
        assetNo = asString(j['asset_no']),
        name = asString(j['name']),
        categoryId = j['category_id'] as String?,
        categoryName = j['category_name'] as String?,
        serialNo = j['serial_no'] as String?,
        statusName = j['status_name'] as String?,
        storeId = j['store_id'] as String?,
        storeName = j['store_name'] as String?,
        locationName = j['location_name'] as String?,
        note = j['note'] as String?;
}

class InventoryOverview {
  const InventoryOverview({
    required this.total,
    required this.kinds,
    required this.statuses,
    required this.byStatus,
    required this.byBrand,
    required this.byPlace,
    required this.attention,
    required this.rentals,
  });
  final int total;
  final List<CodeItem> kinds;
  final List<CodeItem> statuses;
  final List<OverviewRow> byStatus;
  final List<OverviewRow> byBrand;
  final List<OverviewRow> byPlace;
  final List<AttentionAsset> attention;
  final List<RentalAsset> rentals;
  factory InventoryOverview.fromJson(Map<String, dynamic> j) => InventoryOverview(
        total: asInt(j['total']),
        kinds: asList(j['kinds'], CodeItem.fromJson),
        statuses: asList(j['statuses'], CodeItem.fromJson),
        byStatus: asList(j['by_status'], OverviewRow.fromJson),
        byBrand: asList(j['by_brand'], OverviewRow.fromJson),
        byPlace: asList(j['by_place'], OverviewRow.fromJson),
        attention: asList(j['attention'], AttentionAsset.fromJson),
        rentals: asList(j['rentals'], RentalAsset.fromJson),
      );
}

class BulkMoveResult {
  const BulkMoveResult({
    required this.moved,
    required this.skipped,
    required this.errors,
  });
  final List<String> moved;
  final List<String> skipped;
  final List<String> errors;
  factory BulkMoveResult.fromJson(Map<String, dynamic> j) => BulkMoveResult(
        moved: (j['moved'] as List? ?? []).map((e) => e.toString()).toList(),
        skipped: (j['skipped'] as List? ?? []).map((e) => e.toString()).toList(),
        errors: (j['errors'] as List? ?? []).map((e) => e.toString()).toList(),
      );
}

class BulkCreateResult {
  const BulkCreateResult({
    required this.created,
    required this.duplicates,
  });
  final List<Asset> created;
  final List<String> duplicates;
  factory BulkCreateResult.fromJson(Map<String, dynamic> j) => BulkCreateResult(
        created: asList(j['created'], Asset.fromJson),
        duplicates: (j['duplicates'] as List? ?? []).map((e) => e.toString()).toList(),
      );
}

class RentalAsset extends AttentionAsset {
  // The JSON map is also used by the rental-specific initializers.
  // ignore: use_super_parameters
  RentalAsset.fromJson(Map<String, dynamic> j) : ticketId = j['ticket_id'] as String?,
      ticketNo = j['ticket_no'] as String?,
      rentedAt = asDate(j['rented_at']),
      dueDate = asDate(j['due_date']),
      dday = j['dday'] == null ? null : asInt(j['dday']),
      super.fromJson(j);
  final String? ticketId;
  final String? ticketNo;
  final DateTime? rentedAt;
  final DateTime? dueDate;
  final int? dday;
}
