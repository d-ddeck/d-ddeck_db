import 'dart:convert';
import 'package:ddeck_app/models/calendar.dart';
import 'package:ddeck_app/services/widget_calendar_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  CalendarEvent event() => CalendarEvent(
    id: 'event',
    calendarId: 'c',
    title: '알람 없는 일정',
    startsAt: DateTime(2026, 10, 3, 9),
    endsAt: DateTime(2026, 10, 3, 10),
    status: EventStatus.scheduled,
  );
  test(
    'calendar stores events without reminders and clears on logout',
    () async {
      final store = WidgetCalendarStore();
      await store.save([event()], ownerUserId: 'a', isCurrentOwner: () => true);
      final prefs = await SharedPreferences.getInstance();
      final data = jsonDecode(prefs.getString(WidgetCalendarStore.key)!);
      expect(data['events'].single['event_id'], 'event');
      expect(data['owner_user_id'], 'a');
      await store.clear();
      expect(prefs.getString(WidgetCalendarStore.key), isNull);
    },
  );
  test(
    'in-flight old-account results cannot repopulate a cleared widget',
    () async {
      final store = WidgetCalendarStore();
      var current = true;
      final pending = store.save(
        [event()],
        ownerUserId: 'old',
        isCurrentOwner: () => current,
      );
      current = false;
      await store.clear();
      await pending;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(WidgetCalendarStore.key), isNull);
    },
  );
}
