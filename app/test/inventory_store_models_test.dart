import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/inventory.dart';
import 'package:ddeck_app/models/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final kind = {'id': 'arm', 'code': 'ARM', 'name': '로봇팔'};
  final status = {'id': 'installed', 'code': 'INSTALLED', 'name': '설치',
    'extra': {'rule': 'store', 'enum': 'IN_USE'}};
  final asset = <String, dynamic>{
    'id': 'asset', 'asset_no': 'AST-0001', 'name': '로봇팔 RB5', 'serial_no': 'SN-1',
    'category_id': 'arm', 'category': kind, 'quantity': '1.00', 'status': 'IN_USE',
    'status_item': status, 'purchase_date': '2026-09-25', 'set_no': 2,
    'store_id': 'store', 'store': {'id': 'store', 'name': '강남점'},
  };
  final brief = <String, dynamic>{
    'id': 'asset', 'asset_no': 'AST-0001', 'name': '로봇팔 RB5',
    'category_id': 'arm', 'category_name': '로봇팔', 'serial_no': 'SN-1',
    'status_name': 'AS 대기', 'store_id': 'store', 'store_name': '강남점',
    'location_name': null, 'note': '확인 필요',
  };

  test('코드의 부모·활성 여부·이동 규칙을 보존한다', () {
    final item = CodeItem.fromJson({...status, 'parent_id': 'parent', 'is_active': false});
    expect(item.extra['rule'], 'store');
    expect(item.extra['enum'], 'IN_USE');
    expect(item.parentId, 'parent');
    expect(item.isActive, false);
    expect(CodeItem.fromJson({'extra': null}).extra, isEmpty);
    for (final rule in ['store', 'as', 'clear', 'free']) {
      expect(CodeItem.fromJson({'extra': {'rule': rule, 'place': '창고'}}).extra['rule'], rule);
    }
  });

  test('현황은 종류·상태 순서와 희소 셀·숫자 문자열을 읽는다', () {
    final overview = InventoryOverview.fromJson({
      'total': '3', 'kinds': [kind], 'statuses': [status],
      'by_status': [{'key': 'installed', 'label': '설치', 'color': '#123456', 'counts': {'arm': '2', '-': 1}, 'total': 3}],
      'by_brand': [{'key': 'brand', 'label': '브랜드', 'counts': {'arm': 2}, 'total': 2}],
      'by_place': [{'key': '-', 'label': '장소 없음', 'counts': {'-': 1}, 'total': 1}],
      'attention': [brief], 'rentals': [{...brief, 'ticket_id': 'ticket', 'ticket_no': 'AS-1',
        'rented_at': '2026-09-01T00:00:00Z', 'due_date': '2026-09-20', 'dday': -5}],
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
    final listRow = Asset.fromJson({'id': 'a', 'status_item_id': 'as', 'location_id': 'warehouse'});
    expect(listRow.statusItemId, 'as');
    expect(listRow.locationId, 'warehouse');
    expect(listRow.statusItem, isNull);
  });

  test('일괄 결과의 목록을 숫자로 오해하지 않고 부분 실패를 보존한다', () {
    final created = BulkCreateResult.fromJson({'created': [asset], 'duplicates': ['SN-2', 'SN-3']});
    expect(created.created.single.id, 'asset');
    expect(created.duplicates, ['SN-2', 'SN-3']);
    final moved = BulkMoveResult.fromJson({'moved': ['로봇팔 SN-1'], 'skipped': ['로봇팔 SN-2'], 'errors': ['매장을 선택해 주세요.']});
    expect(moved.moved, ['로봇팔 SN-1']);
    expect(moved.skipped, ['로봇팔 SN-2']);
    expect(moved.errors, ['매장을 선택해 주세요.']);
    expect(BulkMoveResult.fromJson({}).errors, isEmpty);
    expect(BulkCreateResult.fromJson({}).created, isEmpty);
  });

  test('이력의 직전·직후 상태 및 매장 ID와 사유를 보존한다', () {
    final movement = AssetMovement.fromJson({
      'id': 'move', 'movement_type': 'MOVE', 'moved_at': '2026-09-25T00:00:00Z',
      'from_store_id': 'old', 'to_store_id': 'new',
      'from_status_item_id': 'installed', 'to_status_item_id': 'as',
      'from_status': 'IN_USE', 'to_status': 'REPAIR', 'reason': '점검 반출',
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
      'id': 'store', 'name': '강남점', 'is_closed': false,
      'open_ticket_count': '2', 'install_date': '2026-09-01', 'movable_count': 3, 'rental_count': 1,
      'sets': [{'id': 'set', 'set_no': 2, 'name': '좌측'}],
      'asset_groups': [{'category_id': 'arm', 'category_name': '로봇팔', 'count': 1, 'assets': [asset]}],
      'category_counts': [{'category_id': 'arm', 'label': '로봇팔', 'color': '#123456', 'count': '4'}],
      'unreturned_rentals': [{'ticket_id': 'rental', 'ticket_no': 'AS-1', 'rental_type': '로봇팔', 'serials': 'SN-1', 'due_date': '2026-09-25', 'dday': 0}],
      'recent_tickets': [{'id': 'ticket', 'ticket_no': 'AS-2', 'title': '점검', 'status': 'RECEIVED',
        'received_at': '2026-09-25T00:00:00Z', 'completed_at': null, 'cause_labels': ['로봇팔 > 정지', '제어박스']}],
      'recover_options': [{'id': 'brand-recover', 'code': 'RECOVER', 'name': '브랜드 회수'}, status],
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
    expect(store.recoverOptions.map((s) => s.id), ['brand-recover', 'installed']);
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
    final closed = StoreCloseResult.fromJson({'store': json, 'moved': ['SN-1'], 'notices': ['렌탈은 기록에서 회수']});
    expect(closed.store.isClosed, true);
    expect(closed.moved, ['SN-1']);
    expect(closed.notices, ['렌탈은 기록에서 회수']);
    expect(StoreCloseResult.fromJson({'store': json}).notices, isEmpty);
    final equipment = EquipmentSetupResult.fromJson({'store': json, 'added': ['NG-0001'], 'moved': ['SN-1'], 'kept': ['SN-2']});
    expect(equipment.added, ['NG-0001']);
    expect(equipment.moved, ['SN-1']);
    expect(equipment.kept, ['SN-2']);
    expect(equipment.store.id, 'store');
    expect(StoreRentalRow.fromJson({'ticket_id': 't', 'ticket_no': 'AS-1'}).dday, isNull);
  });
}
