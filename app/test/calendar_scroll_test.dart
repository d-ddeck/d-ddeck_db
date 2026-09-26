import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/data/calendar_repository.dart';
import 'package:ddeck_app/models/calendar.dart';
import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/calendar/calendar_page.dart';
import 'package:ddeck_app/ui/calendar/calendar_range_selection.dart';
import 'package:ddeck_app/ui/calendar/calendar_month_data.dart';
import 'package:ddeck_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Auth extends ChangeNotifier implements AuthState {
  @override
  UserProfile? get user => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Calendar implements CalendarRepository {
  @override
  Future<List<AppCalendar>> calendars() async => [];
  @override
  Future<List<Holiday>> holidays(int year) async => [];
  @override
  Future<List<CalendarEvent>> events({
    required DateTime from,
    required DateTime to,
    String? calendarId,
    bool mineOnly = false,
    String? categoryId,
    String? participantId,
  }) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Admin implements AdminRepository {
  @override
  Future<CodeGroup> codeGroup(String code) async =>
      CodeGroup(id: 'c', code: code, name: '분류', module: 'calendar', items: []);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'touch drag over wide calendar scrolls instead of selecting a range',
    (tester) async {
      var selected = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CalendarRangeSelection(
                firstDay: DateTime(2026, 9, 1),
                rowHeight: 100,
                weeks: 12,
                enabled: true,
                onSelected: (_, _) => selected = true,
                child: const SizedBox(height: 1222, width: double.infinity),
              ),
            ),
          ),
        ),
      );
      await tester.dragFrom(const Offset(300, 300), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        greaterThan(0),
      );
      expect(selected, isFalse);
    },
  );
  for (final size in [
    const Size(360, 640),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'calendar entire page scrolls with bottom safe area $size / $scale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final auth = _Auth();
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<AuthState>.value(value: auth),
                Provider<CalendarRepository>.value(value: _Calendar()),
                Provider<AdminRepository>.value(value: _Admin()),
              ],
              child: MaterialApp(
                theme: AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    padding: const EdgeInsets.only(bottom: 24),
                  ),
                  child: child!,
                ),
                home: const Scaffold(
                  body: CalendarPage(),
                  bottomNavigationBar: SizedBox(height: 72),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Exercise a six-row month, where the original fixed-height layout clipped.
          var month = DateTime(DateTime.now().year, DateTime.now().month);
          for (var i = 0; i < 12; i++) {
            final data = CalendarMonthData(
              month: month,
              categories: [],
              calendars: [],
              events: [],
              holidays: [],
            );
            if (data.weeks.length == 6) break;
            await tester.ensureVisible(find.byIcon(Icons.chevron_right).first);
            await tester.tap(find.byIcon(Icons.chevron_right).first);
            await tester.pumpAndSettle();
            month = DateTime(month.year, month.month + 1);
            expect(tester.takeException(), isNull);
          }
          final scroll = find.byKey(const ValueKey('calendar-page-scroll'));
          final scrollable = find
              .descendant(of: scroll, matching: find.byType(Scrollable))
              .first;
          final state = tester.state<ScrollableState>(scrollable);
          state.position.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.drag(scroll, const Offset(0, -180));
          await tester.pumpAndSettle();
          expect(state.position.pixels, greaterThan(0));
          await tester.scrollUntilVisible(
            find.text('아직 등록된 일정이 없습니다'),
            220,
            scrollable: scrollable,
          );
          state.position.jumpTo(state.position.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(
            tester.getBottomLeft(find.text('아직 등록된 일정이 없습니다')).dy,
            lessThan(size.height - 72 - 24),
          );
          expect(tester.takeException(), isNull);
          await tester.drag(scroll, const Offset(0, 160));
          await tester.pumpAndSettle();
          expect(
            state.position.pixels,
            lessThan(state.position.maxScrollExtent),
          );
          await tester.pumpWidget(const SizedBox());
          auth.dispose();
        },
      );
    }
  }
}
