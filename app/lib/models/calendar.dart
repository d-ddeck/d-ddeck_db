import 'package:flutter/material.dart';

import 'common.dart';

enum CalendarType {
  personal('PERSONAL', '개인', Icons.person),
  department('DEPARTMENT', '부서', Icons.groups),
  company('COMPANY', '전사', Icons.apartment);

  const CalendarType(this.value, this.label, this.icon);
  final String value;
  final String label;
  final IconData icon;

  static CalendarType parse(String? v) => CalendarType.values
      .firstWhere((t) => t.value == v, orElse: () => CalendarType.personal);
}

enum EventStatus {
  scheduled('SCHEDULED', '예정'),
  canceled('CANCELED', '취소'),
  done('DONE', '완료');

  const EventStatus(this.value, this.label);
  final String value;
  final String label;

  static EventStatus parse(String? v) => EventStatus.values
      .firstWhere((s) => s.value == v, orElse: () => EventStatus.scheduled);
}

enum ParticipantResponse {
  pending('PENDING', '미정', Icons.schedule, Color(0xFF94A3B8)),
  accepted('ACCEPTED', '참석', Icons.check_circle, Color(0xFF10B981)),
  declined('DECLINED', '불참', Icons.cancel, Color(0xFFEF4444)),
  tentative('TENTATIVE', '미정(임시)', Icons.help, Color(0xFFF59E0B));

  const ParticipantResponse(this.value, this.label, this.icon, this.color);
  final String value;
  final String label;
  final IconData icon;
  final Color color;

  static ParticipantResponse parse(String? v) => ParticipantResponse.values
      .firstWhere((r) => r.value == v, orElse: () => ParticipantResponse.pending);
}

class AppCalendar {
  const AppCalendar({
    required this.id,
    required this.name,
    required this.type,
    required this.color,
    this.ownerId,
    this.departmentId,
    this.isShared = false,
    this.isActive = true,
    this.defaultReminderMinutes,
  });

  final String id;
  final String name;
  final CalendarType type;
  final String color;
  final String? ownerId;
  final String? departmentId;
  final bool isShared;
  final bool isActive;
  final int? defaultReminderMinutes;

  Color get displayColor => parseHexColor(color);

  factory AppCalendar.fromJson(Map<String, dynamic> j) => AppCalendar(
        id: asString(j['id']),
        name: asString(j['name']),
        type: CalendarType.parse(j['type'] as String?),
        color: asString(j['color'], '#3B82F6'),
        ownerId: j['owner_id'] as String?,
        departmentId: j['department_id'] as String?,
        isShared: asBool(j['is_shared']),
        isActive: asBool(j['is_active'], true),
        defaultReminderMinutes: j['default_reminder_minutes'] == null
            ? null
            : asInt(j['default_reminder_minutes']),
      );
}

class EventParticipant {
  const EventParticipant({
    required this.id,
    required this.userId,
    required this.response,
    this.user,
    this.isOrganizer = false,
  });

  final String id;
  final String userId;
  final ParticipantResponse response;
  final UserBrief? user;
  final bool isOrganizer;

  factory EventParticipant.fromJson(Map<String, dynamic> j) => EventParticipant(
        id: asString(j['id']),
        userId: asString(j['user_id']),
        response: ParticipantResponse.parse(j['response'] as String?),
        user: j['user'] is Map ? UserBrief.fromJson(asMap(j['user'])) : null,
        isOrganizer: asBool(j['is_organizer']),
      );
}

class EventReminder {
  const EventReminder({
    required this.id,
    required this.offsetMinutes,
    this.method = 'PUSH',
    this.sentAt,
  });

  final String id;
  final int offsetMinutes;
  final String method;
  final DateTime? sentAt;

  String get label => offsetMinutes == 0 ? '시작 시각' : '$offsetMinutes분 전';

