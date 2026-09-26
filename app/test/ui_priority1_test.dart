import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddeck_app/ui/common/filter_bar.dart';
import 'package:ddeck_app/ui/common/pinned_table.dart';
import 'package:ddeck_app/ui/common/responsive_table.dart';
import 'package:ddeck_app/ui/service/service_ticket_row.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/ui/theme.dart';

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets('적용 필터는 펼치지 않아도 표시되고 개별 해제 가능 ($width)', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final filters = ['2026년', '서울점'];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => FilterBar(
                appliedFilters: filters,
                onRemoveFilter: (i) => update(() => filters.removeAt(i)),
                onReset: () => update(filters.clear),
                children: const [Text('검색 입력')],
              ),
            ),
          ),
        ),
      );
      expect(find.text('서울점'), findsOneWidget);
      await tester.tap(find.byTooltip('서울점 조건 해제'));
      await tester.pumpAndSettle();
      expect(find.text('서울점'), findsNothing);
      expect(find.text('2026년'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('가로 스크롤에도 S/N 위치가 유지되고 체크박스 동작', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool selected = false;
    int opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, update) => PinnedTable<String>(
                rows: const ['SERIAL-12345678901234567890'],
                isSelected: (_) => selected,
                onTap: (_) => opened++,
                columns: [
                  TableColumn(
                    label: 'S/N',
                    cell: (s) => Row(
                      children: [
                        Checkbox(
                          value: selected,
                          onChanged: (v) => update(() => selected = v!),
                        ),
                        Expanded(child: Text(s)),
                      ],
                    ),
                  ),
                  for (final name in ['품명', '상태', '위치', '세트', '작업'])
                    TableColumn(label: name, cell: (_) => Text('$name 값')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final serial = find.text('SERIAL-12345678901234567890');
    final before = tester.getTopLeft(serial);
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(serial), before);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(selected, true);
    expect(opened, 0);
    await tester.tap(serial);
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('대응 목록은 넓은 화면 열 정렬, 좁은 화면 카드와 긴 제목 툴팁', (tester) async {
    addTearDown(tester.view.reset);
    const title = '아주 긴 발생 내용으로 표시 범위를 넘더라도 전체 내용을 확인할 수 있는 대응 기록';
    final ticket = ServiceTicket.fromJson({
      'id': 'ticket',
      'ticket_no': 'AS-202609-0001',
      'title': title,
      'received_at': '2026-09-26T09:00:00Z',
      'status': 'RECEIVED',
    });
    for (final width in [1440.0, 390.0]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Column(
              children: [
                const ServiceTicketRow.header(),
                ServiceTicketRow(ticket: ticket, onTap: () {}),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('매장 / 브랜드'),
        width == 1440 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byTooltip(width == 1440 ? title : '${ticket.displayNo} · $title'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
