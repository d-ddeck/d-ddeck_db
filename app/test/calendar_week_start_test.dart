import 'package:ddeck_app/models/calendar.dart';
import 'package:ddeck_app/ui/calendar/calendar_month_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resize preserves clock time and exclusive all-day end', () {
    final timed = CalendarEvent(
      id: 'e',
      calendarId: 'c',
      title: '일정',
      startsAt: DateTime(2026, 9, 10, 9),
      endsAt: DateTime(2026, 9, 10, 18),
      status: EventStatus.scheduled,
    );
    expect(
      resizedCalendarRange(timed, DateTime(2026, 9, 12), start: false)!.end,
      DateTime(2026, 9, 12, 18),
    );
    expect(
      resizedCalendarRange(timed, DateTime(2026, 9, 9), start: true)!.start,
      DateTime(2026, 9, 9, 9),
    );
    expect(
      resizedCalendarRange(timed, DateTime(2026, 9, 11), start: true),
      isNull,
    );
    final allDay = CalendarEvent(
      id: 'a',
      calendarId: 'c',
      title: '종일',
      allDay: true,
      startsAt: DateTime(2026, 9, 10),
      endsAt: DateTime(2026, 9, 13),
      status: EventStatus.scheduled,
    );
    expect(
      resizedCalendarRange(allDay, DateTime(2026, 9, 10), start: false)!.end,
      DateTime(2026, 9, 11),
    );
    expect(
      resizedCalendarRange(allDay, DateTime(2026, 9, 15), start: false)!.end,
      DateTime(2026, 9, 16),
    );
  });

  test('every month starts on Sunday and contains all dates', () {
    for (final year in [2024, 2026, 2027]) {
      for (var month = 1; month <= 12; month++) {
        final data = CalendarMonthData(
          month: DateTime(year, month),
          categories: [],
          calendars: [],
          events: [],
          holidays: [],
        );
        final dates = data.weeks.expand((week) => week.days).toList();
        expect(dates.first.weekday, DateTime.sunday);
        expect(dates.last.weekday, DateTime.saturday);
        expect(dates.toSet().length, dates.length);
        expect(
          dates
              .where((date) => date.year == year && date.month == month)
              .length,
          DateTime(year, month + 1, 0).day,
        );
        for (var i = 1; i < dates.length; i++) {
          expect(
            dates[i],
            DateTime(
              dates[i - 1].year,
              dates[i - 1].month,
              dates[i - 1].day + 1,
            ),
          );
        }
      }
    }
  });
}
