import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/auth_repository.dart';
import '../../data/calendar_repository.dart';
import '../../models/calendar.dart';
import '../../models/common.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';

class _MonthData {
  const _MonthData({required this.calendars, required this.events, required this.holidays});
  final List<AppCalendar> calendars;
  final List<CalendarEvent> events;
  final List<Holiday> holidays;
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

  @override
  Widget build(BuildContext context) {
    final repo = context.read<CalendarRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('캘린더'), actions: [FilledButton.icon(
        onPressed: () async {
          final created = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => EventFormPage(initialDate: _selected),
            ),
          );
          if (created == true) _refresh();
        }, icon: const Icon(Icons.add), label: const Text('일정 등록'))]),
      body: PageBody(child: AsyncView<_MonthData>(
        key: _viewKey,
        load: () async {
          try {
            final results = await Future.wait([
              repo.calendars(),
              repo.events(from: _windowStart, to: _windowEnd),
              for (var y = _windowStart.year; y <= _windowEnd.year; y++)
                if (y >= 2000 && y <= 2100) _loadHolidays(repo, y),
            ]);
            return _MonthData(
              calendars: results[0] as List<AppCalendar>,
              events: results[1] as List<CalendarEvent>,
              holidays: results.skip(2).expand((v) => (v as List<Holiday>)).toList(),
            );
          } on ApiException catch (e) {
            if (context.mounted) AppSnack.show(context, e.message, error: true);
            rethrow;
          }
        },
        builder: (context, data, reload) {
          final colorsById = {
            for (final c in data.calendars) c.id: c.displayColor
          };
          final dayEvents = data.events
              .where((e) => e.occursOn(_selected))
              .toList()
            ..sort((a, b) => a.startsAt.compareTo(b.startsAt));

          return ListView(
            children: [
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
                events: data.events,
                holidays: data.holidays,
                colorsById: colorsById,
                onSelect: (d) => setState(() => _selected = d),
              ),
              const Divider(height: 1),
              dayEvents.isEmpty
                    ? StatePlaceholder(
                        icon: Icons.event_available,
                        message: '아직 등록된 일정이 없습니다',
                      )
                    : ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                        itemCount: dayEvents.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) => _EventTile(
                          event: dayEvents[i],
                          calendarColor: colorsById[dayEvents[i].calendarId],
                          onChanged: reload,
                        ),
                      ),
            ],
          );
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
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.events,
    required this.holidays,
    required this.colorsById,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime selected;
  final List<CalendarEvent> events;
  final List<Holiday> holidays;
  final Map<String, Color> colorsById;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month, 1);
    // Monday-first grid: weekday is 1..7 with Monday == 1.
    final leading = first.weekday - 1;
    final gridStart = first.subtract(Duration(days: leading));
    final today = DateTime.now();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          Row(
            children: [
              for (final (i, label) in ['월', '화', '수', '목', '금', '토', '일']
                  .indexed)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: switch (i) {
                          5 => AppColors.info(context),
                          6 => AppColors.danger(context),
                          _ => scheme.outline,
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (var week = 0; week < 6; week++)
            Row(
              children: [
                for (var day = 0; day < 7; day++)
                  Expanded(
                    child: _DayCell(
                      date: gridStart.add(Duration(days: week * 7 + day)),
                      month: month,
                      selected: selected,
                      today: today,
                      events: events,
                      holidays: holidays,
                      colorsById: colorsById,
                      onTap: onSelect,
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.month,
    required this.selected,
    required this.today,
    required this.events,
    required this.holidays,
    required this.colorsById,
    required this.onTap,
  });

  final DateTime date;
  final DateTime month;
  final DateTime selected;
  final DateTime today;
  final List<CalendarEvent> events;
  final List<Holiday> holidays;
  final Map<String, Color> colorsById;
  final ValueChanged<DateTime> onTap;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inMonth = date.month == month.month;
    final isSelected = _sameDay(date, selected);
    final isToday = _sameDay(date, today);
    final holiday = holidays.where((h) => _sameDay(h.date, date)).map((h) => h.name).join(' · ');
    final dayEvents = events.where((e) => e.occursOn(date)).toList();

    return InkWell(
      onTap: () => onTap(date),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52, minWidth: 44),
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: isSelected ? scheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: isToday && !isSelected
              ? Border.all(color: scheme.primary, width: 1.2)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                color: holiday.isNotEmpty ? AppColors.danger(context) : !inMonth
                    ? scheme.onSurfaceVariant
                    : switch (date.weekday) {
                        6 => AppColors.info(context),
                        7 => AppColors.danger(context),
                        _ => null,
                      },
              ),
            ),
            if (holiday.isNotEmpty) Tooltip(message: holiday, child: Text(holiday,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 8, color: AppColors.danger(context)))),
            const SizedBox(height: 3),
            // Up to three dots, then a "+N" marker, so a busy day stays legible.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final e in dayEvents.take(3))
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: e.displayColor(colorsById[e.calendarId]),
                      shape: BoxShape.circle,
                    ),
                  ),
                if (dayEvents.length > 3)
                  Text(
                    '+${dayEvents.length - 3}',
                    style: TextStyle(fontSize: 8, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.calendarColor,
    required this.onChanged,
  });

  final CalendarEvent event;
  final Color? calendarColor;
  final VoidCallback onChanged;

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
          color: event.displayColor(calendarColor),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      title: Text(
        event.title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => _EventSheet(event: event),
      ),
    );
  }
}

