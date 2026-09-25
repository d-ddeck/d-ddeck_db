import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';

import 'common/common.dart';

import '../data/calendar_repository.dart';
import '../models/calendar.dart';
import '../services/alarm_service.dart';
import '../state/auth_state.dart';
import 'async_view.dart';
import 'format.dart';
import 'theme.dart';

class _AlarmStatus {
  const _AlarmStatus({
    required this.reminders,
    required this.pending,
    required this.exactAllowed,
  });

  final List<UpcomingReminder> reminders;
  final List<PendingNotificationRequest> pending;
  final bool exactAllowed;
}

/// 일정 알람 상태를 보여주고, 권한 문제를 사용자가 스스로 고치게 돕는 화면.
///
/// 알람이 안 울리는 원인은 거의 항상 권한이나 제조사 절전 설정이다. 조용히
/// 실패하면 직원은 "앱이 이상하다"고만 느끼므로, 무엇이 막혀 있는지 드러낸다.
class AlarmSettingsPage extends StatefulWidget {
  const AlarmSettingsPage({super.key});

  @override
  State<AlarmSettingsPage> createState() => _AlarmSettingsPageState();
}

class _AlarmSettingsPageState extends State<AlarmSettingsPage> {
  final _viewKey = GlobalKey<AsyncViewState<_AlarmStatus>>();

  @override
  Widget build(BuildContext context) {
    final alarms = context.read<AlarmService>();
    final repo = context.read<CalendarRepository>();
    final auth = context.watch<AuthState>();

    if (!AlarmService.isSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('일정 알림')),
        body: PageBody(child: StatePlaceholder(
          icon: Icons.notifications_off_outlined,
          message: '이 기기에서는 사용할 수 없습니다',
          detail: AlarmService.unsupportedReason,
        )),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('일정 알림')),
      body: PageBody(child: AsyncView<_AlarmStatus>(
        key: _viewKey,
        load: () async {
          final reminders = await repo.upcomingReminders(days: 7);
          return _AlarmStatus(
            reminders: reminders,
            pending: await alarms.pending(),
            exactAllowed: await alarms.hasExactAlarmPermission(),
          );
        },
        builder: (context, data, reload) => ListView(
          padding: EdgeInsets.zero,
          children: [
            if (!data.exactAllowed) _ExactAlarmWarning(onFixed: reload),

            SectionCard(title: '알림 상태',
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          data.pending.isEmpty
                              ? Icons.notifications_off_outlined
                              : Icons.notifications_active,
                          color: data.pending.isEmpty
                              ? Theme.of(context).colorScheme.outline
                              : AppColors.success(context),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          data.pending.isEmpty
                              ? '예약된 알림 없음'
                              : '${data.pending.length}건 예약됨',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '앞으로 7일간의 일정 알림을 기기에 미리 걸어둡니다.\n'
                      '인터넷이나 VPN 이 끊겨 있어도 정해진 시각에 울립니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await alarms.showTest();
                      if (!context.mounted) return;
                      AppSnack.show(context, '알림이 보이지 않으면 권한을 확인해 주세요.');
                    },
                    icon: const Icon(Icons.volume_up_outlined, size: 18),
                    label: const Text('테스트 알림'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await auth.syncAlarms();
                      reload();
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('다시 예약'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            Text(
              '예정된 알림',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (data.reminders.isEmpty)
              const EmptyState(message: '아직 등록된 예정 알림이 없습니다')
            else
              for (final r in data.reminders)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Container(
                      width: 4,
                      height: 40,
                      decoration: BoxDecoration(
                        color: r.color == null
                            ? Theme.of(context).colorScheme.primary
                            : parseHexColor(r.color!),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    title: Text(
                      r.title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '일정 ${Fmt.dateTime(r.startsAt)}'
                          '${r.location?.isNotEmpty == true ? ' · ${r.location}' : ''}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        Text(
                          '알림 ${Fmt.dateTime(r.scheduledAt)} '
                          '(${r.offsetMinutes}분 전)',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

            const SizedBox(height: 18),
            const _BatteryOptimizationNote(),
            const SizedBox(height: 24),
          ],
        ),
      )),
    );
  }
}

class _ExactAlarmWarning extends StatelessWidget {
  const _ExactAlarmWarning({required this.onFixed});
  final VoidCallback onFixed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '알림 시각이 밀릴 수 있습니다',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '"알람 및 리마인더" 권한이 꺼져 있어, 안드로이드가 알림을 '
              '수 분에서 수십 분까지 미룰 수 있습니다.\n\n'
              '설정 > 앱 > d-ddeck > 알람 및 리마인더 에서 켜주세요.',
              style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                await context.read<AlarmService>().requestPermissions();
                onFixed();
              },
              child: const Text('권한 다시 요청'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatteryOptimizationNote extends StatelessWidget {
  const _BatteryOptimizationNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(title: '알림 도움말',
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.battery_saver, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                const Text(
                  '알림이 안 울린다면',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '삼성·샤오미 등 일부 제조사는 배터리 절약을 위해 앱을 강제로 '
              '잠재웁니다. 그러면 예약한 알림도 함께 멈춥니다.\n\n'
              '설정 > 배터리 > 앱 절전 관리 에서 d-ddeck 을 '
              '"제한 없음" 으로 바꿔주세요.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
