import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/calendar.dart';
import '../services/alarm_service.dart';
import '../services/connectivity_probe.dart';
import '../services/synced_alarm_store.dart';
import '../state/auth_state.dart';
import 'alarm_settings_page.dart';
import 'common/common.dart';
import 'format.dart';
import 'theme.dart';

class SyncedAlarmsPage extends StatefulWidget {
  const SyncedAlarmsPage({super.key});

  @override
  State<SyncedAlarmsPage> createState() => _SyncedAlarmsPageState();
}

class _SyncedAlarmsPageState extends State<SyncedAlarmsPage>
    with WidgetsBindingObserver {
  final _store = SyncedAlarmStore();
  SyncedAlarmSnapshot _snapshot = const SyncedAlarmSnapshot();
  Set<int>? _scheduled;
  bool? _reachable;
  bool _loading = true;
  bool _syncing = false;
  bool _deleting = false;
  bool _refreshing = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    if (_refreshing || _deleting) return;
    _refreshing = true;
    final auth = context.read<AuthState>();
    final service = context.read<AlarmService>();
    final probe = canReachServer(auth.api);
    try {
      final snapshot = await _store.load();
      if (mounted && !_deleting) {
        setState(() {
          _snapshot = snapshot;
          _error = null;
          _loading = false;
        });
      }
      await service.init();
      final scheduled = AlarmService.isSupported && service.isReady
          ? (await Alarm.getAlarms()).map((a) => a.id).toSet()
          : null;
      if (mounted && !_deleting) setState(() => _scheduled = scheduled);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _scheduled = null;
          _error = '저장된 알람 또는 예약 상태를 읽지 못했습니다. 다시 확인해 주세요.';
        });
      }
    } finally {
      final reachable = await probe;
      if (mounted) {
        setState(() => _reachable = reachable);
      }
      _refreshing = false;
    }
  }

  Future<void> _sync() async {
    final auth = context.read<AuthState>();
    setState(() => _syncing = true);
    final before = _snapshot.syncedAt;
    try {
      final reachable = await canReachServer(auth.api);
      if (!mounted) return;
      setState(() => _reachable = reachable);
      if (!reachable || auth.phase != AuthPhase.ready) return;
      await auth.syncAlarms();
      final snapshot = await _store.load();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
      AppSnack.show(
        context,
        snapshot.syncedAt != before
            ? '알람을 동기화했습니다.'
            : '동기화하지 못했습니다. 연결과 로그인 상태를 확인해 주세요.',
      );
      await _reload();
    } catch (_) {
      if (mounted) AppSnack.show(context, '알람을 동기화하지 못했습니다.');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _deleteAll() async {
    if (_deleting || _syncing) return;
    final confirmed = await ConfirmDialog.show(
      context,
      title: '이 폰의 알람 모두 지우기',
      message:
          '예약된 알람과 저장 목록을 모두 지웁니다. 울리는 알람도 멈춥니다.\n'
          '로그인 중이면 다음 동기화 때 다시 받아 올 수 있습니다.',
      confirmLabel: '모두 지우기',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      await context.read<AlarmService>().cancelAll();
      if (!mounted) return;
      setState(() {
        _snapshot = const SyncedAlarmSnapshot();
        _scheduled = {};
        _error = null;
        _loading = false;
      });
      AppSnack.show(context, '이 폰의 알람을 모두 지웠습니다.');
    } catch (_) {
      if (mounted) {
        AppSnack.show(context, '알람을 모두 지우지 못했습니다. 다시 시도해 주세요.', error: true);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (mounted) await _reload();
  }

  List<Widget> _rows(List<UpcomingReminder> reminders, {required bool past}) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    DateTime? previousDay;
    for (final r in reminders) {
      final date = r.scheduledAt.toLocal();
      final day = DateUtils.dateOnly(date);
      if (day != previousDay) {
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '${Fmt.date(day)} · ${Fmt.monthDay(day)}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        );
        previousDay = day;
      }
      final color = past ? scheme.onSurfaceVariant : scheme.onSurface;
      rows.add(
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: color),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5, right: 8),
                        child: Icon(
                          Icons.circle,
                          size: 10,
                          color: past
                              ? scheme.outline
                              : parseHexColor(r.color ?? '', scheme.primary),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          r.title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('${Fmt.time(date)} · ${r.offsetMinutes}분 전'),
                  Text(
                    '일정 시작: ${Fmt.dateTime(r.startsAt.toLocal())}${r.allDay ? ' · 종일' : ''}',
                  ),
                  if (r.location?.isNotEmpty == true) Text('장소: ${r.location}'),
                  Text('캘린더: ${r.calendarName ?? '-'}'),
                  const SizedBox(height: 6),
                  StatusChip(
                    label: _scheduled == null
                        ? '예약 확인 불가'
                        : _scheduled!.contains(r.alarmId)
                        ? '예약됨'
                        : '예약 안 됨',
                    color:
                        past ||
                            _scheduled == null ||
                            !_scheduled!.contains(r.alarmId)
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                    dense: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final reminders = [..._snapshot.reminders]
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    final upcoming = reminders
        .where((r) => r.scheduledAt.isAfter(now))
        .toList();
    final past = reminders.where((r) => !r.scheduledAt.isAfter(now)).toList();
    final syncedAt = _snapshot.syncedAt;
    return Scaffold(
      appBar: AppBar(
        title: const Text('이 폰의 알람'),
        actions: [
          IconButton(
            tooltip: '연결·예약 상태 새로 고침',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            enabled: !_deleting && !_syncing,
            onSelected: (_) => _deleteAll(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'deleteAll',
                child: Text(
                  '이 폰의 알람 모두 지우기',
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: PageBody(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Text(
                  '마지막 동기화: ${syncedAt == null ? '없음' : '${Fmt.monthDay(syncedAt)} ${Fmt.time(syncedAt)}'}',
                ),
                const SizedBox(height: 8),
                Wrap(
                  children: [
                    StatusChip(
                      label: _reachable == null
                          ? '서버 연결 확인 중'
                          : _reachable!
                          ? '서버 연결됨'
                          : '연결 안 됨(사내망·VPN 확인)',
                      color: _reachable == true
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      dense: true,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          !_syncing &&
                              !_deleting &&
                              _reachable == true &&
                              auth.phase == AuthPhase.ready
                          ? _sync
                          : null,
                      icon: const Icon(Icons.sync, size: 18),
                      label: Text(_syncing ? '동기화 중…' : '다시 동기화'),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AlarmSettingsPage(),
                          ),
                        );
                        if (mounted) _reload();
                      },
                      child: const Text('알람 설정'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (reminders.isEmpty && _error == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '동기화된 알람이 없습니다. 사내망이나 VPN 에 연결한 뒤 로그인하면 받아 옵니다.',
                    ),
                  ),
                ..._rows(upcoming, past: false),
                if (past.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    '지난 알람',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  ..._rows(past, past: true),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
