import '../../models/user.dart' show Department;
import '../../services/filter_memory.dart';
import 'calendar_range_selection.dart';
import '../../data/auth_repository.dart';
import 'calendar_month_data.dart';
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
  final _viewKey = GlobalKey<AsyncViewState<CalendarMonthData>>();

  final _calendarHeaderKey = GlobalKey();
  final _monthGridKey = GlobalKey();
  bool _resizing = false;
  double _calendarHeaderHeight = 0;

  void _measureCalendarHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final height = _calendarHeaderKey.currentContext?.size?.height;
      if (height != null && (height - _calendarHeaderHeight).abs() > 0.5) {
        setState(() => _calendarHeaderHeight = height);
      }
    });
  }

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _selected = DateTime.now();
  final Map<int, List<Holiday>> _holidays = {};
  bool _monthList = false;
  String? _categoryId;

  String? _filterKey;
  bool _filtersReady = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final auth = context.read<AuthState>();
      if (auth.user == null) return;
      _filterKey = FilterMemory.key(auth.serverUrl, auth.user!.id, 'calendar');
      final saved = await FilterMemory.load(_filterKey!);
      if (!mounted) return;
      setState(() {
        _monthList = saved['list'] == true;
        _categoryId = saved['category'] as String?;
        _filtersReady = true;
      });
      _refresh();
    });
  }

  Future<List<Holiday>> _loadHolidays(CalendarRepository repo, int year) async {
    return _holidays[year] ??= await repo.holidays(year);
  }

  DateTime get _windowStart =>
      DateTime(_month.year, _month.month, 1).subtract(const Duration(days: 7));
  DateTime get _windowEnd =>
      DateTime(_month.year, _month.month + 1, 1).add(const Duration(days: 7));

  void _refresh() {
    if (_filtersReady && _filterKey != null) {
      FilterMemory.save(_filterKey!, {
        'list': _monthList,
        'category': _categoryId,
      });
    }
    _viewKey.currentState?.reload();
  }

  void _shiftMonth(int delta) => setState(() {
    _month = DateTime(_month.year, _month.month + delta);
    _refresh();
  });

  Future<void> _createEvent(DateTime date, [DateTime? end]) async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EventFormPage(initialDate: date, initialEnd: end),
      ),
    );
    if (mounted && created == true) _refresh();
  }

  Future<void> _resizeEvent(
    CalendarEvent event,
    bool start,
    DateTime date,
  ) async {
    if (_resizing) return;
    final range = resizedCalendarRange(event, date, start: start);
    if (range == null) {
      AppSnack.show(context, '시작일은 종료일보다 늦을 수 없습니다.');
      return;
    }
    if (range.start == event.startsAt && range.end == event.endsAt) return;
    setState(() => _resizing = true);
    final saved = await runGuarded(
      context,
      () => context.read<CalendarRepository>().updateEvent(event.id, {
        'starts_at': range.start.toUtc().toIso8601String(),
        'ends_at': range.end.toUtc().toIso8601String(),
      }),
    );
    if (!mounted) return;
    setState(() => _resizing = false);
    if (saved) _refresh();
  }

  Future<void> _createCalendar() async {
    final departments = await context
        .read<AuthRepository>()
        .departments()
        .catchError((Object error) {
          if (mounted) {
            AppSnack.show(
              context,
              error is ApiException ? error.message : '부서를 불러오지 못했습니다.',
              error: true,
            );
          }
          return <Department>[];
        });
    if (!mounted) return;
    String? departmentId;
    final name = TextEditingController();
    var type = CalendarType.personal;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: const Text('캘린더 만들기'),
          scrollable: true,
          content: FormFields(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '이름'),
              ),
              DropdownButton<CalendarType>(
                value: type,
                items: [
                  for (final value in CalendarType.values.where(
                    (v) =>
                        (v == CalendarType.personal ||
                        context.read<AuthState>().isManager),
                  ))
                    DropdownMenuItem(value: value, child: Text(value.label)),
                ],
                onChanged: (value) {
                  if (value != null) update(() => type = value);
                },
              ),
              if (type == CalendarType.department)
                DropdownButton<String>(
                  value: departmentId,
                  hint: const Text('부서 선택'),
                  items: [
                    for (final d in departments)
                      DropdownMenuItem(value: d.id, child: Text(d.name)),
                  ],
                  onChanged: (value) => update(() => departmentId = value),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isNotEmpty &&
                    (type != CalendarType.department || departmentId != null)) {
                  Navigator.pop(c, true);
                }
              },
              child: const Text('만들기'),
            ),
          ],
        ),
      ),
    );
    final text = name.text.trim();
    Future<void>.delayed(const Duration(seconds: 1), name.dispose);
    if (accepted != true || !mounted) return;
    if (await runGuarded(
      context,
      () => context.read<CalendarRepository>().createCalendar(
        name: text,
        type: type,
        departmentId: type == CalendarType.department ? departmentId : null,
      ),
    )) {
      _refresh();
    }
  }

  void _showDay(
    BuildContext hostContext,
    DateTime date,
    CalendarMonthData data,
  ) {
    setState(() => _selected = date);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Text(
                  '${date.month}월 ${date.day}일 일정',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final event
                        in data.eventsByDay[calendarDateOnly(date)] ??
                            <CalendarEvent>[])
                      _EventTile(
                        event: event,
                        calendarColor: data.colorFor(
                          event,
                          Theme.of(context).colorScheme.primary,
                        ),
                        onChanged: _refresh,
                        onTap: () {
                          Navigator.of(context).pop();
                          EventDetailSheet.show(
                            hostContext,
                            event,
                            onChanged: _refresh,
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<CalendarRepository>();
    return Scaffold(
      body: SafeArea(
        top: false,
        child: PageBody.workspace(
          child: AsyncView<CalendarMonthData>(
            key: _viewKey,
            load: () async {
              try {
                final month = _month;
                final results = await Future.wait([
                  repo.calendars(),
                  repo.events(
                    from: _windowStart,
                    to: _windowEnd,
                    categoryId: _categoryId,
                  ),
                  context
                      .read<AdminRepository>()
                      .codeGroup('EVENT_CATEGORY')
                      .then((group) => group.items),
                  for (var y = _windowStart.year; y <= _windowEnd.year; y++)
                    if (y >= 2000 && y <= 2100) _loadHolidays(repo, y),
                ]);
                return CalendarMonthData(
                  month: month,
                  categories: results[2] as List<CodeItem>,
                  calendars: results[0] as List<AppCalendar>,
                  events: results[1] as List<CalendarEvent>,
                  holidays: results
                      .skip(3)
                      .expand((v) => (v as List<Holiday>))
                      .toList(),
                );
              } on ApiException catch (e) {
                if (context.mounted) {
                  AppSnack.show(context, e.message, error: true);
                }
                rethrow;
              }
            },
            builder: (context, data, reload) {
              final dayEvents = _monthList
                  ? (data.eventsByDay.values
                        .expand((rows) => rows)
                        .where(
                          (event) =>
                              event.startsAt.isBefore(
                                DateTime(_month.year, _month.month + 1),
                              ) &&
                              event.endsAt.isAfter(_month),
                        )
                        .toSet()
                        .toList()
                      ..sort((a, b) => a.startsAt.compareTo(b.startsAt)))
                  : data.eventsByDay[calendarDateOnly(_selected)] ??
                        <CalendarEvent>[];
              return LayoutBuilder(
                builder: (context, constraints) {
                  final desktop = constraints.maxWidth >= 600;
                  final splitView =
                      constraints.maxWidth >= 1000 &&
                      MediaQuery.textScalerOf(context).scale(14) < 22;
                  _measureCalendarHeader();
                  final scaler = MediaQuery.textScalerOf(context);
                  final weekdayHeight = (scaler.scale(11) + 6).clamp(
                    22.0,
                    double.infinity,
                  );
                  // Keep room for the date, one event and the overflow link.
                  // Below this readable minimum the existing page scrolls.
                  final fontSize = desktop ? 12.0 : 11.0;
                  final minHeight =
                      (scaler.scale(12) + 8).clamp(24.0, double.infinity) +
                      2 +
                      (scaler.scale(fontSize) + 5).clamp(
                        18.0,
                        double.infinity,
                      ) +
                      (scaler.scale(fontSize) + 4).clamp(18.0, double.infinity);
                  final availableHeight =
                      constraints.maxHeight -
                      fieldLabelInsets(context).vertical -
                      _calendarHeaderHeight -
                      weekdayHeight -
                      1;
                  final rowHeight = constraints.hasBoundedHeight
                      ? (availableHeight / data.weeks.length)
                            .clamp(minHeight, double.infinity)
                            .toDouble()
                      : minHeight;
                  final calendar = Padding(
                    padding: fieldLabelInsets(context),
                    child: Column(
                      children: [
                        Column(
                          key: _calendarHeaderKey,
                          children: [
                            Wrap(
                              runSpacing: 12,
                              spacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                DropdownButton<String>(
                                  value: _categoryId,
                                  hint: const Text('모든 분류'),
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('모든 분류'),
                                    ),
                                    for (final category in data.categories)
                                      DropdownMenuItem(
                                        value: category.id,
                                        child: Text(category.name),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    setState(() => _categoryId = value);
                                    _refresh();
                                  },
                                ),
                                TextButton.icon(
                                  onPressed: _createCalendar,
                                  icon: const Icon(Icons.add),
                                  label: const Text('캘린더 만들기'),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpace.md),
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
                          ],
                        ),
                        CalendarRangeSelection(
                          firstDay: data.weeks.first.days.first,
                          rowHeight: rowHeight,
                          weekdayHeight:
                              (MediaQuery.textScalerOf(context).scale(11) + 6)
                                  .clamp(22.0, double.infinity),
                          weeks: data.weeks.length,
                          enabled: false,
                          onSelected: (start, end) => _createEvent(start, end),
                          child: _MonthGrid(
                            key: _monthGridKey,
                            canResize: !_resizing,
                            onResize: _resizeEvent,
                            dateAt: (global) {
                              final box =
                                  _monthGridKey.currentContext
                                          ?.findRenderObject()
                                      as RenderBox?;
                              if (box == null) return null;
                              final point = box.globalToLocal(global);
                              final weekdayHeight =
                                  (MediaQuery.textScalerOf(context).scale(11) +
                                          6)
                                      .clamp(22.0, double.infinity);
                              final col =
                                  ((point.dx - AppSpace.xs) /
                                          ((box.size.width - 2 * AppSpace.xs) /
                                              7))
                                      .floor();
                              final row =
                                  ((point.dy - weekdayHeight) / rowHeight)
                                      .floor();
                              if (col < 0 ||
                                  col > 6 ||
                                  row < 0 ||
                                  row >= data.weeks.length) {
                                return null;
                              }
                              return data.weeks[row].days[col];
                            },
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
                        ),
                        const Divider(height: 1),
                      ],
                    ),
                  );
                  final dayList = dayEvents.isEmpty
                      ? StatePlaceholder(
                          icon: Icons.event_available,
                          message: '아직 등록된 일정이 없습니다',
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: dayEvents.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) => _EventTile(
                            event: dayEvents[i],
                            calendarColor: data.colorFor(
                              dayEvents[i],
                              Theme.of(context).colorScheme.primary,
                            ),
                            onChanged: _refresh,
                          ),
                        );
                  final selectedPanel = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          runSpacing: 12,
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilterChip(
                              label: const Text('월 전체 목록'),
                              selected: _monthList,
                              onSelected: (value) => setState(() {
                                _monthList = value;
                                _refresh();
                              }),
                            ),

                            Text(
                              '${_monthList ? '${_month.year}년 ${_month.month}월' : Fmt.date(_selected)} · ${dayEvents.length}개 일정',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                      dayList,
                    ],
                  );
                  if (splitView) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: SingleChildScrollView(child: calendar),
                        ),
                        const VerticalDivider(width: 24),
                        Expanded(
                          child: SingleChildScrollView(child: selectedPanel),
                        ),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    key: const ValueKey('calendar-page-scroll'),
                    padding: const EdgeInsets.only(bottom: AppSpace.lg),
                    child: Column(
                      children: [
                        calendar,
                        const SizedBox(height: AppSpace.md),
                        selectedPanel,
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
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
          IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
          Expanded(
            child: Text(
              '${month.year}년 ${month.month}월',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
          TextButton(onPressed: onToday, child: const Text('오늘')),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    super.key,
    required this.onResize,
    required this.dateAt,
    required this.canResize,
    required this.month,
    required this.selected,
    required this.data,
    required this.rowHeight,
    required this.desktop,
    required this.onSelect,
    required this.onCreate,
    required this.onOverflow,
    required this.onChanged,
  });

  final void Function(CalendarEvent, bool, DateTime) onResize;
  final DateTime? Function(Offset) dateAt;
  final bool canResize;
  final DateTime month, selected;
  final CalendarMonthData data;
  final double rowHeight;
  final bool desktop;
  final ValueChanged<DateTime> onSelect, onCreate, onOverflow;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = calendarDateOnly(DateTime.now());
    final fontSize = desktop ? 12.0 : 11.0;
    final textHeight = MediaQuery.textScalerOf(context).scale(fontSize);
    final laneHeight = (textHeight + 5).clamp(18.0, double.infinity).toDouble();
    final headerHeight =
        (MediaQuery.textScalerOf(context).scale(12) + 8).clamp(
          24.0,
          double.infinity,
        ) +
        2;
    final overflowHeight = (textHeight + 4)
        .clamp(18.0, double.infinity)
        .toDouble();
    final visibleLanes =
        ((rowHeight - headerHeight - overflowHeight) / laneHeight)
            .floor()
            .clamp(0, desktop ? 5 : 3)
            .toInt();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: Column(
        children: [
          SizedBox(
            height: (MediaQuery.textScalerOf(context).scale(11) + 6).clamp(
              22.0,
              double.infinity,
            ),
            child: Row(
              children: [
                for (final (i, label) in [
                  '일',
                  '월',
                  '화',
                  '수',
                  '목',
                  '금',
                  '토',
                ].indexed)
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: i == 6
                              ? AppColors.info(context)
                              : i == 0
                              ? AppColors.danger(context)
                              : scheme.outline,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (final week in data.weeks)
            SizedBox(
              height: rowHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cellWidth = constraints.maxWidth / 7;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Row(
                          children: [
                            for (final date in week.days)
                              Expanded(
                                child: _DayCell(
                                  date: date,
                                  month: month,
                                  selected: selected,
                                  today: today,
                                  holiday: data.holidayNames[date] ?? '',
                                  onTap: onSelect,
                                  onDoubleTap: onCreate,
                                  onLongPress: onCreate,
                                ),
                              ),
                          ],
                        ),
                      ),
                      for (final segment in week.segments)
                        if (segment.lane < visibleLanes)
                          Positioned(
                            left: segment.start * cellWidth + 1,
                            width:
                                (segment.end - segment.start + 1) * cellWidth -
                                2,
                            top: headerHeight + segment.lane * laneHeight,
                            height: laneHeight - 2,
                            child: _EventBar(
                              key: ValueKey(
                                '${segment.event.id}:${week.days.first}',
                              ),
                              segment: segment,
                              dateAt: dateAt,
                              onResize: (start, date) =>
                                  onResize(segment.event, start, date),
                              canResize: canResize,

                              fontSize: fontSize,
                              color: data.colorFor(
                                segment.event,
                                scheme.primary,
                              ),
                              onTap: () => EventDetailSheet.show(
                                context,
                                segment.event,
                                onChanged: onChanged,
                              ),
                              onLongPress: (offset) {
                                final day =
                                    (segment.start +
                                            (offset / cellWidth).floor())
                                        .clamp(segment.start, segment.end)
                                        .toInt();
                                onCreate(week.days[day]);
                              },
                            ),
                          ),
                      for (var day = 0; day < 7; day++)
                        if (week.lanesByDay[day].any(
                          (lane) => lane >= visibleLanes,
                        ))
                          Positioned(
                            left: day * cellWidth,
                            width: cellWidth,
                            bottom: 0,
                            height: overflowHeight,
                            child: InkWell(
                              onTap: () => onOverflow(week.days[day]),
                              onLongPress: () => onCreate(week.days[day]),
                              child: Center(
                                child: Text(
                                  '+${week.lanesByDay[day].where((lane) => lane >= visibleLanes).length}',
                                  style: TextStyle(
                                    fontSize: fontSize,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                    ],
                  );
                },
              ),
            ),
          const SizedBox(height: AppSpace.xs),
        ],
      ),
    );
  }
}

class _EventBar extends StatefulWidget {
  const _EventBar({
    super.key,
    required this.dateAt,
    required this.onResize,
    required this.canResize,
    required this.segment,
    required this.color,
    required this.fontSize,
    required this.onTap,
    required this.onLongPress,
  });
  final DateTime? Function(Offset) dateAt;
  final void Function(bool, DateTime) onResize;
  final bool canResize;
  final CalendarWeekSegment segment;
  final Color color;
  final double fontSize;
  final VoidCallback onTap;
  final ValueChanged<double> onLongPress;

  @override
  State<_EventBar> createState() => _EventBarState();
}

class _EventBarState extends State<_EventBar> {
  bool selected = false;
  DateTime? preview;
  CalendarWeekSegment get segment => widget.segment;
  double get fontSize => widget.fontSize;
  Color get color => widget.color;
  VoidCallback get onTap => widget.onTap;
  ValueChanged<double> get onLongPress => widget.onLongPress;

  Widget handle(bool start) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (details) =>
        setState(() => preview = widget.dateAt(details.globalPosition)),
    onPanUpdate: (details) =>
        setState(() => preview = widget.dateAt(details.globalPosition)),
    onPanCancel: () => setState(() => preview = null),
    onPanEnd: (_) {
      final date = preview;
      setState(() => preview = null);
      if (date != null) widget.onResize(start, date);
    },
    child: Tooltip(
      message: start ? '시작일 드래그' : '종료일 드래그',
      child: const SizedBox(
        width: 16,
        child: Center(child: Icon(Icons.drag_handle, size: 16)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final event = segment.event;
    final auth = context.read<AuthState>();
    final userId = auth.user?.id;
    final editable =
        widget.canResize &&
        userId != null &&
        (auth.isManager ||
            event.createdById == userId ||
            event.participants.any((p) => p.userId == userId && p.isOrganizer));
    final lastDay = calendarDateOnly(
      event.endsAt.subtract(const Duration(microseconds: 1)),
    );
    final solid =
        event.allDay || lastDay.isAfter(calendarDateOnly(event.startsAt));
    final surface = Theme.of(context).colorScheme.surface;
    final background = Color.alphaBlend(
      solid ? color : color.withValues(alpha: 0.16),
      surface,
    );
    final foreground = background.computeLuminance() > 0.179
        ? Colors.black
        : Colors.white;
    final title = solid
        ? event.title
        : '${event.startsAt.hour.toString().padLeft(2, '0')}:'
              '${event.startsAt.minute.toString().padLeft(2, '0')} ${event.title}';
    final radius = BorderRadius.horizontal(
      left: Radius.circular(segment.continuesLeft ? 0 : 6),
      right: Radius.circular(segment.continuesRight ? 0 : 6),
    );
    final bar = Semantics(
      button: true,
      label: title,
      child: Tooltip(
        message: preview == null
            ? '$title${editable ? ' · 선택 후 양끝을 드래그해 기간 변경' : ''}'
            : Fmt.date(preview!),
        child: GestureDetector(
          onLongPressStart: (details) => onLongPress(details.localPosition.dx),
          child: Material(
            color: background,
            borderRadius: radius,
            child: InkWell(
              onTap: () {
                if (editable && !selected) {
                  setState(() => selected = true);
                } else {
                  onTap();
                }
              },
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    preview == null ? title : Fmt.date(preview!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: fontSize,
                      height: 1,
                      color: foreground,
                      decoration: event.status == EventStatus.canceled
                          ? TextDecoration.lineThrough
                          : null,
                      decorationColor: foreground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!selected || !editable) return bar;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
      child: Row(
        children: [
          if (!segment.continuesLeft) handle(true),
          Expanded(child: bar),
          if (!segment.continuesRight) handle(false),
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
    required this.holiday,
    required this.onTap,
    required this.onDoubleTap,
    required this.onLongPress,
  });
  final DateTime date, month, selected, today;
  final String holiday;
  final ValueChanged<DateTime> onTap, onDoubleTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = date == calendarDateOnly(selected);
    final isToday = date == today;
    final color = holiday.isNotEmpty
        ? AppColors.danger(context)
        : date.month != month.month
        ? scheme.onSurfaceVariant
        : date.weekday == 6
        ? AppColors.info(context)
        : date.weekday == 7
        ? AppColors.danger(context)
        : scheme.onSurface;
    return InkWell(
      onTap: () => onTap(date),
      onDoubleTap: () {
        onTap(date);
        onDoubleTap(date);
      },
      onLongPress: () => onLongPress(date),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: isSelected ? scheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: isToday
              ? Border.all(color: scheme.primary, width: 1.2)
              : null,
        ),
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: (MediaQuery.textScalerOf(context).scale(12) + 8).clamp(
            24.0,
            double.infinity,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
                if (holiday.isNotEmpty)
                  Expanded(
                    child: Tooltip(
                      message: holiday,
                      child: Text(
                        ' $holiday',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 8,
                          color: AppColors.danger(context),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: event.status == EventStatus.canceled
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : null,
          decoration: event.status == EventStatus.canceled
              ? TextDecoration.lineThrough
              : null,
        ),
      ),
      subtitle: Text(
        '${Fmt.range(event.startsAt, event.endsAt, allDay: event.allDay)}'
        '${event.location != null ? ' · ${event.location}' : ''}',
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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
                  () => context.read<CalendarRepository>().respond(event.id, r),
                  successMessage: '${r.label}(으)로 응답했습니다.',
                );
                if (ok) onChanged();
              },
            ),
      onTap:
          onTap ??
          () => EventDetailSheet.show(context, event, onChanged: onChanged),
    );
  }
}
