import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/calendar_repository.dart';
import '../../models/common.dart' show CodeItem;
import '../../models/calendar.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';
import 'event_detail_sheet.dart';
import 'event_form_page.dart';

export 'event_form_page.dart' show EventFormPage;

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);
DateTime _dayAfter(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

class _WeekSegment {
  const _WeekSegment(this.event, this.start, this.end, this.lane,
      this.continuesLeft, this.continuesRight);
  final CalendarEvent event;
  final int start, end, lane;
  final bool continuesLeft, continuesRight;
}

class _WeekData {
  _WeekData(this.days, this.segments, this.lanesByDay);
  final List<DateTime> days;
  final List<_WeekSegment> segments;
  // Sorted lane indices let each day count hidden events without scanning events.
  final List<List<int>> lanesByDay;
}

class _MonthData {
  _MonthData({required DateTime month, required List<AppCalendar> calendars,
    required List<CalendarEvent> events, required List<Holiday> holidays,
    required List<CodeItem> categories}) {
    calendarColors = {for (final c in calendars) c.id: c.color};
    categoryColors = {for (final c in categories)
      if (c.color?.trim().isNotEmpty == true) c.id: c.color!};
    for (final holiday in holidays) {
      final day = _dateOnly(holiday.date);
      holidayNames.update(day, (name) => '$name · ${holiday.name}',
          ifAbsent: () => holiday.name);
    }
    final first = DateTime(month.year, month.month);
    final start = _dayAfter(first, 1 - first.weekday);
    final count = ((first.weekday - 1 + DateTime(month.year, month.month + 1, 0).day) / 7).ceil();
    final sorted = List<CalendarEvent>.of(events)..sort((a, b) {
      final byDate = _dateOnly(a.startsAt).compareTo(_dateOnly(b.startsAt));
      if (byDate != 0) return byDate;
      final byDuration = b.endsAt.difference(b.startsAt).compareTo(a.endsAt.difference(a.startsAt));
      if (byDuration != 0) return byDuration;
      final byTime = a.startsAt.compareTo(b.startsAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    for (var week = 0; week < count; week++) {
      final days = List.generate(7, (day) => _dayAfter(start, week * 7 + day));
      final occupied = <int>[];
      final segments = <_WeekSegment>[];
      final lanesByDay = List.generate(7, (_) => <int>[]);
      for (final event in sorted) {
        final covered = <int>[for (var day = 0; day < 7; day++)
          if (event.occursOn(days[day])) day];
        if (covered.isEmpty) continue;
        final from = covered.first, to = covered.last;
        final mask = ((1 << (to - from + 1)) - 1) << from;
        var lane = 0;
        while (lane < occupied.length && (occupied[lane] & mask) != 0) {
          lane++;
        }
        if (lane == occupied.length) occupied.add(0);
        occupied[lane] |= mask;
        segments.add(_WeekSegment(event, from, to, lane,
            event.startsAt.isBefore(days.first),
            event.endsAt.isAfter(_dayAfter(days.last, 1))));
        for (final day in covered) {
          lanesByDay[day].add(lane);
          eventsByDay.putIfAbsent(days[day], () => []).add(event);
        }
      }
      for (final lanes in lanesByDay) { lanes.sort(); }
      weeks.add(_WeekData(days, segments, lanesByDay));
    }
    for (final events in eventsByDay.values) {
      events.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    }
  }

  late final Map<String, String> calendarColors, categoryColors;
  final Map<DateTime, String> holidayNames = {};
  final Map<DateTime, List<CalendarEvent>> eventsByDay = {};
  final List<_WeekData> weeks = [];

  Color colorFor(CalendarEvent event, Color primary) {
    if (event.status == EventStatus.canceled) return Colors.grey;
    var color = primary;
    for (final value in [categoryColors[event.categoryId], event.calendar?.color,
      calendarColors[event.calendarId], event.color]) {
      if (value?.trim().isNotEmpty == true) color = parseHexColor(value!, color);
    }
    return color;
  }
}

/// 캘린더. A month grid plus the selected day's list.
///
/// The server returns every event overlapping the window, so a multi-day event
/// correctly appears on each day it covers.
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final _viewKey = GlobalKey<AsyncViewState<_MonthData>>();

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _selected = DateTime.now();
  final Map<int, List<Holiday>> _holidays = {};

  Future<List<Holiday>> _loadHolidays(CalendarRepository repo, int year) async {
    return _holidays[year] ??= await repo.holidays(year);
  }

  DateTime get _windowStart =>
      DateTime(_month.year, _month.month, 1).subtract(const Duration(days: 7));
  DateTime get _windowEnd =>
      DateTime(_month.year, _month.month + 1, 1).add(const Duration(days: 7));

  void _refresh() => _viewKey.currentState?.reload();

  void _shiftMonth(int delta) => setState(() {
        _month = DateTime(_month.year, _month.month + delta);
        _refresh();
      });

  Future<void> _createEvent(DateTime date) async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EventFormPage(initialDate: date)),
    );
    if (mounted && created == true) _refresh();
  }

  void _showDay(BuildContext hostContext, DateTime date, _MonthData data) {
    setState(() => _selected = date);
    showModalBottomSheet<void>(context: context, isScrollControlled: true,
      builder: (context) => SafeArea(child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: Column(children: [
          Padding(padding: const EdgeInsets.all(AppSpace.lg),
            child: Text('${date.month}월 ${date.day}일 일정',
              style: Theme.of(context).textTheme.titleMedium)),
          Expanded(child: ListView(children: [
            for (final event in data.eventsByDay[_dateOnly(date)] ?? <CalendarEvent>[])
              _EventTile(event: event,
                calendarColor: data.colorFor(event, Theme.of(context).colorScheme.primary),
                onChanged: _refresh,
                onTap: () {
                  Navigator.of(context).pop();
                  EventDetailSheet.show(hostContext, event, onChanged: _refresh);
                }),
          ])),
        ]),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<CalendarRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('캘린더'), actions: [FilledButton.icon(
        onPressed: () => _createEvent(_selected), icon: const Icon(Icons.add), label: const Text('일정 등록'))]),
      body: PageBody(child: AsyncView<_MonthData>(
        key: _viewKey,
        load: () async {
          try {
            final month = _month;
            final results = await Future.wait([
              repo.calendars(),
              repo.events(from: _windowStart, to: _windowEnd),
              context.read<AdminRepository>().codeGroup('EVENT_CATEGORY')
                  .then((group) => group.items),
              for (var y = _windowStart.year; y <= _windowEnd.year; y++)
                if (y >= 2000 && y <= 2100) _loadHolidays(repo, y),
            ]);
            return _MonthData(
              month: month,
              categories: results[2] as List<CodeItem>,
              calendars: results[0] as List<AppCalendar>,
              events: results[1] as List<CalendarEvent>,
              holidays: results.skip(3).expand((v) => (v as List<Holiday>)).toList(),
            );
          } on ApiException catch (e) {
            if (context.mounted) AppSnack.show(context, e.message, error: true);
            rethrow;
          }
        },
        builder: (context, data, reload) {
          final dayEvents = data.eventsByDay[_dateOnly(_selected)] ?? <CalendarEvent>[];
          return LayoutBuilder(builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 600;
            final minHeight = desktop ? 124.0 : 80.0;
            final rowHeight = ((constraints.maxHeight - 230) / data.weeks.length)
                .clamp(minHeight, double.infinity).toDouble();
            final calendar = Column(children: [
              _MonthHeader(
                month: _month,
                onPrev: () => _shiftMonth(-1),
                onNext: () => _shiftMonth(1),
                onToday: () => setState(() {
                  final now = DateTime.now();
                  _month = DateTime(now.year, now.month);
                  _selected = now;
                  _refresh();
                }),
              ),
              _MonthGrid(
                month: _month,
                selected: _selected,
                data: data,
                rowHeight: rowHeight,
                desktop: desktop,
                onChanged: _refresh,
                onCreate: _createEvent,
                onOverflow: (date) => _showDay(context, date, data),
                onSelect: (d) => setState(() => _selected = d),
              ),
              const Divider(height: 1),
            ]);
            final dayList = dayEvents.isEmpty
                    ? StatePlaceholder(
                        icon: Icons.event_available,
                        message: '아직 등록된 일정이 없습니다',
                      )
                    : ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                        itemCount: dayEvents.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) => _EventTile(
                          event: dayEvents[i],
                          calendarColor: data.colorFor(dayEvents[i], Theme.of(context).colorScheme.primary),
                          onChanged: _refresh,
                        ),
                      );
            if (constraints.maxHeight < 90 + minHeight * data.weeks.length) {
              return ListView(children: [calendar, dayList]);
            }
            return Column(children: [calendar,
              Expanded(child: SingleChildScrollView(child: dayList)),
            ]);
          });
        },
      )),

    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  final DateTime month;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          IconButton(
              onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
          Expanded(
            child: Text(
              '${month.year}년 ${month.month}월',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
              onPressed: onNext, icon: const Icon(Icons.chevron_right)),
          TextButton(onPressed: onToday, child: const Text('오늘')),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.month, required this.selected,
    required this.data, required this.rowHeight, required this.desktop,
    required this.onSelect, required this.onCreate, required this.onOverflow,
    required this.onChanged});

  final DateTime month, selected;
  final _MonthData data;
  final double rowHeight;
  final bool desktop;
  final ValueChanged<DateTime> onSelect, onCreate, onOverflow;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = _dateOnly(DateTime.now());
    final fontSize = desktop ? 12.0 : 11.0;
    final textHeight = MediaQuery.textScalerOf(context).scale(fontSize);
    final laneHeight = (textHeight + 5).clamp(18.0, double.infinity).toDouble();
    const headerHeight = 26.0;
    final overflowHeight = (textHeight + 4).clamp(18.0, double.infinity).toDouble();
    final visibleLanes = ((rowHeight - headerHeight - overflowHeight) / laneHeight)
        .floor().clamp(0, desktop ? 5 : 3).toInt();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: Column(children: [
        SizedBox(height: 22, child: Row(children: [
          for (final (i, label) in ['월', '화', '수', '목', '금', '토', '일'].indexed)
            Expanded(child: Center(child: Text(label,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                color: i == 5 ? AppColors.info(context)
                    : i == 6 ? AppColors.danger(context) : scheme.outline)))),
        ])),
        for (final week in data.weeks)
          SizedBox(height: rowHeight, child: LayoutBuilder(builder: (context, constraints) {
            final cellWidth = constraints.maxWidth / 7;
            return Stack(children: [
              Positioned.fill(child: Row(children: [
                for (final date in week.days)
                  Expanded(child: _DayCell(date: date, month: month,
                    selected: selected, today: today,
                    holiday: data.holidayNames[date] ?? '',
                    onTap: onSelect, onLongPress: onCreate)),
              ])),
              for (final segment in week.segments)
                if (segment.lane < visibleLanes)
                  Positioned(
                    left: segment.start * cellWidth + 1,
                    width: (segment.end - segment.start + 1) * cellWidth - 2,
                    top: headerHeight + segment.lane * laneHeight,
                    height: laneHeight - 2,
                    child: _EventBar(segment: segment, fontSize: fontSize,
                      color: data.colorFor(segment.event, scheme.primary),
                      onTap: () => EventDetailSheet.show(context, segment.event,
                        onChanged: onChanged),
                      onLongPress: (offset) {
                        final day = (segment.start + (offset / cellWidth).floor())
                            .clamp(segment.start, segment.end).toInt();
                        onCreate(week.days[day]);
                      }),
                  ),
              for (var day = 0; day < 7; day++)
                if (week.lanesByDay[day].any((lane) => lane >= visibleLanes))
                  Positioned(left: day * cellWidth, width: cellWidth,
                    bottom: 0, height: overflowHeight,
                    child: InkWell(onTap: () => onOverflow(week.days[day]),
                      onLongPress: () => onCreate(week.days[day]),
                      child: Center(child: Text(
                        '+${week.lanesByDay[day].where((lane) => lane >= visibleLanes).length}',
                        style: TextStyle(fontSize: fontSize, color: scheme.onSurfaceVariant))),
                    )),
            ]);
          })),
        const SizedBox(height: AppSpace.xs),
      ]),
    );
  }
}

