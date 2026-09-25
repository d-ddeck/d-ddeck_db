import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../data/auth_repository.dart';
import '../../data/calendar_repository.dart';
import '../../models/calendar.dart';
import '../../models/common.dart';
import '../async_view.dart';
import '../common/common.dart';
import '../format.dart';

class EventFormPage extends StatefulWidget {
  const EventFormPage({super.key, required this.initialDate}) : event = null, onSaved = null;
  const EventFormPage.edit(CalendarEvent this.event, {super.key, this.onSaved}) : initialDate = null;
  final DateTime? initialDate;
  final CalendarEvent? event;
  final ValueChanged<CalendarEvent>? onSaved;

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
  String? _categoryId;
  bool _isPrivate = false;
  late List<EventReminder> _reminders;
  final Set<String> _participants = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDate ?? widget.event!.startsAt;
    _start = DateTime(d.year, d.month, d.day, 9);
    _end = _start.add(const Duration(hours: 1));
    final event = widget.event;
    _reminders = List.of(event?.reminders ?? [const EventReminder(id: '', offsetMinutes: 30)]);
    if (event != null) {
      _title.text = event.title;
      _location.text = event.location ?? '';
      _description.text = event.description ?? '';
      _calendarId = event.calendarId;
      _categoryId = event.categoryId;
      _start = event.startsAt;
      _end = event.endsAt;
      _allDay = event.allDay;
      _isPrivate = event.isPrivate;
      _participants.addAll(event.participants.map((p) => p.userId));
    }
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

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
      appBar: AppBar(title: Text(widget.event == null ? '일정 등록' : '일정 수정')),
      body: PageBody(child: AsyncView<(List<AppCalendar>, List<UserBrief>, List<CodeItem>)>(
        load: () async {
          final results = await Future.wait([
            calendarRepo.calendars(),
            authRepo.directory(size: 100),
            context.read<AdminRepository>().codeGroup('EVENT_CATEGORY').then((g) => g.items),
          ]);
          return (
            results[0] as List<AppCalendar>,
            (results[1] as PagedList<UserBrief>).items,
            results[2] as List<CodeItem>,
          );
        },
        builder: (context, data, reload) {
          final (calendars, directory, categories) = data;
          final members = {for (final m in directory) m.id: m};
          for (final p in widget.event?.participants ?? <EventParticipant>[]) {
            members.putIfAbsent(p.userId, () => p.user ?? UserBrief(id: p.userId, fullName: p.userId));
          }
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
                  if (_calendarId != null && !calendars.any((c) => c.id == _calendarId))
                    DropdownMenuItem(value: _calendarId,
                      child: Text(widget.event?.calendar?.name ?? '기존 캘린더')),
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
                onChanged: widget.event != null ? null : (v) => setState(() => _calendarId = v),
              ),
              const FormGap(),
              DropdownButtonFormField<String>(
                initialValue: _categoryId ?? '',
                decoration: const InputDecoration(labelText: '구분'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('미지정')),
                  if (_categoryId != null && !categories.any((c) => c.id == _categoryId))
                    DropdownMenuItem(value: _categoryId, child: const Text('기존 구분')),
                  for (final c in categories)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _categoryId = v == '' ? null : v),
              ),
              const FormGap(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('비공개', style: TextStyle(fontSize: 14)),
                value: _isPrivate,
                onChanged: (v) => setState(() => _isPrivate = v),
              ),
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
              FormSection(title: '알림', children: [
                for (final (index, reminder) in _reminders.indexed)
                  Row(children: [
                    Expanded(child: DropdownButtonFormField<int>(
                      key: ObjectKey(reminder),
                      initialValue: reminder.offsetMinutes,
                      isExpanded: true,
                      items: [
                        for (final minutes in ({0, 10, 30, 60, 1440, reminder.offsetMinutes}.toList()..sort()))
                          DropdownMenuItem(value: minutes,
                            child: Text(minutes == 0 ? '시작 시각' : '$minutes분 전')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _reminders[index] = EventReminder(
                          id: reminder.id, offsetMinutes: v, method: reminder.method));
                      },
                    )),
                    IconButton(tooltip: '알림 삭제', icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _reminders.removeAt(index))),
                  ]),
                TextButton.icon(
                  onPressed: () => setState(() => _reminders.add(
                    const EventReminder(id: '', offsetMinutes: 30))),
                  icon: const Icon(Icons.add), label: const Text('알림 추가')),
              ]),
              const SizedBox(height: 16),
              const Text('참석자',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in members.values)
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
                    : Text(widget.event == null ? '등록 (참석자에게 알림 발송)' : '저장'),
              ))]);
        },
      )),
    ));
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty || _calendarId == null) {
      AppSnack.show(context, '제목과 캘린더를 확인해 주세요.');
      return;
    }
    final event = widget.event;
    // Preserve untouched timestamps, including existing all-day event boundaries.
    final start = _allDay && (event == null || !event.allDay || _start != event.startsAt)
        ? DateUtils.dateOnly(_start) : _start;
    final end = _allDay && (event == null || !event.allDay || _end != event.endsAt)
        ? DateTime(_end.year, _end.month, _end.day, 23, 59, 59) : _end;
    if (end.isBefore(start)) {
      AppSnack.show(context, '종료는 시작보다 빠를 수 없습니다.', error: true);
      return;
    }
    final reminders = [for (final r in _reminders)
      {'offset_minutes': r.offsetMinutes, 'method': r.method}];
    setState(() => _busy = true);
    final repo = context.read<CalendarRepository>();
    final ok = await runGuarded(context, () async {
      if (event == null) {
        await repo.createEvent(
          calendarId: _calendarId!, title: _title.text.trim(),
          startsAt: start, endsAt: end, location: _location.text,
          description: _description.text, categoryId: _categoryId,
          allDay: _allDay, isPrivate: _isPrivate,
          participantIds: _participants.toList(), reminders: reminders,
        );
      } else {
        final changes = <String, dynamic>{};
        if (_title.text.trim() != event.title) changes['title'] = _title.text.trim();
        if (_description.text != (event.description ?? '')) changes['description'] = _description.text;
        if (_location.text != (event.location ?? '')) changes['location'] = _location.text;
        if (_categoryId != event.categoryId) changes['category_id'] = _categoryId;
        if (start != event.startsAt) changes['starts_at'] = start.toUtc().toIso8601String();
        if (end != event.endsAt) changes['ends_at'] = end.toUtc().toIso8601String();
        if (_allDay != event.allDay) changes['all_day'] = _allDay;
        if (_isPrivate != event.isPrivate) changes['is_private'] = _isPrivate;
        if (!setEquals(_participants, event.participants.map((p) => p.userId).toSet())) {
          changes['participant_ids'] = _participants.toList();
        }
        if (!listEquals(
          _reminders.map((r) => (r.offsetMinutes, r.method)).toList(),
          event.reminders.map((r) => (r.offsetMinutes, r.method)).toList(),
        )) {
          changes['reminders'] = reminders;
        }
        final updated = changes.isEmpty ? event : await repo.updateEvent(event.id, changes);
        widget.onSaved?.call(updated);
      }
    }, successMessage: event == null ? '일정이 등록되었습니다.' : '일정이 수정되었습니다.');
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
