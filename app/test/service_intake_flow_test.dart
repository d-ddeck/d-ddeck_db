import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/data/calendar_repository.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/ui/service/service_intake_page.dart';

const ticketJson = {
  'id': 'ticket',
  'ticket_no': 'AS-202610-0001',
  'title': '로봇팔 점검',
  'received_at': '2026-10-02T00:00:00Z',
};

class FakeApi implements ApiClient {
  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    if (path.startsWith('/admin/codes/')) {
      return {
        'id': 'responders',
        'code': 'SERVICE_RESPONDER',
        'name': '서비스인원',
        'items': [
          {'id': 'r1', 'code': 'R1', 'name': '김기사'},
        ],
      };
    }
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 저장 요청을 기록하는 접수 내용.
class SaveLog {
  final calls = <(ServiceStatus, String?, DateTime?)>[];
  Future<ServiceTicket> save(
    ServiceStatus status, {
    String? resultNote,
    DateTime? completedAt,
  }) async {
    calls.add((status, resultNote, completedAt));
    return ServiceTicket.fromJson({...ticketJson, 'status': status.value});
  }
}

/// 흐름 화면을 열고, 닫혔을 때 돌려준 값을 읽는 함수를 준다.
Future<Object? Function()> _open(
  WidgetTester tester,
  ServiceIntakeDraft draft,
) async {
  Object? result = 'not popped';
  final api = FakeApi();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<AdminRepository>(create: (_) => AdminRepository(api)),
        Provider<CalendarRepository>(create: (_) => CalendarRepository(api)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ServiceIntakeFlowPage(draft: draft),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

ServiceIntakeDraft _draft(SaveLog log, {Set<String>? responders}) =>
    ServiceIntakeDraft(
      title: '로봇팔 점검',
      storeName: '강남점',
      responders: responders ?? {},
      save: log.save,
    );

void main() {
  testWidgets('nothing is saved until the last step picks a status', (
    tester,
  ) async {
    final log = SaveLog();
    final result = await _open(tester, _draft(log));

    // 2단계: 견적서 없이 건너뛴다. 아직 저장되지 않는다.
    expect(find.text('작성된 견적서가 없습니다. 필요 없으면 건너뛰세요.'), findsOneWidget);
    await tester.tap(find.text('건너뛰기'));
    await tester.pumpAndSettle();
    expect(log.calls, isEmpty);

    // 3단계: 일정 없이 진행중으로 저장.
    expect(find.text('추가한 일정이 없습니다. 필요 없으면 건너뛰세요.'), findsOneWidget);
    await tester.tap(find.text('진행중으로 접수 저장'));
    await tester.pumpAndSettle();

    expect(log.calls.single.$1, ServiceStatus.inProgress);
    expect(log.calls.single.$2, isNull);
    expect(result(), isA<ServiceTicket>());
  });

  testWidgets('completion details are entered inline, not in a dialog', (
    tester,
  ) async {
    final log = SaveLog();
    final responders = <String>{};
    await _open(tester, _draft(log, responders: responders));
    await tester.tap(find.text('건너뛰기'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('종결'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.widgetWithText(TextFormField, '서비스 내용 *'), findsOneWidget);
    expect(find.textContaining('서비스일:'), findsOneWidget);

    // 필수값이 비면 저장하지 않는다.
    await tester.ensureVisible(find.text('종결로 접수 저장'));
    await tester.tap(find.text('종결로 접수 저장'));
    await tester.pumpAndSettle();
    expect(find.text('서비스 내용을 입력해 주세요.'), findsOneWidget);
    expect(find.text('서비스인원을 선택해 주세요.'), findsOneWidget);
    expect(log.calls, isEmpty);

    await tester.enterText(
      find.widgetWithText(TextFormField, '서비스 내용 *'),
      '센서 교체',
    );
    await tester.ensureVisible(find.text('김기사'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('김기사'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('종결로 접수 저장'));
    await tester.tap(find.text('종결로 접수 저장'));
    await tester.pumpAndSettle();

    expect(responders, {'r1'});
    expect(log.calls.single.$1, ServiceStatus.completed);
    expect(log.calls.single.$2, '센서 교체');
    expect(log.calls.single.$3, isNotNull);
  });
}
