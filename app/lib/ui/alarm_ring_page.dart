import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/calendar_repository.dart';
import '../services/alarm_service.dart';
import '../state/auth_state.dart';
import 'calendar/event_detail_sheet.dart';
import 'common/common.dart';

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
    setState(() { _busy = true; _error = null; });
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
    if (context.read<AuthState>().phase != AuthPhase.ready) {
      AppSnack.show(pageContext, '로그인 후 일정 상세를 확인해 주세요.');
      return;
    }
    try {
      final event = await context.read<CalendarRepository>().event(id);
      if (!pageContext.mounted) return;
      await EventDetailSheet.show(pageContext, event);
    } catch (_) {
      if (pageContext.mounted) AppSnack.show(pageContext, '일정을 불러오지 못했습니다. 연결과 접근 권한을 확인해 주세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.read<AlarmService>();
    final data = AlarmService.metadata(widget.alarm);
    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final minutes = widget.alarm.androidSnoozeDuration?.inMinutes ?? service.prefs.snoozeMinutes;
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
              body: Builder(builder: (pageContext) => SafeArea(
                child: Center(child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(time, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 76, fontWeight: FontWeight.w300)),
                      const SizedBox(height: 20),
                      Text(ringing ? '일정 알람' : '알람이 꺼졌습니다', textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Text(data['title'] as String? ?? widget.alarm.notificationSettings.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 16),
                      Text(data['startsLabel'] as String? ?? '', textAlign: TextAlign.center),
                      if (data['location'] != null)
                        Text('${data['location']}', textAlign: TextAlign.center),
                      if (data['calendarName'] != null)
                        Text('${data['calendarName']}', textAlign: TextAlign.center),
                      const SizedBox(height: 48),
                      if (_error != null) Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
                      if (ringing || _busy) ...[
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(68)),
                          onPressed: _busy ? null : () => _act(false),
                          child: const Text('끄기', style: TextStyle(fontSize: 22)),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(68)),
                          onPressed: _busy ? null : () => _act(true),
                          child: Text('$minutes분 뒤 다시', style: const TextStyle(fontSize: 22)),
                        ),
                      ] else ...[
                        if (data['eventId'] is String)
                          TextButton(onPressed: () => _detail(data['eventId'] as String, pageContext),
                            child: const Text('일정 상세 보기')),
                        FilledButton(onPressed: () => service.closeRing(widget.alarm.id),
                          child: const Text('닫기')),
                      ],
                    ],
                  ),
                )),
              )),
            ),
          ),
        );
      },
    );
  }
}
