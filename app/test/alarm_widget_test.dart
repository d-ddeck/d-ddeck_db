import 'package:ddeck_app/models/calendar.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/services/alarm_widget_service.dart';
import 'package:ddeck_app/services/synced_alarm_store.dart';
import 'package:ddeck_app/ui/alarm_widget_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AlarmWidgetService.launch.value = null;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(AlarmWidgetService.channel, null);
    AlarmWidgetService.channel.setMethodCallHandler(null);
    debugDefaultTargetPlatformOverride = null;
    AlarmWidgetService.launch.value = null;
  });

  test(
    'refresh sees durable data after save and empty data after clear',
    () async {
      final snapshots = <SyncedAlarmSnapshot>[];
      messenger.setMockMethodCallHandler(AlarmWidgetService.channel, (
        call,
      ) async {
        if (call.method == 'refresh') {
          snapshots.add(await SyncedAlarmStore().load());
        }
        return null;
      });
      final date = DateTime.utc(2026, 10, 1);
      await SyncedAlarmStore().save([
        UpcomingReminder(
          reminderId: 'r1',
          eventId: 'e1',
          title: '회의',
          startsAt: date,
          endsAt: date.add(const Duration(hours: 1)),
          scheduledAt: date,
          offsetMinutes: 0,
        ),
      ], ownerUserId: 'owner');
      await SyncedAlarmStore().clear();
      expect(snapshots.first.ownerUserId, 'owner');
      expect(snapshots.first.reminders.single.reminderId, 'r1');
      expect(snapshots.last.reminders, isEmpty);
    },
  );

  test('native refresh failure does not lose saved alarms', () async {
    messenger.setMockMethodCallHandler(AlarmWidgetService.channel, (_) async {
      throw PlatformException(code: 'launcher_unavailable');
    });
    await SyncedAlarmStore().save([], ownerUserId: 'owner');
    expect((await SyncedAlarmStore().load()).ownerUserId, 'owner');
  });

  test('cold and warm launches, including header, are consumed once', () async {
    String? next = 'r1';
    messenger.setMockMethodCallHandler(AlarmWidgetService.channel, (
      call,
    ) async {
      if (call.method != 'takeLaunch') return null;
      final value = next;
      next = null;
      return value;
    });
    await AlarmWidgetService.initialize();
    expect(AlarmWidgetService.launch.value, 'r1');
    AlarmWidgetService.launch.value = null;
    await AlarmWidgetService.takeLaunch();
    expect(AlarmWidgetService.launch.value, isNull);
    next = '';
    await messenger.handlePlatformMessage(
      'ddeck/alarm_widget',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('launchAvailable'),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(AlarmWidgetService.launch.value, '');
  });

  testWidgets('deleted/stale widget item shows no resurrected details', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(
      const MaterialApp(home: AlarmWidgetPage(reminderId: 'deleted')),
    );
    await tester.pumpAndSettle();
    expect(find.text('이 알람은 삭제되었거나 저장된 목록에 없습니다.'), findsOneWidget);
    expect(find.text('서버의 일정 상세 보기'), findsNothing);
  });
  testWidgets(
    'saved detail works offline without enabling another account access',
    (tester) async {
      debugDefaultTargetPlatformOverride = null;
      final date = DateTime.utc(2026, 10, 1);
      await tester.runAsync(
        () => SyncedAlarmStore().save([
          UpcomingReminder(
            reminderId: 'r1',
            eventId: 'e1',
            title: '저장된 회의',
            startsAt: date,
            endsAt: date.add(const Duration(hours: 1)),
            scheduledAt: date,
            offsetMinutes: 0,
          ),
        ], ownerUserId: 'owner'),
      );
      final auth = _OfflineAuth();
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: const MaterialApp(home: AlarmWidgetPage(reminderId: 'r1')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('저장된 회의'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}

class _OfflineAuth extends ChangeNotifier implements AuthState {
  @override
  AuthPhase get phase => AuthPhase.loggedOut;
  @override
  UserProfile? get user => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
