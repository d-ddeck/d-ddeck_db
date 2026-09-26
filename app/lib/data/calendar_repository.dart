import '../core/api_client.dart';
import '../models/calendar.dart';
import '../models/common.dart';
import '../models/user.dart';

class CalendarRepository {
  CalendarRepository(this._api);
  final ApiClient _api;

  Future<List<Holiday>> holidays(int year) async {
    final res = await _api.get('/calendar/holidays', query: {'year': year});
    return (res as List? ?? []).map((e) => Holiday.fromJson(asMap(e))).toList();
  }

  Future<List<AppCalendar>> calendars() async {
    final res = await _api.get('/calendar/calendars');
    return (res as List? ?? [])
        .map((e) => AppCalendar.fromJson(asMap(e)))
        .toList();
  }

  Future<AppCalendar> createCalendar({
    required String name,
    CalendarType type = CalendarType.personal,
    String color = '#3B82F6',
    String? departmentId,
  }) async {
    final res = await _api.post(
      '/calendar/calendars',
      body: {
        'name': name,
        'type': type.value,
        'color': color,
        if (departmentId != null) 'department_id': departmentId,
      },
    );
    return AppCalendar.fromJson(asMap(res));
  }

  /// Returns every event OVERLAPPING the window, so a multi-day event shows on
  /// each day it spans. The server caps the window at 400 days.
  Future<List<CalendarEvent>> events({
    required DateTime from,
    required DateTime to,
    String? calendarId,
    bool mineOnly = false,
    String? categoryId,
    String? participantId,
  }) async {
    final res = await _api.get(
      '/calendar/events',
      query: {
        'date_from': from,
        'date_to': to,
        'calendar_id': calendarId,
        'mine_only': mineOnly ? true : null,
        'category_id': categoryId,
        'participant_id': participantId,
      },
    );
    return (res as List? ?? [])
        .map((e) => CalendarEvent.fromJson(asMap(e)))
        .toList();
  }

  Future<CalendarEvent> event(String id) async =>
      CalendarEvent.fromJson(asMap(await _api.get('/calendar/events/$id')));

  /// Creating an event notifies the participants immediately and schedules a
  /// reminder. Omitting `reminders` makes the server apply the calendar
  /// default, which is why the form does not have to ask about it.
  Future<CalendarEvent> createEvent({
    required String calendarId,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    String? description,
    String? location,
    String? categoryId,
    String? color,
    bool allDay = false,
    bool isPrivate = false,
    List<String> participantIds = const [],
    String? rrule,
    DateTime? recurrenceEnd,
    int? reminderMinutes,
    List<Map<String, dynamic>>? reminders,
  }) async {
    final res = await _api.post(
      '/calendar/events',
      body: {
        'calendar_id': calendarId,
        'title': title,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'ends_at': endsAt.toUtc().toIso8601String(),
        if (description?.isNotEmpty == true) 'description': description,
        if (location?.isNotEmpty == true) 'location': location,
        if (categoryId != null) 'category_id': categoryId,
        if (color?.trim().isNotEmpty == true) 'color': color!.trim(),
        'rrule': rrule,
        'recurrence_end': recurrenceEnd?.toUtc().toIso8601String(),
        'all_day': allDay,
        'is_private': isPrivate,
        'participant_ids': participantIds,
        if (reminders != null)
          'reminders': reminders
        else if (reminderMinutes != null)
          'reminders': [
            {'offset_minutes': reminderMinutes, 'method': 'PUSH'},
          ],
      },
    );
    return CalendarEvent.fromJson(asMap(res));
  }

  Future<CalendarEvent> updateEvent(
    String id,
    Map<String, dynamic> changes,
  ) async {
    final res = await _api.patch('/calendar/events/$id', body: changes);
    return CalendarEvent.fromJson(asMap(res));
  }

  Future<void> deleteEvent(String id) => _api.delete('/calendar/events/$id');

  Future<void> respond(String eventId, ParticipantResponse response) =>
      _api.post(
        '/calendar/events/$eventId/respond',
        body: {'response': response.value},
      );

  /// 기기에 걸어둘 알람 목록. 한 번의 요청으로 알림 구성에 필요한 정보를
  /// 모두 받아, 이후에는 네트워크 없이도 울릴 수 있게 한다.
  Future<List<UpcomingReminder>> upcomingReminders({int days = 7}) async {
    final res = await _api.get(
      '/calendar/reminders/upcoming',
      query: {'days': days},
    );
    return (res as List? ?? [])
        .map((e) => UpcomingReminder.fromJson(asMap(e)))
        .toList();
  }

  // ------------------------------------------------------- notifications
  Future<PagedList<AppNotification>> notifications({
    int page = 1,
    int size = 30,
    bool unreadOnly = false,
  }) async {
    final res = await _api.get(
      '/calendar/notifications',
      query: {
        'page': page,
        'size': size,
        'unread_only': unreadOnly ? true : null,
      },
    );
    return PagedList.fromJson(res, AppNotification.fromJson);
  }

  Future<int> unreadCount() async {
    final res = await _api.get('/calendar/notifications/count');
    return asInt(asMap(res)['unread']);
  }

  Future<void> markRead(String id) =>
      _api.post('/calendar/notifications/$id/read');

  Future<void> markAllRead() => _api.post('/calendar/notifications/read-all');
}
