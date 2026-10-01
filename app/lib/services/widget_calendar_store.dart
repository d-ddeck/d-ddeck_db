import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/calendar.dart';
import 'alarm_widget_service.dart';

/// Separate from ringing alarms: includes visible events without reminders.
class WidgetCalendarStore {
  static const key = 'calendar_widget.synced';
  static Future<void> _queue = Future.value();

  static Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> save(
    List<CalendarEvent> events, {
    required String ownerUserId,
    required bool Function() isCurrentOwner,
  }) => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    if (!isCurrentOwner()) return;
    final saved = await prefs.setString(
      key,
      jsonEncode({
        'owner_user_id': ownerUserId,
        'synced_at': DateTime.now().toUtc().toIso8601String(),
        'events': [
          for (final e in events)
            {
              'event_id': e.id,
              'title': e.title,
              'starts_at': e.startsAt.toUtc().toIso8601String(),
              'ends_at': e.endsAt.toUtc().toIso8601String(),
              'all_day': e.allDay,
              'location': e.location,
              'calendar_name': e.calendar?.name,
            },
        ],
      }),
    );
    if (!saved) throw StateError('위젯 일정을 저장하지 못했습니다.');
    await AlarmWidgetService.refresh();
  });

  Future<void> clear() => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(key)) throw StateError('위젯 일정을 지우지 못했습니다.');
    await AlarmWidgetService.refresh();
  });
}