class _EventSheet extends StatelessWidget {
  const _EventSheet({required this.event});
  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SectionCard(title: '일정 정보', child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              event.title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _row(context, Icons.schedule,
                Fmt.range(event.startsAt, event.endsAt, allDay: event.allDay)),
            if (event.location != null)
              _row(context, Icons.place_outlined, event.location!),
            if (event.description != null)
              _row(context, Icons.notes, event.description!),
            if (event.reminders.isNotEmpty)
              _row(
                context,
                Icons.notifications_outlined,
                event.reminders.map((r) => r.label).join(', '),
              ),
            const FormGap(),
            Text('참석자 ${Fmt.number(event.participants.length)}명',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in event.participants)
                  StatusChip(
                    label:
                        '${p.user?.fullName ?? '?'}${p.isOrganizer ? ' (주최)' : ''}',
                    color: p.response.color,
                    icon: p.response.icon,
                    dense: true,
                  ),
              ],
            ),
          ],
        )),
      )),
    );
  }

  Widget _row(BuildContext context, IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

class EventFormPage extends StatefulWidget {
  const EventFormPage({super.key, required this.initialDate});
  final DateTime initialDate;

  @override
  State<EventFormPage> createState() => _EventFormPageState();
}

class _EventFormPageState extends State<EventFormPage> {
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _description = TextEditingController();

  String? _calendarId;
  late DateTime _start;
  late DateTime _end;
  bool _allDay = false;
  int _reminderMinutes = 30;
  final Set<String> _participants = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDate;
    _start = DateTime(d.year, d.month, d.day, 9);
    _end = _start.add(const Duration(hours: 1));
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calendarRepo = context.read<CalendarRepository>();
    final authRepo = context.read<AuthRepository>();

    return Scaffold(
      appBar: AppBar(title: const Text('일정 등록')),
      body: PageBody(child: AsyncView<(List<AppCalendar>, List<UserBrief>)>(
        load: () async {
          final results = await Future.wait([
            calendarRepo.calendars(),
            authRepo.directory(size: 100),
          ]);
          return (
            results[0] as List<AppCalendar>,
            (results[1] as PagedList<UserBrief>).items,
          );
        },
        builder: (context, data, reload) {
          final (calendars, members) = data;
          _calendarId ??= calendars.isNotEmpty ? calendars.first.id : null;

          return Column(children: [Expanded(child: ListView(
            padding: EdgeInsets.zero,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: '제목 *'),
              ),
              const FormGap(),
              DropdownButtonFormField<String>(
                initialValue: _calendarId,
                decoration: const InputDecoration(labelText: '캘린더 *'),
                isExpanded: true,
                items: [
                  for (final c in calendars)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: c.displayColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${c.name} (${c.type.label})'),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _calendarId = v),
              ),
              const FormGap(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('종일', style: TextStyle(fontSize: 14)),
                value: _allDay,
                onChanged: (v) => setState(() => _allDay = v),
              ),
              _DateTimeRow(
                label: '시작',
                value: _start,
                allDay: _allDay,
                onChanged: (d) => setState(() {
                  _start = d;
                  if (_end.isBefore(_start)) {
                    _end = _start.add(const Duration(hours: 1));
                  }
                }),
              ),
              _DateTimeRow(
                label: '종료',
                value: _end,
                allDay: _allDay,
                onChanged: (d) => setState(() => _end = d),
              ),
              const FormGap(),
              TextField(
                controller: _location,
                decoration: const InputDecoration(labelText: '장소'),
              ),
              const FormGap(),
              DropdownButtonFormField<int>(
                initialValue: _reminderMinutes,
                decoration: const InputDecoration(labelText: '알림'),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('시작 시각')),
                  DropdownMenuItem(value: 10, child: Text('10분 전')),
                  DropdownMenuItem(value: 30, child: Text('30분 전')),
                  DropdownMenuItem(value: 60, child: Text('1시간 전')),
                  DropdownMenuItem(value: 1440, child: Text('1일 전')),
                ],
                onChanged: (v) =>
                    setState(() => _reminderMinutes = v ?? _reminderMinutes),
              ),
              const SizedBox(height: 16),
              const Text('참석자',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in members)
                    FilterChip(
                      label: Text(m.fullName,
                          style: const TextStyle(fontSize: 12)),
                      selected: _participants.contains(m.id),
                      onSelected: (v) => setState(() {
                        v ? _participants.add(m.id) : _participants.remove(m.id);
                      }),
                    ),
                ],
              ),
              const FormGap(),
              TextField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: '설명',
                  alignLabelWithHint: true,
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 20),

              const SizedBox(height: 24),
            ],
          )), FormActions(child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('등록 (참석자에게 알림 발송)'),
              ))]);
        },
      )),
    );
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty || _calendarId == null) {
      AppSnack.show(context, '제목과 캘린더를 확인해 주세요.');
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => context.read<CalendarRepository>().createEvent(
            calendarId: _calendarId!,
            title: _title.text.trim(),
            startsAt: _start,
            endsAt: _end,
            location: _location.text,
            description: _description.text,
            allDay: _allDay,
            participantIds: _participants.toList(),
            reminderMinutes: _reminderMinutes,
          ),
      successMessage: '일정이 등록되었습니다.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }
}

class _DateTimeRow extends StatelessWidget {
  const _DateTimeRow({
    required this.label,
    required this.value,
    required this.allDay,
    required this.onChanged,
  });

  final String label;
  final DateTime value;
  final bool allDay;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 44, child: Text(label)),
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                final date = await pickDate(context, value, firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (date == null) return;
                onChanged(DateTime(
                    date.year, date.month, date.day, value.hour, value.minute));
              },
              child: Text(Fmt.date(value)),
            ),
          ),
          if (!allDay) ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(value),
                  );
                  if (time == null) return;
                  onChanged(DateTime(value.year, value.month, value.day,
                      time.hour, time.minute));
                },
                child: Text(Fmt.time(value)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
