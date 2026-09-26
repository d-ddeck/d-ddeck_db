import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/models/quotation.dart';
import 'package:ddeck_app/ui/service/quotation_page.dart';
import 'package:ddeck_app/ui/theme.dart';

const snapshot = {
  'quote_date': '2026-09-27',
  'valid_until': '2026-10-27',
  'supplier': {
    'company': '검증 공급회사',
    'contact': '대표',
    'address': '검증 주소',
    'phone': '010-0000-0000',
    'email': 'sample@example.test',
  },
  'recipient': {'company': '검증 고객사', 'contact': '담당'},
  'bank_account': '검증용 계좌',
  'notes': '테스트 견적',
  'items': [
    {
      'name': '교체 부품',
      'specification': '한글 규격',
      'quantity': '1.005',
      'unit_price': '100',
      'note': '부품',
    },
  ],
};

class QuoteApi implements ApiClient {
  Object? saved;
  final versions = [
    {
      'id': 'v1',
      'version': 1,
      'filename': 'QT-AS-0001-v001_abcd.pdf',
      'author_name': '검토 담당',
      'created_at': '2026-09-27T09:00:00+09:00',
      'total': 111,
      'revision_note': '최초 작성',
    },
  ];
  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    if (path.endsWith('/v1')) return {'snapshot': snapshot};
    if (path.endsWith('/defaults')) return snapshot;
    return versions;
  }

  @override
  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    saved = body;
    versions.insert(0, {
      ...versions.first,
      'id': 'v2',
      'version': 2,
      'filename': 'QT-AS-0001-v002_efgh.pdf',
    });
    return versions.first;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'quotation amounts use decimal rounding without binary floating point',
    () {
      expect(
        quotationSubtotal([
          {'quantity': '1.005', 'unit_price': '100'},
        ]),
        101,
      );
      expect(
        quotationSubtotal([
          {'quantity': '0.005', 'unit_price': '100'},
        ]),
        1,
      );
      expect(
        quotationSubtotal([
          {'quantity': '1000000', 'unit_price': '10000000000'},
        ]),
        10000000000000000,
      );
      expect(
        quotationSubtotal([
          {'quantity': '-1', 'unit_price': '10'},
        ]),
        isNull,
      );
      expect(
        quotationSubtotal([
          {'quantity': '1.0001', 'unit_price': '10'},
        ]),
        isNull,
      );
    },
  );
  for (final width in [390.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'quotation edit saves new version and preserves history $width/$dark',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = QuoteApi();
          await tester.pumpWidget(
            Provider<ApiClient>.value(
              value: api,
              child: MaterialApp(
                theme: dark ? AppTheme.dark() : AppTheme.light(),
                home: const QuotationPage(ticketId: 'ticket'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('v001'), findsWidgets);
          await tester.tap(find.text('최신 견적 수정 · 새 버전 저장'));
          await tester.pumpAndSettle();
          expect(find.text('견적서 v002 작성'), findsOneWidget);
          expect(find.text('검증 공급회사'), findsOneWidget);
          final save = find.text('새 버전 PDF 생성 · 저장');
          await tester.scrollUntilVisible(
            save,
            500,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect((api.saved as Map)['base_version'], 1);
          expect(
            ((api.saved as Map)['items'] as List).first['quantity'],
            '1.005',
          );
          expect(find.textContaining('v002'), findsWidgets);
          expect(find.text('QT-AS-0001-v001_abcd.pdf'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('empty required fields do not create PDF revision', (
    tester,
  ) async {
    final api = QuoteApi();
    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: api,
        child: const MaterialApp(
          home: QuotationEditPage(
            path: '/service/tickets/t/quotations',
            initial: {},
            baseVersion: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final save = find.text('새 버전 PDF 생성 · 저장');
    await tester.scrollUntilVisible(
      save,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(api.saved, isNull);
    expect(find.text('필수 항목과 숫자 입력을 확인해 주세요.'), findsOneWidget);
  });
}
