import 'package:flutter/material.dart';
import '../../models/calendar.dart';
import '../../models/common.dart';

DateTime calendarDateOnly(DateTime date) =>
    DateTime(date.year, date.month, date.day);
DateTime calendarDayAfter(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

class CalendarWeekSegment {
  const CalendarWeekSegment(
    this.event,
    this.start,
    this.end,
    this.lane,
    this.continuesLeft,
    this.continuesRight,
  );
  final CalendarEvent event;
  final int start, end, lane;
  final bool continuesLeft, continuesRight;
}

class CalendarWeekData {
  CalendarWeekData(this.days, this.segments, this.lanesByDay);
  final List<DateTime> days;
  final List<CalendarWeekSegment> segments;
  // Sorted lane indices let each day count hidden events without scanning events.
  final List<List<int>> lanesByDay;
}

class CalendarMonthData {
  CalendarMonthData({
    required DateTime month,
    required List<AppCalendar> calendars,
    required List<CalendarEvent> events,
    required List<Holiday> holidays,
    required List<CodeItem> categories,
  }) {
    this.categories = categories;
    calendarColors = {for (final c in calendars) c.id: c.color};
    categoryColors = {
      for (final c in categories)
        if (c.color?.trim().isNotEmpty == true) c.id: c.color!,
    };
    for (final holiday in holidays) {
      final day = calendarDateOnly(holiday.date);
      holidayNames.update(
        day,
        (name) => '$name · ${holiday.name}',
        ifAbsent: () => holiday.name,
      );
    }
    final first = DateTime(month.year, month.month);
    final start = calendarDayAfter(first, 1 - first.weekday);
    final count =
        ((first.weekday - 1 + DateTime(month.year, month.month + 1, 0).day) / 7)
            .ceil();
    final sorted = List<CalendarEvent>.of(events)
      ..sort((a, b) {
        final byDate = calendarDateOnly(
          a.startsAt,
        ).compareTo(calendarDateOnly(b.startsAt));
        if (byDate != 0) return byDate;
        final byDuration = b.endsAt
            .difference(b.startsAt)
            .compareTo(a.endsAt.difference(a.startsAt));
        if (byDuration != 0) return byDuration;
        final byTime = a.startsAt.compareTo(b.startsAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    for (var week = 0; week < count; week++) {
      final days = List.generate(
        7,
        (day) => calendarDayAfter(start, week * 7 + day),
      );
      final occupied = <int>[];
      final segments = <CalendarWeekSegment>[];
      final lanesByDay = List.generate(7, (_) => <int>[]);
      for (final event in sorted) {
        final covered = <int>[
          for (var day = 0; day < 7; day++)
            if (event.occursOn(days[day])) day,
        ];
        if (covered.isEmpty) continue;
        final from = covered.first, to = covered.last;
        final mask = ((1 << (to - from + 1)) - 1) << from;
        var lane = 0;
        while (lane < occupied.length && (occupied[lane] & mask) != 0) {
          lane++;
        }
        if (lane == occupied.length) occupied.add(0);
        occupied[lane] |= mask;
        segments.add(
          CalendarWeekSegment(
            event,
            from,
            to,
            lane,
            event.startsAt.isBefore(days.first),
            event.endsAt.isAfter(calendarDayAfter(days.last, 1)),
          ),
        );
        for (final day in covered) {
          lanesByDay[day].add(lane);
          eventsByDay.putIfAbsent(days[day], () => []).add(event);
        }
      }
      for (final lanes in lanesByDay) {
        lanes.sort();
      }
      weeks.add(CalendarWeekData(days, segments, lanesByDay));
    }
    for (final events in eventsByDay.values) {
      events.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    }
  }

  late final List<CodeItem> categories;
  late final Map<String, String> calendarColors, categoryColors;
  final Map<DateTime, String> holidayNames = {};
  final Map<DateTime, List<CalendarEvent>> eventsByDay = {};
  final List<CalendarWeekData> weeks = [];

  Color colorFor(CalendarEvent event, Color primary) {
    if (event.status == EventStatus.canceled) return Colors.grey;
    var color = primary;
    for (final value in [
      categoryColors[event.categoryId],
      event.calendar?.color,
      calendarColors[event.calendarId],
      event.color,
    ]) {
      if (value?.trim().isNotEmpty == true) {
        color = parseHexColor(value!, color);
      }
    }
    return color;
  }
}
