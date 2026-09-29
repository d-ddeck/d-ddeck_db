import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/data/calendar_repository.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/notifications_page.dart';
import 'package:ddeck_app/ui/theme.dart';
import 'service_work_types_test.dart' show FakeApi, FakeAuth;

class NotificationApi extends FakeApi {
  bool read = false;
  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async => {
    'items': [
      {
        'id': 'new',
        'type': 'SERVICE_ASSIGNED',
        'title': '새 서비스 서비스 담당자로 지정되었습니다',
        'body': '매장 장비 점검 요청입니다. 방문 일정과 담당자 연락처를 확인해 주세요.',
        'is_read': read,
        'created_at': '2026-09-27T00:00:00Z',
      },
      {
        'id': 'old',
        'type': 'EVENT_REMINDER',
        'title': '회의 일정 안내',
        'body': '오후 정기 회의',
        'is_read': true,
        'created_at': '2026-09-26T00:00:00Z',
      },
    ],
    'total': 2,
    'page': 1,
    'size': 50,
  };
  @override
  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    if (path.endsWith('/new/read')) read = true;
    return {};
  }
}

class NotificationAuth extends FakeAuth {
  @override
  Future<void> refreshUnread() async {}
}

void main() {
  for (final width in [390.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          'notification cards spacing and read behavior $width/$scale/$dark',
          (tester) async {
            tester.view.physicalSize = Size(width, 1200);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final api = NotificationApi();
            await tester.pumpWidget(
              MultiProvider(
                providers: [
                  Provider(create: (_) => CalendarRepository(api)),
                  ChangeNotifierProvider<AuthState>(
                    create: (_) => NotificationAuth(),
                  ),
                ],
                child: MaterialApp(
                  theme: dark ? AppTheme.dark() : AppTheme.light(),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: const NotificationsPage(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final first = find.byKey(const ValueKey('notification-new'));
            final second = find.byKey(const ValueKey('notification-old'));
            expect(tester.widget(first), isA<Card>());
            expect(
              tester.getTopLeft(second).dy - tester.getBottomLeft(first).dy,
              greaterThanOrEqualTo(12),
            );
            expect(find.textContaining('읽지 않음 ·'), findsOneWidget);
            await tester.tap(find.text('새 서비스 서비스 담당자로 지정되었습니다'));
            await tester.pumpAndSettle();
            expect(api.read, isTrue);
            expect(find.textContaining('읽지 않음 ·'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
