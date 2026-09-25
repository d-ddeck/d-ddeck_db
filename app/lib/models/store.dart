import 'common.dart';
import 'inventory.dart';

/// 브랜드별 현황. 매장 화면의 첫 단계 — 바른치킨 28곳 / 자산 54대.
class BrandSummary {
  const BrandSummary({
    required this.brandName,
    required this.storeCount,
    required this.openStoreCount,
    required this.assetCount,
    this.brandId,
    this.color,
  });

  final String? brandId;
  final String brandName;
  final String? color;
  final int storeCount;
  final int openStoreCount;
  final int assetCount;

  int get closedStoreCount => storeCount - openStoreCount;

  factory BrandSummary.fromJson(Map<String, dynamic> j) => BrandSummary(
        brandId: j['brand_id'] as String?,
        brandName: asString(j['brand_name'], '미지정'),
        color: j['color'] as String?,
        storeCount: asInt(j['store_count']),
        openStoreCount: asInt(j['open_store_count']),
        assetCount: asInt(j['asset_count']),
      );
}

class StoreSet {
  const StoreSet({required this.id, required this.setNo, this.name});

  final String id;
  final int setNo;
  final String? name;

  String get label => name?.isNotEmpty == true ? name! : '세트 $setNo';

  factory StoreSet.fromJson(Map<String, dynamic> j) => StoreSet(
        id: asString(j['id']),
        setNo: asInt(j['set_no']),
        name: j['name'] as String?,
      );
}

/// 매장 한 곳에 나가 있는 우리 장비 한 대.
class AssetInStore {
  const AssetInStore({
    required this.id,
    required this.assetNo,
    required this.name,
    required this.status,
    this.category,
    this.modelName,
    this.serialNo,
    this.statusItem,
    this.setNo = 0,
  });

  final String id;
  final String assetNo;
  final String name;
  final AssetStatus status;
  final CodeItem? category;
  final String? modelName;
  final String? serialNo;

  /// 구 서버의 13종 상태(설치 / 렌탈 중 / AS 대기 …). 있으면 이쪽이 더 정확하다.
  final CodeItem? statusItem;
  final int setNo;

  String get statusLabel => statusItem?.name ?? status.label;

  factory AssetInStore.fromJson(Map<String, dynamic> j) => AssetInStore(
        id: asString(j['id']),
        assetNo: asString(j['asset_no']),
        name: asString(j['name']),
        status: AssetStatus.parse(j['status'] as String?),
        category:
            j['category'] is Map ? CodeItem.fromJson(asMap(j['category'])) : null,
        modelName: j['model_name'] as String?,
        serialNo: j['serial_no'] as String?,
        statusItem: j['status_item'] is Map
            ? CodeItem.fromJson(asMap(j['status_item']))
            : null,
        setNo: asInt(j['set_no']),
      );
}

/// 보유 장비를 종류별로 묶은 것. 매장 화면이 종류 단위로 읽힌다.
class StoreAssetGroup {
  const StoreAssetGroup({
    required this.categoryName,
    required this.count,
    required this.assets,
    this.categoryId,
    this.color,
  });

  final String? categoryId;
  final String categoryName;
  final String? color;
  final int count;
  final List<AssetInStore> assets;

  factory StoreAssetGroup.fromJson(Map<String, dynamic> j) => StoreAssetGroup(
        categoryId: j['category_id'] as String?,
        categoryName: asString(j['category_name'], '미분류'),
        color: j['color'] as String?,
        count: asInt(j['count']),
        assets: asList(j['assets'], AssetInStore.fromJson),
      );
}

class Store {
  const Store({
    required this.id,
    required this.name,
    required this.isClosed,
    this.brandId,
    this.brand,
    this.openDate,
    this.closedDate,
    this.gripperType,
    this.note,
    this.assetCount = 0,
    this.ticketCount = 0,
    this.sets = const [],
    this.openTicketCount = 0,
    this.installDate,
    this.categoryCounts = const [],
    this.unreturnedRentals = const [],
    this.recentTickets = const [],
    this.recoverOptions = const [],
    this.movableCount = 0,
    this.rentalCount = 0,
    this.assetGroups = const [],
  });

  final String id;
  final String name;
  final bool isClosed;
  final String? brandId;
  final CodeItem? brand;
  final DateTime? openDate;
  final DateTime? closedDate;
  final String? gripperType;
  final String? note;
  final int assetCount;
  final int ticketCount;

  /// 상세 조회에서만 채워진다.
  final List<StoreSet> sets;
  final int openTicketCount;
  final DateTime? installDate;
  final List<CategoryCount> categoryCounts;
  final List<StoreRentalRow> unreturnedRentals;
  final List<StoreTicketBrief> recentTickets;
  final List<CodeItem> recoverOptions;
  final int movableCount;
  final int rentalCount;
  final List<StoreAssetGroup> assetGroups;

