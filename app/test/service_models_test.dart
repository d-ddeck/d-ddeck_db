import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:ddeck_app/core/api_exception.dart';
import 'package:ddeck_app/data/service_repository.dart';
import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final category = {
    'id': 'category',
    'code': 'ARM',
    'name': '로봇팔',
    'color': '#123456',
  };
  final responder = {
    'id': 'responder',
    'code': 'LEE',
    'name': '이담당',
    'color': null,
  };
  final ticket = <String, dynamic>{
    'id': 'ticket',
    'ticket_no': 'AS-202609-0001',
    'title': '로봇팔 멈춤',
    'received_at': '2026-09-25T00:00:00Z',
    'status': 'RECEIVED',
    'priority': 'NORMAL',
    'channel': 'PHONE',
  };

  test('목록 응답은 상세 객체 없이도 번호와 표시용 이름을 파싱한다', () {
    final value = ServiceTicket.fromJson({
      ...ticket,
      'legacy_no': 42,
      'store_id': 'store',
      'store_name': '강남점',
      'brand_name': '브랜드',
      'cause_labels': ['로봇팔 > 정지 (제조사)', '제어박스'],
      'responder_names': ['이담당', '김담당'],
      'attachment_count': '2',
      'log_count': 3,
      'is_rental': true,
      'rental_type_id': 'rental',
      'rental_serials': 'SN1, SN2',
      'rental_due_date': '2026-09-30',
      'rental_returned': false,
    });
    expect(value.displayNo, '42');
    expect(value.storeId, 'store');
    expect(value.storeName, '강남점');
    expect(value.brandName, '브랜드');
    expect(value.causeLabels, ['로봇팔 > 정지 (제조사)', '제어박스']);
    expect(value.responderNames, ['이담당', '김담당']);
    expect(value.attachmentCount, 2);
    expect(value.logCount, 3);
    expect(value.causes, isEmpty);
    expect(value.responders, isEmpty);
    expect(value.isRental, isTrue);
    expect(value.rentalTypeId, 'rental');
    expect(value.rentalSerials, 'SN1, SN2');
    expect(value.rentalDueDate, DateTime(2026, 9, 30));
    expect(value.rentalReturned, isFalse);
    expect(value.store, isNull);
  });

  test('상세의 원인 순서·코드 브리프·매장·작성자·렌탈·안내를 보존한다', () {
    final value = ServiceTicket.fromJson({
      ...ticket,
      'fault_id': 'fault',
      'fault': {
        'id': 'fault',
        'code': 'CUSTOMER',
        'name': '고객 과실',
        'color': '#ff0000',
      },
      'causes': [
        {
          'id': 'row1',
          'seq': 1,
          'category_id': 'category',
          'symptom_id': 'symptom',
          'maker_id': 'maker',
          'category': category,
          'symptom': {'id': 'symptom', 'code': 'STOP', 'name': '정지'},
          'maker': {'id': 'maker', 'code': 'MAKER', 'name': '제조사'},
        },
        {
          'id': 'row2',
          'seq': 2,
          'category_id': 'category2',
          'symptom_id': null,
          'maker_id': null,
        },
      ],
      'responders': [responder],
      'store': {
        'id': 'store',
        'name': '강남점',
        'brand_id': 'brand',
        'brand_name': '브랜드',
        'is_closed': true,
      },
      'is_rental': true,
      'rental_type': {'id': 'rental', 'code': 'ARM', 'name': '로봇팔'},
      'rental_returned': true,
      'rental_return_date': '2026-09-25',
      'notices': ['재고 SN1: 렌탈 중 → 창고'],
      'logs': [
        {
          'id': 'log',
          'content': '회수 완료',
          'created_at': '2026-09-25T01:30:00Z',
          'author': {'id': 'user', 'full_name': '이담당', 'position': '기사'},
        },
      ],
    });
    expect(value.displayNo, ticket['ticket_no']);
    expect(value.faultId, 'fault');
    expect(value.fault!.name, '고객 과실');
    expect(value.causes.map((c) => c.seq), [1, 2]);
    expect(value.causes.first.id, 'row1');
    expect(value.causes.first.categoryId, 'category');
    expect(value.causes.first.symptomId, 'symptom');
    expect(value.causes.first.makerId, 'maker');
    expect(value.causes.first.category!.color, '#123456');
    expect(value.causes.first.symptom!.name, '정지');
    expect(value.causes.first.maker!.name, '제조사');
    expect(value.causes.last.symptom, isNull);
    expect(value.causes.last.maker, isNull);
    expect(value.responders.single.name, '이담당');
    expect(value.store!.brandId, 'brand');
    expect(value.store!.brandName, '브랜드');
    expect(value.store!.isClosed, isTrue);
    expect(value.rentalType!.name, '로봇팔');
    expect(value.rentalReturned, isTrue);
    expect(value.rentalReturnDate, DateTime(2026, 9, 25));
    expect(value.notices, ['재고 SN1: 렌탈 중 → 창고']);
    expect(value.logs.single.author!.fullName, '이담당');
    // asDate 는 로컬로 바꿔 준다. 시각(인스턴트)이 같은지만 본다.
    expect(
      value.logs.single.createdAt!.isAtSameMomentAs(
        DateTime.utc(2026, 9, 25, 1, 30),
      ),
      isTrue,
    );
  });

  test('누락·null 필드와 legacy_no 0을 안전하게 처리한다', () {
    final value = ServiceTicket.fromJson({
      ...ticket,
      'causes': null,
      'responders': null,
      'cause_labels': null,
      'responder_names': null,
      'notices': null,
      'legacy_no': 0,
    });
    expect(value.displayNo, '0');
    expect(value.causes, isEmpty);
    expect(value.responders, isEmpty);
    expect(value.notices, isEmpty);
    expect(value.isRental, isFalse);
    expect(value.rentalReturned, isFalse);
    expect(value.attachmentCount, 0);
    expect(value.logCount, 0);
    expect(ServiceLog.fromJson({'id': 'old'}).author, isNull);
    expect(
      CodeItem.fromJson({...category, 'parent_id': 'parent'}).parentId,
      'parent',
    );
  });

  test('크로스탭은 원인 수와 중복 제거한 대응 건수를 구분한다', () {
    final value = Crosstab.fromJson({
      'rows_axis': 'brand',
      'cols_axis': 'category',
      'cols': [
        {'key': 'arm', 'label': '로봇팔', 'color': '#123456'},
      ],
      'rows': [
        {
          'key': 'brand',
          'label': '브랜드',
          'color': null,
          'cells': {'arm': '3'},
          'total': 3,
          'ticket_count': 2,
          'ratio': '1.0',
        },
      ],
      'col_totals': {'arm': 3},
      'total_causes': 3,
      'total_tickets': 2,
    });
    expect(value.rowsAxis, 'brand');
    expect(value.colsAxis, 'category');
    expect(value.cols.single.color, '#123456');
    expect(value.rows.single.cells, {'arm': 3});
    expect(value.rows.single.total, 3);
    expect(value.rows.single.ticketCount, 2);
    expect(value.rows.single.ratio, 1.0);
    expect(value.colTotals, {'arm': 3});
    expect(value.totalCauses, 3);
    expect(value.totalTickets, 2);
    expect(Crosstab.fromJson({}).rows, isEmpty);
    expect(Crosstab.fromJson({}).colTotals, isEmpty);
    expect(StatAxis.responder.isMultiValue, isTrue);
  });

  test('매장 연도 집계는 연도 문자열·브랜드별 건수·개점 미상 목록을 읽는다', () {
    final value = StoreYears.fromJson({
      'years': ['2025', '2026'],
      'rows': [
        {
          'year': '2026',
          'operating': 8,
          'opened': 2,
          'closed': 1,
          'year_end': 7,
          'active': 4,
          'tickets': 12,
          'per_store': 1.5,
        },
      ],
      'by_brand': [
        {
          'brand': '브랜드',
          'counts': {'2025': 6, '2026': '8'},
        },
      ],
      'total_stores': 9,
      'closed_stores': 1,
      'unknown_open': ['개점 미상 매장'],
    });
    expect(value.years, ['2025', '2026']);
    expect(value.rows.single.operating, 8);
    expect(value.rows.single.opened, 2);
    expect(value.rows.single.closed, 1);
    expect(value.rows.single.yearEnd, 7);
    expect(value.rows.single.active, 4);
    expect(value.rows.single.tickets, 12);
    expect(value.rows.single.perStore, 1.5);
    expect(value.byBrand.single.counts, {'2025': 6, '2026': 8});
    expect(value.totalStores, 9);
    expect(value.closedStores, 1);
    expect(value.unknownOpen, ['개점 미상 매장']);
    expect(StoreYearRow.fromJson({}).perStore, isNull);
    expect(StoreYears.fromJson({}).unknownOpen, isEmpty);
  });

  test('대시보드의 오래된 미종결·렌탈 D-day·최근 기록·연도 집계 파싱', () {
    final value = ServiceDashboard.fromJson({
      'total': 20,
      'this_year': 12,
      'open_count': 4,
      'open_tickets': [
        {...ticket, 'store_name': '강남점', 'brand_name': '브랜드', 'days_open': 8},
      ],
      'unreturned_rentals': [
        {
          'ticket_id': 'ticket',
          'ticket_no': 'AS-1',
          'store_name': '강남점',
          'rental_type': '로봇팔',
          'serials': 'SN1, SN2',
          'due_date': '2026-09-24',
          'dday': -1,
        },
      ],
      'recent': [
        {...ticket, 'legacy_no': 42},
      ],
      'by_year': [
        {'year': '2026', 'count': 20},
      ],
    });
    expect(value.total, 20);
    expect(value.thisYear, 12);
    expect(value.openCount, 4);
    expect(value.openTickets.single.status, ServiceStatus.received);
    expect(value.openTickets.single.daysOpen, 8);
    expect(value.openTickets.single.storeName, '강남점');
    expect(value.unreturnedRentals.single.ticketId, 'ticket');
    expect(value.unreturnedRentals.single.rentalType, '로봇팔');
    expect(value.unreturnedRentals.single.serials, 'SN1, SN2');
    expect(value.unreturnedRentals.single.dueDate, DateTime(2026, 9, 24));
    expect(value.unreturnedRentals.single.dday, -1);
    expect(value.recent.single.displayNo, '42');
    expect(value.byYear.single.year, '2026');
    expect(value.byYear.single.count, 20);
    expect(RentalRow.fromJson({'dday': 0}).dday, 0);
    expect(RentalRow.fromJson({}).dday, isNull);
    expect(ServiceDashboard.fromJson({}).openTickets, isEmpty);
    expect(ServiceDashboard.fromJson({}).unreturnedRentals, isEmpty);
    expect(ServiceDashboard.fromJson({}).recent, isEmpty);
    expect(ServiceDashboard.fromJson({}).byYear, isEmpty);
  });

  test('엑셀의 바이트 오류 응답에서도 서버 메시지를 그대로 파싱한다', () {
    final options = RequestOptions(path: '/service/tickets/export.xlsx');
    final error = ApiException.fromDio(
      DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<List<int>>(
          requestOptions: options,
          statusCode: 400,
          data: utf8.encode(
            jsonEncode({
              'error': {'code': 'EXPORT_ERROR', 'message': '내려받을 기록이 없습니다.'},
            }),
          ),
        ),
      ),
    );
    expect(error.message, '내려받을 기록이 없습니다.');
    expect(error.statusCode, 400);
  });

  test('제목은 발생 내용 첫 줄의 250자이며 렌탈 날짜는 날짜만 전송한다', () {
    expect(ServiceRepository.titleFromDescription('  첫 줄\n둘째 줄  '), '첫 줄');
    expect(ServiceRepository.titleFromDescription('첫 줄\r\n둘째 줄'), '첫 줄');
    expect(
      ServiceRepository.titleFromDescription(
        List.filled(251, '😀').join(),
      ).runes.length,
      250,
    );
    expect(
      ServiceRepository.dateOnly(DateTime(2026, 1, 2, 23, 59)),
      '2026-01-02',
    );
    expect(ServiceRepository.dateOnly(null), isNull);
  });
}
