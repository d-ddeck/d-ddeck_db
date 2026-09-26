import 'package:ddeck_app/ui/calendar/calendar_month_data.dart';
import 'package:ddeck_app/models/service_filter.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ddeck_app/models/inventory.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/models/calendar.dart';
import 'package:ddeck_app/services/filter_memory.dart';
import 'package:ddeck_app/services/upload_image.dart';

void main() {
  test(
    'month lanes separate overlapping events and end midnight is exclusive',
    () {
      CalendarEvent event(String id, String start, String end) =>
          CalendarEvent.fromJson({
            'id': id,
            'calendar_id': 'one',
            'title': id,
            'starts_at': start,
            'ends_at': end,
            'all_day': true,
          });
      final data = CalendarMonthData(
        month: DateTime(2026, 9),
        calendars: [],
        holidays: [],
        categories: [],
        events: [
          event('long', '2026-09-07T00:00:00', '2026-09-10T00:00:00'),
          event('overlap', '2026-09-08T00:00:00', '2026-09-09T00:00:00'),
          event('after', '2026-09-10T00:00:00', '2026-09-11T00:00:00'),
        ],
      );
      final segments = data.weeks.expand((week) => week.segments).toList();
      expect(segments.firstWhere((s) => s.event.id == 'long').lane, 0);
      expect(segments.firstWhere((s) => s.event.id == 'overlap').lane, 1);
      expect(segments.firstWhere((s) => s.event.id == 'after').lane, 0);
      expect(data.eventsByDay[DateTime(2026, 9, 10)]!.map((e) => e.id), [
        'after',
      ]);
    },
  );
  test(
    'shared service criteria preserve false values and explicit overrides',
    () {
      final filter = ServiceFilter(
        year: 2026,
        isRental: false,
        status: ServiceStatus.unknown,
      );
      final query = filter.toQuery({'year': 2025, 'store_id': 'store'});
      expect(query['year'], 2025);
      expect(query['is_rental'], false);
      expect(query['store_id'], 'store');
      expect(query.containsKey('date_from'), false);
    },
  );

  test('unknown server enums never become actionable known states', () {
    expect(AssetStatus.parse('NEW_STATE'), AssetStatus.unknown);
    expect(ServiceStatus.parse('NEW_STATE').isOpen, false);
    expect(ServiceStatus.parse('NEW_STATE').nextOptions, isEmpty);
    expect(UserStatus.parse('NEW_STATE'), UserStatus.unknown);
  });
  test('filter preferences are isolated by account and server', () async {
    SharedPreferences.setMockInitialValues({});
    final key = FilterMemory.key('https://one', 'alice', 'service');
    await FilterMemory.save(key, {'q': 'serial', 'year': 2026});
    expect((await FilterMemory.load(key))['year'], 2026);
    expect(
      await FilterMemory.load(
        FilterMemory.key('https://one', 'bob', 'service'),
      ),
      isEmpty,
    );
    expect(
      await FilterMemory.load(
        FilterMemory.key('https://two', 'alice', 'service'),
      ),
      isEmpty,
    );
  });
  test('recurrence metadata survives model parsing', () {
    final event = CalendarEvent.fromJson({
      'id': 'event',
      'calendar_id': 'calendar',
      'title': 'weekly',
      'starts_at': '2026-09-26T01:00:00Z',
      'ends_at': '2026-09-26T02:00:00Z',
      'rrule': 'FREQ=WEEKLY',
      'recurrence_end': '2026-12-31T00:00:00Z',
      'recurrence_parent_id': 'parent',
    });
    expect(event.rrule, 'FREQ=WEEKLY');
    expect(event.recurrenceParentId, 'parent');
    expect(event.recurrenceEnd?.year, 2026);
  });
  test('large upload image is resized and small image remains untouched', () {
    final folder = Directory.systemTemp.createTempSync('ddeck-image-test-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}/photo.jpg');
    file.writeAsBytesSync(img.encodeJpg(img.Image(width: 2000, height: 1000)));
    final Uint8List? result = resizeUploadImage(file.path);
    final decoded = img.decodeJpg(result!);
    expect(decoded!.width, 1600);
    expect(decoded.height, 800);
    file.writeAsBytesSync(img.encodeJpg(img.Image(width: 200, height: 100)));
    expect(resizeUploadImage(file.path), isNull);
  });
}