class _EventBar extends StatelessWidget {
  const _EventBar({required this.segment, required this.color,
    required this.fontSize, required this.onTap, required this.onLongPress});
  final _WeekSegment segment;
  final Color color;
  final double fontSize;
  final VoidCallback onTap;
  final ValueChanged<double> onLongPress;

  @override
  Widget build(BuildContext context) {
    final event = segment.event;
    final lastDay = _dateOnly(event.endsAt.subtract(const Duration(microseconds: 1)));
    final solid = event.allDay || lastDay.isAfter(_dateOnly(event.startsAt));
    final surface = Theme.of(context).colorScheme.surface;
    final background = Color.alphaBlend(solid ? color : color.withValues(alpha: 0.16), surface);
    final foreground = background.computeLuminance() > 0.179 ? Colors.black : Colors.white;
    final title = solid ? event.title
        : '${event.startsAt.hour.toString().padLeft(2, '0')}:'
          '${event.startsAt.minute.toString().padLeft(2, '0')} ${event.title}';
    final radius = BorderRadius.horizontal(
      left: Radius.circular(segment.continuesLeft ? 0 : 6),
      right: Radius.circular(segment.continuesRight ? 0 : 6));
    return Semantics(button: true, label: title,
      child: Tooltip(message: title, child: GestureDetector(
        onLongPressStart: (details) => onLongPress(details.localPosition.dx),
        child: Material(color: background, borderRadius: radius,
          child: InkWell(onTap: onTap, borderRadius: radius,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Align(alignment: Alignment.centerLeft,
                child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fontSize, height: 1, color: foreground,
                    decoration: event.status == EventStatus.canceled
                        ? TextDecoration.lineThrough : null,
                    decorationColor: foreground)),
              ),
            ),
          ),
        ),
      )),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.date, required this.month,
    required this.selected, required this.today, required this.holiday,
    required this.onTap, required this.onLongPress});
  final DateTime date, month, selected, today;
  final String holiday;
  final ValueChanged<DateTime> onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = date == _dateOnly(selected);
    final isToday = date == today;
    final color = holiday.isNotEmpty ? AppColors.danger(context)
        : date.month != month.month ? scheme.onSurfaceVariant
        : date.weekday == 6 ? AppColors.info(context)
        : date.weekday == 7 ? AppColors.danger(context) : scheme.onSurface;
    return InkWell(onTap: () => onTap(date),
      onLongPress: () => onLongPress(date),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: isSelected ? scheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: isToday ? Border.all(color: scheme.primary, width: 1.2) : null),
        alignment: Alignment.topLeft,
        child: SizedBox(height: 24, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(children: [
            Text('${date.day}', style: TextStyle(fontSize: 12, color: color,
              fontWeight: isToday ? FontWeight.w700 : FontWeight.w400)),
            if (holiday.isNotEmpty) Expanded(child: Tooltip(message: holiday,
              child: Text(' $holiday', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 8, color: AppColors.danger(context))))),
          ]),
        )),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.calendarColor,
    required this.onChanged,
    this.onTap,
  });

  final CalendarEvent event;
  final Color? calendarColor;
  final VoidCallback onChanged;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthState>();
    final me = event.participants
        .where((p) => p.userId == auth.user?.id)
        .firstOrNull;

    return ListTile(
      leading: Container(
        width: 4,
        height: 38,
        decoration: BoxDecoration(
          color: calendarColor ?? event.displayColor(),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      title: Text(
        event.title,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
          color: event.status == EventStatus.canceled ? Theme.of(context).colorScheme.onSurfaceVariant : null,
          decoration: event.status == EventStatus.canceled ? TextDecoration.lineThrough : null),
      ),
      subtitle: Text(
        '${Fmt.range(event.startsAt, event.endsAt, allDay: event.allDay)}'
        '${event.location != null ? ' · ${event.location}' : ''}',
        style: TextStyle(
            fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      trailing: me == null
          ? const Icon(Icons.chevron_right)
          : PopupMenuButton<ParticipantResponse>(
              tooltip: '참석 응답',
              child: StatusChip(
                label: me.response.label,
                color: me.response.color,
                icon: me.response.icon,
                dense: true,
              ),
              itemBuilder: (_) => [
                for (final r in ParticipantResponse.values)
                  if (r != ParticipantResponse.pending)
                    PopupMenuItem(value: r, child: Text(r.label)),
              ],
              onSelected: (r) async {
                final ok = await runGuarded(
                  context,
                  () => context
                      .read<CalendarRepository>()
                      .respond(event.id, r),
                  successMessage: '${r.label}(으)로 응답했습니다.',
                );
                if (ok) onChanged();
              },
            ),
      onTap: onTap ?? () => EventDetailSheet.show(context, event, onChanged: onChanged),
    );
  }
}
