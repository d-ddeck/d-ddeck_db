import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/data/auth_repository.dart';
import 'package:ddeck_app/data/service_repository.dart';
import 'package:ddeck_app/data/store_repository.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/service/service_form_page.dart';
import 'package:ddeck_app/ui/service/service_ticket_row.dart';
import 'package:ddeck_app/ui/theme.dart';

const types = [
  {'id': 'as', 'code': 'AS', 'name': '수리/점검'},
  {'id': 'cs', 'code': 'CS', 'name': '고객 서비스'},
  {'id': 'po', 'code': 'PO', 'name': '구매'},
  {'id': 'custom', 'code': 'INSTALL', 'name': '설치 지원'},
];
const ticketJson = {
  'id': 'ticket',
  'ticket_no': 'AS-202609-0001',
  'title': '장비 구매 요청',
  'received_at': '2026-09-27T00:00:00Z',
};

class FakeApi implements ApiClient {
  Map<String, dynamic>? lastQuery;
  Object? lastBody;
  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    lastQuery = query;
    if (path.startsWith('/admin/codes/')) {
      return {
        'id': path,
        'code': path.split('/').last,
        'name': '업무 구분',
        'items': path.endsWith('SERVICE_WORK_TYPE') ? types : [],
      };
    }
    if (path.startsWith('/admin/settings/')) {
      return {'module': 'SERVICE', 'settings': [], 'code_groups': []};
    }
    return [];
  }

  @override
  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    lastBody = body;
    return {...ticketJson, ...body as Map<String, dynamic>};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuth extends ChangeNotifier implements AuthState {
  @override
  UserProfile? get user => UserProfile.fromJson({
    'id': 'preview',
    'full_name': '검토 담당',
    'role': 'ADMIN',
    'status': 'APPROVED',
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = String.fromEnvironment('WORK_TYPE_CAPTURE_DIR');
  const font = String.fromEnvironment('WORK_TYPE_CAPTURE_FONT');
  setUpAll(() async {
    if (font.isNotEmpty) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await (FontLoader('Preview')..addFont(
            File(font).readAsBytes().then((b) => ByteData.sublistView(b)),
          ))
          .load();
    }
  });
  test('custom types and legacy null remain independent of ticket number', () {
    for (final item in types) {
      final ticket = ServiceTicket.fromJson({
        ...ticketJson,
        'work_type_id': item['id'],
        'work_type': item,
      });
      expect(ticket.workTypeId, item['id']);
      expect(ticket.workTypeLabel, '${item['code']} · ${item['name']}');
      expect(ticket.displayNo, ticketJson['ticket_no']);
    }
    expect(ServiceTicket.fromJson(ticketJson).workTypeLabel, '미분류');
    expect(
      const ServiceFilter(workTypeId: 'custom').toQuery()['work_type_id'],
      'custom',
    );
  });
  test('repository forwards work type on creation and filtering', () async {
    final api = FakeApi();
    final repo = ServiceRepository(api);
    await repo.create(description: '설치 요청', workTypeId: 'custom');
    expect((api.lastBody as Map)['work_type_id'], 'custom');
    await repo.list(workTypeId: 'po');
    expect(api.lastQuery!['work_type_id'], 'po');
  });
  test(
    'creation sends selected status, note and occurrence time in UTC',
    () async {
      final api = FakeApi();
      final time = DateTime(2026, 10, 1, 14, 37);
      await ServiceRepository(api).create(
        description: '점검',
        receivedAt: time,
        initialStatus: ServiceStatus.completed,
        note: '방문 메모',
        resultNote: '점검 완료',
      );
      final body = api.lastBody as Map;
      expect(body['initial_status'], 'COMPLETED');
      expect(body['note'], '방문 메모');
      expect(body['result_note'], '점검 완료');
      expect(body['received_at'], time.toUtc().toIso8601String());
    },
  );
  for (final width in [390.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets('new form defaults AS and offers custom type $width/$dark', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = FakeApi();
        final previewKey = GlobalKey();
        final theme = dark ? AppTheme.dark() : AppTheme.light();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider<AdminRepository>(create: (_) => AdminRepository(api)),
              Provider<AuthRepository>(create: (_) => AuthRepository(api)),
              Provider<ServiceRepository>(
                create: (_) => ServiceRepository(api),
              ),
              Provider<StoreRepository>(create: (_) => StoreRepository(api)),
              ChangeNotifierProvider<AuthState>(create: (_) => FakeAuth()),
            ],
            child: RepaintBoundary(
              key: previewKey,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: font.isEmpty
                    ? theme
                    : theme.copyWith(
                        textTheme: theme.textTheme.apply(fontFamily: 'Preview'),
                      ),
                home: const ServiceFormPage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byWidgetPredicate(
          (w) =>
              w is DropdownButtonFormField<String> &&
              w.decoration.labelText == '업무 구분',
        );
        expect(field, findsOneWidget);
        expect(tester.state<FormFieldState<String>>(field).value, 'as');
        await Scrollable.ensureVisible(tester.element(field), alignment: 0.25);
        await tester.pumpAndSettle();
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text('INSTALL · 설치 지원').last);
        await tester.pumpAndSettle();
        expect(tester.state<FormFieldState<String>>(field).value, 'custom');
        expect(find.text('기타'), findsNothing);
        expect(find.text('첨부파일 추가'), findsOneWidget);
        final status = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<ServiceStatus>,
        );
        await Scrollable.ensureVisible(tester.element(status), alignment: 0.25);
        await tester.pumpAndSettle();
        await tester.tap(status);
        await tester.pumpAndSettle();
        await tester.tap(find.text('종결').last);
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextFormField, '서비스 처리 내용 *'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (capture.isNotEmpty) {
          Scrollable.of(tester.element(field)).position.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary =
                previewKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '$capture/form-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
    testWidgets('list shows work type without overflow at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: ServiceTicketRow(
                  ticket: ServiceTicket.fromJson({
                    ...ticketJson,
                    'work_type': types[2],
                  }),
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('PO · 구매'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