  factory EventReminder.fromJson(Map<String, dynamic> j) => EventReminder(
        id: asString(j['id']),
        offsetMinutes: asInt(j['offset_minutes']),
        method: asString(j['method'], 'PUSH'),
        sentAt: asDate(j['sent_at']),
      );
}

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.status,
    this.description,
    this.location,
    this.categoryId,
    this.allDay = false,
    this.color,
    this.isPrivate = false,
    this.createdById,
    this.participants = const [],
    this.reminders = const [],
    this.calendar,
  });

  final String id;
  final String calendarId;
  final String title;
  final DateTime startsAt;
  final DateTime endsAt;
  final EventStatus status;
  final String? description;
  final String? location;
  final String? categoryId;
  final bool allDay;
  final String? color;
  final bool isPrivate;
  final String? createdById;
  final List<EventParticipant> participants;
  final List<EventReminder> reminders;
  final AppCalendar? calendar;

  /// Event colour wins over the calendar's; falls back to a neutral blue.
  Color displayColor([Color? calendarColor]) {
    if (color != null && color!.isNotEmpty) return parseHexColor(color!);
    return calendarColor ?? const Color(0xFF3B82F6);
  }

  /// True when the event covers any part of [day].
  bool occursOn(DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    return startsAt.isBefore(dayEnd) && endsAt.isAfter(dayStart);
  }

  factory CalendarEvent.fromJson(Map<String, dynamic> j) {
    final start = asDate(j['starts_at']) ?? DateTime.now();
    return CalendarEvent(
      id: asString(j['id']),
      calendarId: asString(j['calendar_id']),
      title: asString(j['title']),
      startsAt: start,
      endsAt: asDate(j['ends_at']) ?? start,
      status: EventStatus.parse(j['status'] as String?),
      description: j['description'] as String?,
      location: j['location'] as String?,
      categoryId: j['category_id'] as String?,
      allDay: asBool(j['all_day']),
      color: j['color'] as String?,
      isPrivate: asBool(j['is_private']),
      createdById: j['created_by_id'] as String?,
      participants: asList(j['participants'], EventParticipant.fromJson),
      reminders: asList(j['reminders'], EventReminder.fromJson),
      calendar: j['calendar'] is Map
          ? AppCalendar.fromJson(asMap(j['calendar']))
          : null,
    );
  }
}

/// One alarm the device should schedule locally.
///
/// Comes from GET /calendar/reminders/upcoming. Everything needed to build the
/// notification is here, so the device can ring with no network at all.
class UpcomingReminder {
  const UpcomingReminder({
    required this.reminderId,
    required this.eventId,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.scheduledAt,
    required this.offsetMinutes,
    this.location,
    this.allDay = false,
    this.color,
    this.calendarName,
  });

  final String reminderId;
  final String eventId;
  final String title;
  final DateTime startsAt;
  final DateTime endsAt;

  /// When the alarm should fire, already converted to local time.
  final DateTime scheduledAt;
  final int offsetMinutes;
  final String? location;
  final bool allDay;
  final String? color;
  final String? calendarName;

  /// Stable 32-bit id for the OS scheduler.
  ///
  /// Android notification ids must fit in an int, but reminder ids are UUIDs.
  /// Hashing keeps the mapping stable across app restarts so re-syncing
  /// replaces an existing alarm instead of creating a duplicate.
  int get alarmId => reminderId.hashCode & 0x7FFFFFFF;

  String get body {
    final when = allDay
        ? '오늘'
        : '${startsAt.hour.toString().padLeft(2, '0')}:'
            '${startsAt.minute.toString().padLeft(2, '0')}';
    final lead = offsetMinutes == 0
        ? '지금 시작'
        : offsetMinutes >= 1440
            ? '${offsetMinutes ~/ 1440}일 뒤'
            : offsetMinutes >= 60
                ? '${offsetMinutes ~/ 60}시간 뒤'
                : '$offsetMinutes분 뒤';
    final place = location?.isNotEmpty == true ? ' · $location' : '';
    return '$when 시작 ($lead)$place';
  }

  factory UpcomingReminder.fromJson(Map<String, dynamic> j) {
    final start = asDate(j['starts_at']) ?? DateTime.now();
    return UpcomingReminder(
      reminderId: asString(j['reminder_id']),
      eventId: asString(j['event_id']),
      title: asString(j['title']),
      startsAt: start,
      endsAt: asDate(j['ends_at']) ?? start,
      scheduledAt: asDate(j['scheduled_at']) ?? start,
      offsetMinutes: asInt(j['offset_minutes']),
      location: j['location'] as String?,
      allDay: asBool(j['all_day']),
      color: j['color'] as String?,
      calendarName: j['calendar_name'] as String?,
    );
  }
}

/// Parses "#RRGGBB" / "#AARRGGBB"; falls back to blue on anything unexpected
/// so a bad value in the code master cannot crash a screen.
Color parseHexColor(String hex, [Color fallback = const Color(0xFF3B82F6)]) {
  var value = hex.trim().replaceFirst('#', '');
  if (value.length == 6) value = 'FF$value';
  if (value.length != 8) return fallback;
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? fallback : Color(parsed);
}

/// A calendar date; do not shift a holiday through UTC/local time conversion.
class Holiday {
  const Holiday({required this.date, required this.name});
  final DateTime date;
  final String name;

  factory Holiday.fromJson(Map<String, dynamic> j) => Holiday(
    date: DateTime.parse(asString(j['date'])),
    name: asString(j['name']),
  );
}
