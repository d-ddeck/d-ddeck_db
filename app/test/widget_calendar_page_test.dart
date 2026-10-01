import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/widget_calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Auth extends ChangeNotifier implements AuthState {
  bool fail = true;
  int calls = 0;
  @override
  AuthPhase get phase => AuthPhase.ready;
  @override
  Future<void> syncWidgetCalendar() async {
    calls++;
    if (fail) throw StateError('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'widget launch offers VPN recovery and retries server synchronization',
    (tester) async {
      final auth = _Auth();
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: const MaterialApp(home: WidgetCalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.calls, 1);
      expect(find.text('VPN 연결 설정'), findsOneWidget);
      expect(find.textContaining('서버에 연결하거나'), findsOneWidget);
      auth.fail = false;
      await tester.tap(find.text('다시 동기화'));
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
      expect(find.textContaining('캘린더를 동기화했습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