  String get brandName => brand?.name ?? '미지정';

  factory Store.fromJson(Map<String, dynamic> j) => Store(
        id: asString(j['id']),
        name: asString(j['name']),
        isClosed: asBool(j['is_closed'], false),
        brandId: j['brand_id'] as String?,
        brand: j['brand'] is Map ? CodeItem.fromJson(asMap(j['brand'])) : null,
        openDate: asDate(j['open_date']),
        closedDate: asDate(j['closed_date']),
        gripperType: j['gripper_type'] as String?,
        note: j['note'] as String?,
        assetCount: asInt(j['asset_count']),
        ticketCount: asInt(j['ticket_count']),
        sets: asList(j['sets'], StoreSet.fromJson),
        openTicketCount: asInt(j['open_ticket_count']),
        installDate: asDate(j['install_date']),
        categoryCounts: asList(j['category_counts'], CategoryCount.fromJson),
        unreturnedRentals: asList(j['unreturned_rentals'], StoreRentalRow.fromJson),
        recentTickets: asList(j['recent_tickets'], StoreTicketBrief.fromJson),
        recoverOptions: asList(j['recover_options'], CodeItem.fromJson),
        movableCount: asInt(j['movable_count']),
        rentalCount: asInt(j['rental_count']),
        assetGroups: asList(j['asset_groups'], StoreAssetGroup.fromJson),
      );
}

class CategoryCount {
  const CategoryCount({
    required this.categoryId,
    required this.label,
    required this.color,
    required this.count,
  });
  final String? categoryId;
  final String label;
  final String? color;
  final int count;
  factory CategoryCount.fromJson(Map<String, dynamic> j) => CategoryCount(
        categoryId: j['category_id'] as String?,
        label: asString(j['label']),
        color: j['color'] as String?,
        count: asInt(j['count']),
      );
}

class StoreRentalRow {
  const StoreRentalRow({
    required this.ticketId,
    required this.ticketNo,
    required this.rentalType,
    required this.serials,
    required this.dueDate,
    required this.dday,
  });
  final String ticketId;
  final String ticketNo;
  final String? rentalType;
  final String? serials;
  final DateTime? dueDate;
  final int? dday;
  factory StoreRentalRow.fromJson(Map<String, dynamic> j) => StoreRentalRow(
        ticketId: asString(j['ticket_id']),
        ticketNo: asString(j['ticket_no']),
        rentalType: j['rental_type'] as String?,
        serials: j['serials'] as String?,
        dueDate: asDate(j['due_date']),
        dday: j['dday'] == null ? null : asInt(j['dday']),
      );
}

class StoreTicketBrief {
  const StoreTicketBrief({
    required this.id,
    required this.ticketNo,
    required this.title,
    required this.status,
    required this.receivedAt,
    required this.completedAt,
    required this.causeLabels,
  });
  final String id;
  final String ticketNo;
  final String title;
  final String status;
  final DateTime? receivedAt;
  final DateTime? completedAt;
  final List<String> causeLabels;
  factory StoreTicketBrief.fromJson(Map<String, dynamic> j) => StoreTicketBrief(
        id: asString(j['id']),
        ticketNo: asString(j['ticket_no']),
        title: asString(j['title']),
        status: asString(j['status']),
        receivedAt: asDate(j['received_at']),
        completedAt: asDate(j['completed_at']),
        causeLabels: (j['cause_labels'] as List? ?? []).map((e) => e.toString()).toList(),
      );
}

class StoreCloseResult {
  const StoreCloseResult({
    required this.store,
    required this.moved,
    required this.notices,
  });
  final Store store;
  final List<String> moved;
  final List<String> notices;
  factory StoreCloseResult.fromJson(Map<String, dynamic> j) => StoreCloseResult(
        store: Store.fromJson(asMap(j['store'])),
        moved: (j['moved'] as List? ?? []).map((e) => e.toString()).toList(),
        notices: (j['notices'] as List? ?? []).map((e) => e.toString()).toList(),
      );
}

class EquipmentSetupResult {
  const EquipmentSetupResult({
    required this.added,
    required this.moved,
    required this.kept,
    required this.store,
  });
  final List<String> added;
  final List<String> moved;
  final List<String> kept;
  final Store store;
  factory EquipmentSetupResult.fromJson(Map<String, dynamic> j) => EquipmentSetupResult(
        added: (j['added'] as List? ?? []).map((e) => e.toString()).toList(),
        moved: (j['moved'] as List? ?? []).map((e) => e.toString()).toList(),
        kept: (j['kept'] as List? ?? []).map((e) => e.toString()).toList(),
        store: Store.fromJson(asMap(j['store'])),
      );
}
