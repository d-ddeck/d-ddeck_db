import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';

import 'common/common.dart';

import '../data/calendar_repository.dart';
import '../models/calendar.dart';
import '../services/alarm_service.dart';
import 'alarm_list_page.dart';
import '../state/auth_state.dart';
import 'async_view.dart';
import 'format.dart';
import 'theme.dart';

class _AlarmStatus {
  const _AlarmStatus({
    required this.reminders,
    required this.pending,
    required this.exactAllowed,
    required this.notificationAllowed,
    required this.fullScreenAllowed,
  });

  final List<UpcomingReminder> reminders;
  final List<PendingNotificationRequest> pending;
  final bool exactAllowed;
  final bool notificationAllowed;
  final bool fullScreenAllowed;
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

class _AlarmSettingsPageState extends State<AlarmSettingsPage> with WidgetsBindingObserver {
  final _viewKey = GlobalKey<AsyncViewState<_AlarmStatus>>();

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _viewKey.currentState?.reload();
  }

  Future<void> _save(AlarmService alarms, AuthState auth) async {
    setState(() => _saving = true);
    try {
      await alarms.prefs.save();
      if (!alarms.prefs.enabled) await alarms.applyDisabledPreference();
      await auth.syncAlarms();
      _viewKey.currentState?.reload();
    } catch (_) {
      if (mounted) AppSnack.show(context, '알람 설정을 저장하지 못했습니다.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

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
      body: PageBody(child: Column(children: [
        ListTile(leading: const Icon(Icons.alarm),
          title: const Text('이 폰에 저장된 알람 보기'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SyncedAlarmsPage()))),
        Expanded(child: AsyncView<_AlarmStatus>(
        key: _viewKey,
        load: () async {
          await alarms.init();
          // 네트워크가 없어도 권한과 기기에 저장된 예약을 확인할 수 있다.
          List<UpcomingReminder> reminders = [];
          if (auth.phase == AuthPhase.ready) {
            try { reminders = await repo.upcomingReminders(days: 7); } catch (_) {}
          }
          return _AlarmStatus(
            reminders: reminders,
            pending: await alarms.pending(),
            exactAllowed: await alarms.hasExactAlarmPermission(),
            notificationAllowed: await alarms.hasNotificationPermission(),
            fullScreenAllowed: await alarms.hasFullScreenPermission(),
          );
        },
        builder: (context, data, reload) => ListView(
          padding: EdgeInsets.zero,
          children: [
            SectionCard(title: '알람 설정', child: Column(children: [
              SwitchListTile(title: const Text('알람 사용'), value: alarms.prefs.enabled,
                onChanged: _saving ? null : (v) { setState(() => alarms.prefs.enabled = v); _save(alarms, auth); }),
              SwitchListTile(title: const Text('소리'), value: alarms.prefs.sound,
                onChanged: _saving ? null : (v) { setState(() => alarms.prefs.sound = v); _save(alarms, auth); }),
              SwitchListTile(title: const Text('진동'), value: alarms.prefs.vibrate,
                onChanged: _saving ? null : (v) { setState(() => alarms.prefs.vibrate = v); _save(alarms, auth); }),
              ListTile(title: Text('볼륨 ${(alarms.prefs.volume * 100).round()}%'),
                subtitle: Slider(value: alarms.prefs.volume,
                  onChanged: _saving || !alarms.prefs.sound ? null : (v) => setState(() => alarms.prefs.volume = v),
                  onChangeEnd: (_) => _save(alarms, auth))),
              ListTile(title: const Text('다시 울림'), trailing: DropdownButton<int>(
                value: alarms.prefs.snoozeMinutes,
                items: [1, 3, 5, 10].map((m) => DropdownMenuItem(value: m, child: Text('$m분'))).toList(),
                onChanged: _saving ? null : (v) {
                  if (v == null) return;
                  setState(() => alarms.prefs.snoozeMinutes = v);
                  _save(alarms, auth);
                },
              )),
            ])),
            const SizedBox(height: 12),
            SectionCard(title: '권한 상태', child: Column(children: [
              ListTile(title: const Text('알림'), trailing: Text(data.notificationAllowed ? '허용' : '꺼짐')),
              ListTile(title: const Text('정확한 알람'), trailing: Text(data.exactAllowed ? '허용' : '꺼짐')),
              ListTile(title: const Text('잠금화면 전면 표시'), trailing: Text(data.fullScreenAllowed ? '허용' : '꺼짐'),
                subtitle: const Text('Android 14 이상: 설정 > 앱 > 특별한 앱 액세스 > 전체 화면 알림에서 허용해 주세요.')),
              Wrap(spacing: 8, children: [
                TextButton(onPressed: () async {
                  await alarms.requestPermissions();
                  await auth.syncAlarms();
                  reload();
                }, child: const Text('알림·정확한 알람 권한')),
                TextButton(onPressed: () async {
                  await alarms.requestFullScreenPermission();
                  reload();
                }, child: const Text('전면 표시 설정 열기')),
              ]),
            ])),
            const SizedBox(height: 12),
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
                      try {
                        await alarms.showTest();
                        if (!context.mounted) return;
                        AppSnack.show(context, '10초 뒤 테스트 알람이 울립니다. 화면을 잠가 확인해 보세요.');
                        reload();
                      } catch (e) {
                        if (context.mounted) AppSnack.show(context, '$e');
                      }
                    },
                    icon: const Icon(Icons.volume_up_outlined, size: 18),
                    label: const Text('10초 뒤 테스트'),
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

            for (final alarm in data.pending)
              ListTile(leading: const Icon(Icons.alarm),
                title: Text(alarm.title ?? '일정 알람'),
                subtitle: Text(alarm.body ?? '')),
            const SizedBox(height: 12),
            Text(
              '서버의 예정된 알림',
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
      ])),
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
                    '정확한 알람 권한이 필요합니다',
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
              '"알람 및 리마인더" 권한이 꺼져 있어, 일정 알람을 '
              '예약하지 못할 수 있습니다.\n\n'
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
