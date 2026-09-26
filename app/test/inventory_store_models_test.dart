import 'package:ddeck_app/models/calendar.dart';
import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/models/inventory.dart';
import 'package:ddeck_app/models/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final kind = {'id': 'arm', 'code': 'ARM', 'name': '로봇팔'};
  final status = {
    'id': 'installed',
    'code': 'INSTALLED',
    'name': '설치',
    'extra': {'rule': 'store', 'enum': 'IN_USE'},
  };
  final asset = <String, dynamic>{
    'id': 'asset',
    'asset_no': 'AST-0001',
    'name': '로봇팔 RB5',
    'serial_no': 'SN-1',
    'category_id': 'arm',
    'category': kind,
    'quantity': '1.00',
    'status': 'IN_USE',
    'status_item': status,
    'purchase_date': '2026-09-25',
    'set_no': 2,
    'store_id': 'store',
    'store': {'id': 'store', 'name': '강남점'},
  };
  final brief = <String, dynamic>{
    'id': 'asset',
    'asset_no': 'AST-0001',
    'name': '로봇팔 RB5',
    'category_id': 'arm',
    'category_name': '로봇팔',
    'serial_no': 'SN-1',
    'status_name': 'AS 대기',
    'store_id': 'store',
    'store_name': '강남점',
    'location_name': null,
    'note': '확인 필요',
  };

  test('코드의 부모·활성 여부·이동 규칙을 보존한다', () {
    final item = CodeItem.fromJson({
      ...status,
      'parent_id': 'parent',
      'is_active': false,
    });
    expect(item.extra['rule'], 'store');
    expect(item.extra['enum'], 'IN_USE');
    expect(item.parentId, 'parent');
    expect(item.isActive, false);
    expect(CodeItem.fromJson({'extra': null}).extra, isEmpty);
    for (final rule in ['store', 'as', 'clear', 'free']) {
      expect(
        CodeItem.fromJson({
          'extra': {'rule': rule, 'place': '창고'},
        }).extra['rule'],
        rule,
      );
    }
  });

  test('현황은 종류·상태 순서와 희소 셀·숫자 문자열을 읽는다', () {
    final overview = InventoryOverview.fromJson({
      'total': '3',
      'kinds': [kind],
      'statuses': [status],
      'by_status': [
        {
          'key': 'installed',
          'label': '설치',
          'color': '#123456',
          'counts': {'arm': '2', '-': 1},
          'total': 3,
        },
      ],
      'by_brand': [
        {
          'key': 'brand',
          'label': '브랜드',
          'counts': {'arm': 2},
          'total': 2,
        },
      ],
      'by_place': [
        {
          'key': '-',
          'label': '장소 없음',
          'counts': {'-': 1},
          'total': 1,
        },
      ],
      'attention': [brief],
      'rentals': [
        {
          ...brief,
          'ticket_id': 'ticket',
          'ticket_no': 'AS-1',
          'rented_at': '2026-09-01T00:00:00Z',
          'due_date': '2026-09-20',
          'dday': -5,
        },
      ],
    });
    expect(overview.total, 3);
    expect(overview.kinds.single.id, 'arm');
    expect(overview.statuses.single.name, '설치');
    expect(overview.byStatus.single.counts, {'arm': 2, '-': 1});
    expect(overview.byStatus.single.color, '#123456');
    expect(overview.byBrand.single.total, 2);
    expect(overview.byPlace.single.key, '-');
    expect(overview.attention.single.categoryName, '로봇팔');
    expect(overview.attention.single.storeName, '강남점');
    expect(overview.attention.single.locationName, isNull);
    expect(overview.attention.single.note, '확인 필요');
    final rental = overview.rentals.single;
    expect(rental, isA<AttentionAsset>());
    expect(rental.id, 'asset');
    expect(rental.serialNo, 'SN-1');
    expect(rental.ticketId, 'ticket');
    expect(rental.ticketNo, 'AS-1');
    expect(rental.dday, -5);
    expect(rental.dueDate, DateTime(2026, 9, 20));
    expect(rental.rentedAt?.toUtc(), DateTime.utc(2026, 9, 1));
  });

  test('빈 현황과 연결 기록이 없는 렌탈도 파싱된다', () {
    final overview = InventoryOverview.fromJson({});
    expect(overview.total, 0);
    expect(overview.kinds, isEmpty);
    expect(overview.statuses, isEmpty);
    expect(overview.byStatus, isEmpty);
    expect(overview.byBrand, isEmpty);
    expect(overview.byPlace, isEmpty);
    expect(overview.attention, isEmpty);
    expect(overview.rentals, isEmpty);
    final rental = RentalAsset.fromJson(brief);
    expect(rental.ticketId, isNull);
    expect(rental.dday, isNull);
    expect(rental.dueDate, isNull);
    expect(RentalAsset.fromJson({...brief, 'dday': 0}).dday, 0);
    expect(RentalAsset.fromJson({...brief, 'dday': '7'}).dday, 7);
  });

  test('설치일과 매장·세트·세부 상태를 자산에서 읽는다', () {
    final value = Asset.fromJson(asset);
    expect(value.purchaseDate, DateTime(2026, 9, 25));
    expect(value.quantity, 1);
    expect(value.setNo, 2);
    expect(value.storeId, 'store');
    expect(value.placeLabel, '강남점');
    expect(value.statusLabel, '설치');
    expect(value.statusItemId, 'installed');
    final listRow = Asset.fromJson({
      'id': 'a',
      'status_item_id': 'as',
      'location_id': 'warehouse',
    });
    expect(listRow.statusItemId, 'as');
    expect(listRow.locationId, 'warehouse');
    expect(listRow.statusItem, isNull);
  });

  test('일괄 결과의 목록을 숫자로 오해하지 않고 부분 실패를 보존한다', () {
    final created = BulkCreateResult.fromJson({
      'created': [asset],
      'duplicates': ['SN-2', 'SN-3'],
    });
    expect(created.created.single.id, 'asset');
    expect(created.duplicates, ['SN-2', 'SN-3']);
    final moved = BulkMoveResult.fromJson({
      'moved': ['로봇팔 SN-1'],
      'skipped': ['로봇팔 SN-2'],
      'errors': ['매장을 선택해 주세요.'],
    });
    expect(moved.moved, ['로봇팔 SN-1']);
    expect(moved.skipped, ['로봇팔 SN-2']);
    expect(moved.errors, ['매장을 선택해 주세요.']);
    expect(BulkMoveResult.fromJson({}).errors, isEmpty);
    expect(BulkCreateResult.fromJson({}).created, isEmpty);
  });

  test('이력의 직전·직후 상태 및 매장 ID와 사유를 보존한다', () {
    final movement = AssetMovement.fromJson({
      'id': 'move',
      'movement_type': 'MOVE',
      'moved_at': '2026-09-25T00:00:00Z',
      'from_store_id': 'old',
      'to_store_id': 'new',
      'from_status_item_id': 'installed',
      'to_status_item_id': 'as',
      'from_status': 'IN_USE',
      'to_status': 'REPAIR',
      'reason': '점검 반출',
    });
    expect(movement.fromStoreId, 'old');
    expect(movement.toStoreId, 'new');
    expect(movement.fromStatusItemId, 'installed');
    expect(movement.toStatusItemId, 'as');
    expect(movement.toStatus, AssetStatus.repair);
    expect(movement.reason, '점검 반출');
  });

  test('매장 상세의 원인 수·렌탈·기록·회수 기본 순서를 읽는다', () {
    final store = Store.fromJson({
      'id': 'store',
      'name': '강남점',
      'is_closed': false,
      'open_ticket_count': '2',
      'install_date': '2026-09-01',
      'movable_count': 3,
      'rental_count': 1,
      'sets': [
        {'id': 'set', 'set_no': 2, 'name': '좌측'},
      ],
      'asset_groups': [
        {
          'category_id': 'arm',
          'category_name': '로봇팔',
          'count': 1,
          'assets': [asset],
        },
      ],
      'category_counts': [
        {
          'category_id': 'arm',
          'label': '로봇팔',
          'color': '#123456',
          'count': '4',
        },
      ],
      'unreturned_rentals': [
        {
          'ticket_id': 'rental',
          'ticket_no': 'AS-1',
          'rental_type': '로봇팔',
          'serials': 'SN-1',
          'due_date': '2026-09-25',
          'dday': 0,
        },
      ],
      'recent_tickets': [
        {
          'id': 'ticket',
          'ticket_no': 'AS-2',
          'title': '점검',
          'status': 'RECEIVED',
          'received_at': '2026-09-25T00:00:00Z',
          'completed_at': null,
          'cause_labels': ['로봇팔 > 정지', '제어박스'],
        },
      ],
      'recover_options': [
        {'id': 'brand-recover', 'code': 'RECOVER', 'name': '브랜드 회수'},
        status,
      ],
    });
    expect(store.openTicketCount, 2);
    expect(store.installDate, DateTime(2026, 9, 1));
    expect(store.movableCount, 3);
    expect(store.rentalCount, 1);
    expect(store.sets.single.label, '좌측');
    expect(store.assetGroups.single.assets.single.setNo, 2);
    expect(store.categoryCounts.single.count, 4);
    expect(store.categoryCounts.single.color, '#123456');
    expect(store.unreturnedRentals.single.dday, 0);
    expect(store.unreturnedRentals.single.serials, 'SN-1');
    expect(store.recentTickets.single.causeLabels, ['로봇팔 > 정지', '제어박스']);
    expect(store.recentTickets.single.completedAt, isNull);
    expect(store.recoverOptions.map((s) => s.id), [
      'brand-recover',
      'installed',
    ]);
  });

  test('목록 수준의 매장 응답과 폐점·장비 설정 결과를 읽는다', () {
    final json = {'id': 'store', 'name': '강남점', 'is_closed': true};
    final store = Store.fromJson(json);
    expect(store.openTicketCount, 0);
    expect(store.installDate, isNull);
    expect(store.categoryCounts, isEmpty);
    expect(store.unreturnedRentals, isEmpty);
    expect(store.recentTickets, isEmpty);
    expect(store.recoverOptions, isEmpty);
    expect(store.movableCount, 0);
    expect(store.rentalCount, 0);
    final closed = StoreCloseResult.fromJson({
      'store': json,
      'moved': ['SN-1'],
      'notices': ['렌탈은 기록에서 회수'],
    });
    expect(closed.store.isClosed, true);
    expect(closed.moved, ['SN-1']);
    expect(closed.notices, ['렌탈은 기록에서 회수']);
    expect(StoreCloseResult.fromJson({'store': json}).notices, isEmpty);
    final equipment = EquipmentSetupResult.fromJson({
      'store': json,
      'added': ['NG-0001'],
      'moved': ['SN-1'],
      'kept': ['SN-2'],
    });
    expect(equipment.added, ['NG-0001']);
    expect(equipment.moved, ['SN-1']);
    expect(equipment.kept, ['SN-2']);
    expect(equipment.store.id, 'store');
    expect(
      StoreRentalRow.fromJson({'ticket_id': 't', 'ticket_no': 'AS-1'}).dday,
      isNull,
    );
  });
  test('공휴일은 시각 변환 없이 날짜와 대체공휴일 이름을 보존한다', () {
    final holiday = Holiday.fromJson({
      'date': '2026-05-25',
      'name': '부처님오신날 대체공휴일',
    });
    expect(holiday.date, DateTime(2026, 5, 25));
    expect(holiday.date.isUtc, false);
    expect(holiday.name, '부처님오신날 대체공휴일');
    expect(
      Holiday.fromJson({'date': '2027-01-01', 'name': '신정'}).date.year,
      2027,
    );
  });

  test('교차표는 원인 합계와 중복 제거 대응 수 및 희소 셀을 구분한다', () {
    final table = Crosstab.fromJson({
      'rows_axis': 'store',
      'cols_axis': 'year',
      'cols': [
        {'key': '2025', 'label': '2025'},
        {'key': '2026', 'label': '2026', 'color': '#123456'},
      ],
      'rows': [
        {
          'key': 'store',
          'label': '강남점',
          'cells': {'2026': '5'},
          'total': '5',
          'ticket_count': '2',
          'ratio': '0.8333',
        },
        {
          'key': '-',
          'label': '매장 미상',
          'cells': {'2025': 1},
          'total': 1,
          'ticket_count': 1,
          'ratio': 0.1667,
        },
      ],
      'col_totals': {'2025': 1, '2026': '5'},
      'total_causes': '6',
      'total_tickets': 3,
    });
    expect(table.rowsAxis, 'store');
    expect(table.colsAxis, 'year');
    expect(table.cols.map((c) => c.key), ['2025', '2026']);
    expect(table.cols.last.color, '#123456');
    expect(table.rows.first.cells['2025'] ?? 0, 0);
    expect(table.rows.first.cells['2026'], 5);
    expect(table.rows.first.total, 5);
    expect(table.rows.first.ticketCount, 2);
    expect(table.rows.first.ratio, closeTo(0.8333, 0.00001));
    expect(table.rows.last.key, '-');
    expect(table.colTotals, {'2025': 1, '2026': 5});
    expect(table.totalCauses, 6);
    expect(table.totalTickets, 3);
    expect(Crosstab.fromJson({}).rows, isEmpty);
    expect(Crosstab.fromJson({}).cols, isEmpty);
    expect(Crosstab.fromJson({}).totalCauses, 0);
    expect(CrosstabRow.fromJson({'cells': null}).cells, isEmpty);
  });

  test('운영 매장의 연도·브랜드 순서, 폐점, 미상, 매장당 건수를 읽는다', () {
    final years = StoreYears.fromJson({
      'years': ['2025', '2026'],
      'total_stores': '3',
      'closed_stores': 1,
      'unknown_open': ['개점일 미상점'],
      'rows': [
        {
          'year': '2025',
          'operating': '2',
          'opened': 1,
          'closed': '1',
          'year_end': 1,
          'active': '1',
          'tickets': 3,
          'per_store': '1.5',
        },
        {'year': '2026', 'operating': 0, 'per_store': null},
      ],
      'by_brand': [
        {
          'brand': '브랜드 A',
          'counts': {'2025': '2', '2026': 0},
        },
        {
          'brand': '전체',
          'counts': {'2025': 2, '2026': 0},
        },
      ],
    });
    expect(years.years, ['2025', '2026']);
    expect(years.totalStores, 3);
    expect(years.closedStores, 1);
    expect(years.unknownOpen, ['개점일 미상점']);
    final row = years.rows.first;
    expect(row.year, '2025');
    expect(row.operating, 2);
    expect(row.opened, 1);
    expect(row.closed, 1);
    expect(row.yearEnd, 1);
    expect(row.active, 1);
    expect(row.tickets, 3);
    expect(row.perStore, 1.5);
    expect(years.rows.last.perStore, isNull);
    expect(years.byBrand.first.counts['2025'], 2);
    expect(years.byBrand.last.brand, '전체');
    expect(StoreYears.fromJson({}).years, isEmpty);
    expect(StoreYears.fromJson({}).unknownOpen, isEmpty);
    expect(StoreYears.fromJson({}).byBrand, isEmpty);
  });

  test('위치 트리의 부모·종류·자산 수와 하위 노드를 보존한다', () {
    final root = StorageLocation.fromJson({
      'id': 'root',
      'code': 'HQ',
      'name': '본사',
      'type': 'SITE',
      'asset_count': '2',
      'children': [
        {
          'id': 'child',
          'code': 'WH',
          'name': '창고',
          'type': 'ROOM',
          'parent_id': 'root',
          'path': '본사 > 창고',
          'asset_count': 3,
          'children': [],
        },
      ],
    });
    expect(root.type, LocationType.site);
    expect(root.assetCount, 2);
    expect(root.children.single.parentId, 'root');
    expect(root.children.single.type, LocationType.room);
    expect(root.children.single.display, '본사 > 창고');
    expect(root.children.single.assetCount, 3);
    expect(StorageLocation.fromJson({}).children, isEmpty);
    expect(StorageLocation.fromJson({}).assetCount, 0);
  });
}
