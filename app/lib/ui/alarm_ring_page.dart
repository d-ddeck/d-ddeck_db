import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/calendar_repository.dart';
import '../services/alarm_service.dart';
import '../services/connectivity_probe.dart';
import '../services/synced_alarm_store.dart';
import '../models/calendar.dart';
import 'format.dart';
import 'theme.dart';
import '../state/auth_state.dart';
import 'calendar/event_detail_sheet.dart';

/// 인증 화면과 별개로 표시한다. payload만으로 오프라인에서도 내용을 읽는다.
class AlarmRingPage extends StatefulWidget {
  const AlarmRingPage({super.key, required this.alarm});
  final AlarmSettings alarm;

  @override
  State<AlarmRingPage> createState() => _AlarmRingPageState();
}

class _AlarmRingPageState extends State<AlarmRingPage> {
  late final Timer _clock;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  Future<void> _act(bool snooze) async {
    final service = context.read<AlarmService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (snooze) {
        await service.snooze(widget.alarm);
        service.closeRing(widget.alarm.id);
      } else {
        await service.stop(widget.alarm.id);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _detail(String id, BuildContext pageContext) async {
    final auth = context.read<AuthState>();
    final repo = context.read<CalendarRepository>();
    if (auth.phase != AuthPhase.ready || !await canReachServer(auth.api)) {
      if (pageContext.mounted) await _savedDetail(id, pageContext);
      return;
    }
    try {
      final event = await repo.event(id).timeout(const Duration(seconds: 3));
      if (!pageContext.mounted) return;
      await EventDetailSheet.show(pageContext, event);
    } catch (_) {
      if (pageContext.mounted) await _savedDetail(id, pageContext);
    }
  }

  Future<void> _savedDetail(String id, BuildContext pageContext) async {
    UpcomingReminder? reminder;
    try {
      final saved = await SyncedAlarmStore().load();
      for (final r in saved.reminders) {
        if (r.alarmId == widget.alarm.id) {
          reminder = r;
          break;
        }
        if (r.eventId == id) reminder ??= r;
      }
    } catch (_) {
      // 저장본이 없거나 읽을 수 없어도 울림 payload에 기본 정보가 있다.
    }
    if (!pageContext.mounted) return;
    final data = AlarmService.metadata(widget.alarm);
    final title =
        reminder?.title ??
        data['title'] as String? ??
        widget.alarm.notificationSettings.title;
    final when = reminder == null
        ? '${data['startsLabel'] ?? '-'}'
        : Fmt.range(
            reminder.startsAt.toLocal(),
            reminder.endsAt.toLocal(),
            allDay: reminder.allDay,
          );
    final location = reminder?.location ?? data['location'] as String?;
    await showModalBottomSheet<void>(
      context: pageContext,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '이 폰에 저장된 일정',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text('일정: $when'),
              Text(
                '알림: ${Fmt.dateTime((reminder?.scheduledAt ?? widget.alarm.dateTime).toLocal())}',
              ),
              if (location?.isNotEmpty == true) Text('장소: $location'),
              const SizedBox(height: 12),
              const Text('폰에 저장된 내용으로, 서버의 최신 일정과 다를 수 있습니다.'),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('닫기'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = context.read<AlarmService>();
    final data = AlarmService.metadata(widget.alarm);
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final minutes =
        widget.alarm.androidSnoozeDuration?.inMinutes ??
        service.prefs.snoozeMinutes;
    return ValueListenableBuilder<Set<int>>(
      valueListenable: service.ringingIds,
      builder: (context, ids, _) {
        final ringing = ids.contains(widget.alarm.id);
        return PopScope(
          canPop: false,
          child: Theme(
            data: ThemeData.dark(useMaterial3: true),
            child: Scaffold(
              backgroundColor: const Color(0xFF10141D),
              body: Builder(
                builder: (pageContext) => SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            time,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 76,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            ringing ? '일정 알람' : '알람이 꺼졌습니다',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: parseHexColor(
                                    data['color'] as String? ?? '#3B82F6',
                                  ),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: AppSpace.sm),
                              Flexible(
                                child: Text(
                                  data['title'] as String? ??
                                      widget.alarm.notificationSettings.title,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            data['startsLabel'] as String? ?? '',
                            textAlign: TextAlign.center,
                          ),
                          if (data['location'] != null)
                            Text(
                              '${data['location']}',
                              textAlign: TextAlign.center,
                            ),
                          if (data['calendarName'] != null)
                            Text(
                              '${data['calendarName']}',
                              textAlign: TextAlign.center,
                            ),
                          const SizedBox(height: 48),
                          if (_error != null)
                            Text(
                              _error!,
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                              ),
                            ),
                          if (ringing || _busy) ...[
                            FilledButton(
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(68),
                              ),
                              onPressed: _busy ? null : () => _act(false),
                              child: const Text(
                                '끄기',
                                style: TextStyle(fontSize: 22),
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(68),
                              ),
                              onPressed: _busy ? null : () => _act(true),
                              child: Text(
                                '$minutes분 뒤 다시',
                                style: const TextStyle(fontSize: 22),
                              ),
                            ),
                          ] else ...[
                            if (data['eventId'] is String)
                              TextButton(
                                onPressed: () => _detail(
                                  data['eventId'] as String,
                                  pageContext,
                                ),
                                child: const Text('일정 상세 보기'),
                              ),
                            FilledButton(
                              onPressed: () =>
                                  service.closeRing(widget.alarm.id),
                              child: const Text('닫기'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
