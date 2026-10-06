import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/models/quotation.dart';
import 'package:ddeck_app/ui/service/quotation_page.dart';

const notice = '레인보우 로봇 입고 시 전원을 차단하고 포장 상태로 보관하세요.';

const rainbow = QuoteChecklistEntry(
  id: 'rainbow',
  label: '레인보우 입고',
  notes: notice,
  items: [
    {
      'name': '입고 점검',
      'specification': 'RB5',
      'quantity': '1',
      'unit_price': '120000',
      'note': '',
    },
  ],
);

const initial = {
  'quote_date': '2026-10-06',
  'valid_until': '2026-11-05',
  'supplier': {'company': '공급회사'},
  'recipient': {'company': '고객사'},
  'notes': '기본 안내',
};

class SaveApi implements ApiClient {
  Object? saved;
  @override
  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    saved = body;
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SaveApi> _open(
  WidgetTester tester, {
  Map<String, dynamic> data = initial,
}) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = SaveApi();
  await tester.pumpWidget(
    Provider<ApiClient>.value(
      value: api,
      child: MaterialApp(
        home: QuotationEditPage(
          path: '/service/tickets/t/quotations',
          initial: data,
          baseVersion: 0,
          checklist: const [rainbow],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

TextField _field(WidgetTester tester, String label) => tester.widget<TextField>(
  find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  ),
);

void main() {
  group('notes blocks', () {
    test('add once, separated by a blank line', () {
      expect(addNotesBlock('', notice), notice);
      expect(addNotesBlock('기본 안내\n', notice), '기본 안내\n\n$notice');
      expect(addNotesBlock('기본 안내\n\n$notice', notice), '기본 안내\n\n$notice');
    });

    test('remove only an untouched block', () {
      expect(removeNotesBlock('기본 안내\n\n$notice', notice), '기본 안내');
      expect(removeNotesBlock('$notice\n\n기본 안내', notice), '기본 안내');
      expect(removeNotesBlock('기본 안내\n\n고친 문구', notice), isNull);
    });
  });

  testWidgets('checking fills notes and items, unchecking removes them', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('체크리스트'), findsOneWidget);
    expect(find.text('품목 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '레인보우 입고'));
    await tester.pumpAndSettle();
    expect(_field(tester, '안내사항').controller!.text, '기본 안내\n\n$notice');
    // The blank starting row is replaced, not left above the added item.
    expect(find.text('품목 2'), findsNothing);
    expect(_field(tester, '품목 *').controller!.text, '입고 점검');

    await tester.tap(find.widgetWithText(FilterChip, '레인보우 입고'));
    await tester.pumpAndSettle();
    expect(_field(tester, '안내사항').controller!.text, '기본 안내');
    expect(_field(tester, '품목 *').controller!.text, isEmpty);
    expect(find.text('품목 1'), findsOneWidget);
  });

  testWidgets('edited notes and items are kept when unchecking', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.widgetWithText(FilterChip, '레인보우 입고'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '안내사항',
      ),
      '고객과 협의한 안내',
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '단가(원) *',
      ),
      '150000',
    );
    await tester.tap(find.widgetWithText(FilterChip, '레인보우 입고'));
    await tester.pumpAndSettle();
    expect(_field(tester, '안내사항').controller!.text, '고객과 협의한 안내');
    expect(_field(tester, '단가(원) *').controller!.text, '150000');
    expect(find.textContaining('그대로 두었습니다'), findsOneWidget);
  });

  testWidgets('checked ids are saved and restored for the next version', (
    tester,
  ) async {
    final api = await _open(tester);
    await tester.tap(find.widgetWithText(FilterChip, '레인보우 입고'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 버전 PDF 생성 · 저장'));
    await tester.pumpAndSettle();
    final body = api.saved as Map;
    expect(body['checks'], ['rainbow']);
    expect(body['notes'], '기본 안내\n\n$notice');
    expect((body['items'] as List).single['name'], '입고 점검');

    await tester.pumpWidget(const SizedBox());
    await _open(
      tester,
      data: {
        ...initial,
        'checks': ['rainbow'],
      },
    );
    final chip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, '레인보우 입고'),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('no checklist card when nothing is configured', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: SaveApi(),
        child: const MaterialApp(
          home: QuotationEditPage(path: '/p', initial: initial, baseVersion: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('체크리스트'), findsNothing);
  });
}
