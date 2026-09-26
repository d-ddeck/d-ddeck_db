import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/calendar_repository.dart';
import '../services/synced_alarm_store.dart';
import '../state/auth_state.dart';
import 'alarm_list_page.dart';
import 'calendar/event_detail_sheet.dart';
import 'common/common.dart';
import 'format.dart';

/// Always re-resolves a tapped ID from current storage. Stale launcher items
/// cannot open another account's event or resurrect a deleted snapshot.
class AlarmWidgetPage extends StatefulWidget {
  const AlarmWidgetPage({super.key, required this.reminderId});
  final String reminderId;
  @override
  State<AlarmWidgetPage> createState() => _AlarmWidgetPageState();
}

class _AlarmWidgetPageState extends State<AlarmWidgetPage> {
  late final _snapshot = SyncedAlarmStore().load();

  @override
  Widget build(BuildContext context) {
    if (widget.reminderId.isEmpty) return const SyncedAlarmsPage();
    return Scaffold(
      appBar: AppBar(title: const Text('저장된 알람 상세')),
      body: PageBody(
        child: FutureBuilder<SyncedAlarmSnapshot>(
          future: _snapshot,
          builder: (context, result) {
            if (result.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final snapshot = result.data;
            final reminder = snapshot?.reminders
                .where((r) => r.reminderId == widget.reminderId)
                .firstOrNull;
            if (reminder == null) {
              return const Text('이 알람은 삭제되었거나 저장된 목록에 없습니다.');
            }
            final auth = context.watch<AuthState>();
            final canOpen =
                auth.phase == AuthPhase.ready &&
                auth.user?.id == snapshot?.ownerUserId;
            return SingleChildScrollView(
              child: FormFields(
                children: [
                  Text(
                    reminder.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text('알람: ${Fmt.dateTime(reminder.scheduledAt.toLocal())}'),
                  Text(
                    '일정: ${Fmt.range(reminder.startsAt.toLocal(), reminder.endsAt.toLocal(), allDay: reminder.allDay)}',
                  ),
                  if (reminder.location?.isNotEmpty == true)
                    Text('장소: ${reminder.location}'),
                  if (reminder.calendarName?.isNotEmpty == true)
                    Text('캘린더: ${reminder.calendarName}'),
                  const Text('휴대폰에 저장된 내용입니다. 서버의 최신 일정과 다를 수 있습니다.'),
                  FilledButton.icon(
                    onPressed: !canOpen
                        ? null
                        : () async {
                            await runGuarded(context, () async {
                              final event = await context
                                  .read<CalendarRepository>()
                                  .event(reminder.eventId);
                              if (context.mounted) {
                                await EventDetailSheet.show(context, event);
                              }
                            });
                          },
                    icon: const Icon(Icons.event),
                    label: const Text('서버의 일정 상세 보기'),
                  ),
                  if (!canOpen)
                    const Text('서버 상세는 알람을 저장한 계정으로 로그인한 후 볼 수 있습니다.'),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
