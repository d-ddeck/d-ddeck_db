import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:alarm/alarm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/calendar.dart';
import 'alarm_prefs.dart';
import 'synced_alarm_store.dart';

/// Android의 네이티브 알람을 사용한다. 모든 변경은 하나의 큐에서 실행한다.
class AlarmService with WidgetsBindingObserver {
  AlarmService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final prefs = AlarmPrefs();
  final active = ValueNotifier<AlarmSettings?>(null);
  final ringingIds = ValueNotifier<Set<int>>({});
  Future<void> _queue = Future<void>.value();
  Future<void>? _initializing;
  bool _ready = false;
  bool get isReady => _ready;
  void Function(String eventId)? onAlarmTapped;
  Future<void> Function()? onStopped;
  static const _permissions = MethodChannel('ddeck/alarm_permissions');
  static bool get isSupported => !kIsWeb && Platform.isAndroid;
  static String get unsupportedReason =>
      '이 기기에서는 일정 알람을 지원하지 않습니다. Android 휴대폰 앱을 사용해 주세요.';

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {
        debugPrint('알람: $e');
      },
    );
    return next;
  }

  Future<void> init() async {
    if (!isSupported || _ready) return;
    await (_initializing ??= _initialize());
  }

  Future<void> _initialize() async {
    try {
      await prefs.load();
      await Alarm.init();
      Alarm.ringing.listen((set) {
        final previous = ringingIds.value;
        ringingIds.value = set.alarms.map((a) => a.id).toSet();
        if (set.alarms.isNotEmpty) active.value = set.alarms.first;
        if (previous.difference(ringingIds.value).isNotEmpty) {
          // 동기화는 큐 뒤에 들어간다. 다시 울림 예약도 그 전에 저장된다.
          onStopped?.call();
        }
      });
      Alarm.events.listen((event) {
        if (event is AlarmMoved && event.cause == AlarmEventCause.snooze) {
          closeRing(event.id);
        }
      });
      if (await Alarm.isRinging()) {
        for (final alarm in await Alarm.getAlarms()) {
          if (await Alarm.isRinging(alarm.id)) {
            active.value = alarm;
            ringingIds.value = {...ringingIds.value, alarm.id};
          }
        }
      }
      _ready = true;
      WidgetsBinding.instance.addObserver(this);
      // 이전 버전의 예약만 정리한다. 새 일정 예약에는 이 플러그인을 쓰지 않는다.
      try {
        await _plugin.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        for (final legacy in await _plugin.pendingNotificationRequests()) {
          await _plugin.cancel(legacy.id);
        }
      } catch (e) {
        debugPrint('이전 알림 정리 실패: $e');
      }
    } catch (e) {
      _initializing = null;
      debugPrint('알람 초기화 실패: $e');
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<bool> requestPermissions() async {
    if (!isSupported) return false;
    await init();
    try {
      final granted = await _android?.requestNotificationsPermission() ?? false;
      await _android?.requestExactAlarmsPermission();
      return granted;
    } catch (_) {
      return false;
    }
  }

  // MaterialApp보다 먼저 등록하여 시스템 뒤로 가기도 울림 화면에서 소비한다.
  @override
  Future<bool> didPopRoute() async => active.value != null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refreshRinging().catchError((Object e) => debugPrint('알람 상태 확인 실패: $e'));
    }
  }

  Future<void> refreshRinging() async {
    if (!isSupported || !_ready) return;
    await _serial(() => Alarm.checkAlarm());
  }

  Future<bool> hasExactAlarmPermission() async {
    if (!isSupported) return false;
    try {
      return await _android?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasNotificationPermission() async {
    if (!isSupported) return false;
    try {
      return await _android?.areNotificationsEnabled() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasFullScreenPermission() async {
    if (!isSupported) return false;
    try {
      return await _permissions.invokeMethod<bool>('fullScreenAllowed') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestFullScreenPermission() async {
    if (isSupported) await _android?.requestFullScreenIntentPermission();
  }

  static Map<String, dynamic> metadata(AlarmSettings alarm) {
    try {
      return jsonDecode(alarm.payload ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  AlarmSettings _settings(int id, DateTime date, Map<String, dynamic> data) =>
      AlarmSettings(
        id: id,
        dateTime: date,
        assetAudioPath: 'assets/sounds/alarm.wav',
        loopAudio: prefs.loopAudio,
        vibrate: prefs.vibrate,
        androidFullScreenIntent: true,
        androidStopAlarmOnTermination: false,
        allowSameSecondScheduling: true,
        warningNotificationOnKill: false,
        androidSnoozeDuration: Duration(minutes: prefs.snoozeMinutes),
        volumeSettings: VolumeSettings.fade(
          volume: prefs.sound ? prefs.volume : 0.0,
          fadeDuration: const Duration(seconds: 3),
          volumeEnforced: !prefs.sound,
        ),
        notificationSettings: NotificationSettings(
          title: '일정 알림 · ${data['title']}',
          body: '${data['startsLabel']} ${data['location'] ?? ''}',
          stopButton: '끄기',
          androidSnoozeButton: '${prefs.snoozeMinutes}분 뒤 다시',
          androidStopAlarmOnDismiss: false,
          icon: 'mipmap/ic_launcher',
        ),
        payload: jsonEncode(data),
      );

  Future<int> sync(
    List<UpcomingReminder> reminders, {
    required String ownerUserId,
  }) async {
    if (!isSupported) return 0;
    await init();
    if (!_ready) throw StateError('알람을 초기화하지 못했습니다.');
    return _serial(() async {
      final snapshot = await SyncedAlarmStore().load();
      if (snapshot.syncedAt != null && snapshot.ownerUserId != ownerUserId) {
        // 다른 계정의 울림·다시 울림 예약도 새 계정으로 교체한다.
        await _stopAll();
      }
      if (!prefs.enabled) {
        await _stopAll();
        await SyncedAlarmStore().save(reminders, ownerUserId: ownerUserId);
        return 0;
      }
      final desired = <int, AlarmSettings>{};
      for (final r in reminders) {
        if (!r.scheduledAt.isAfter(DateTime.now())) continue;
        final start = r.startsAt.toLocal();
        desired[r.alarmId] = _settings(r.alarmId, r.scheduledAt, {
          'eventId': r.eventId,
          'title': r.title,
          'startsAt': start.toIso8601String(),
          'startsLabel':
              '${start.month}/${start.day} ${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}',
          'location': r.location,
          'calendarName': r.calendarName,
          'color': r.color,
          'scheduledAt': r.scheduledAt.toIso8601String(),
        });
      }
      final retained = <int>{};
      for (final alarm in await Alarm.getAlarms()) {
        if (shouldRetainAlarm(
          alarm,
          desired[alarm.id],
          ringing: await Alarm.isRinging(alarm.id),
          now: DateTime.now(),
        )) {
          retained.add(alarm.id);
        } else {
          await Alarm.stop(alarm.id);
        }
      }
      var count = retained.length;
      for (final entry in desired.entries) {
        if (retained.contains(entry.key)) continue;
        try {
          if (await Alarm.set(alarmSettings: entry.value)) count++;
        } catch (e) {
          debugPrint('알람 예약 실패: $e');
        }
      }
      await SyncedAlarmStore().save(reminders, ownerUserId: ownerUserId);
      return count;
    });
  }

  @visibleForTesting
  static bool shouldRetainAlarm(
    AlarmSettings alarm,
    AlarmSettings? next, {
    required bool ringing,
    required DateTime now,
  }) {
    final data = metadata(alarm);
    final scheduled = DateTime.tryParse(data['scheduledAt']?.toString() ?? '');
    final snoozed =
        scheduled != null &&
        scheduled.millisecondsSinceEpoch !=
            alarm.dateTime.millisecondsSinceEpoch;
    return ringing ||
        (alarm.dateTime.isAfter(now) && (data['test'] == true || snoozed)) ||
        (next != null && sameAlarmSchedule(alarm, next));
  }

  @visibleForTesting
  static bool sameAlarmSchedule(AlarmSettings current, AlarmSettings next) {
    Map<String, dynamic> normalized(AlarmSettings alarm) {
      final json = Map<String, dynamic>.of(alarm.toJson());
      json['dateTime'] = alarm.dateTime.millisecondsSinceEpoch;
      final data = Map<String, dynamic>.of(metadata(alarm));
      for (final key in ['scheduledAt', 'startsAt']) {
        final value = DateTime.tryParse(data[key]?.toString() ?? '');
        if (value != null) data[key] = value.millisecondsSinceEpoch;
      }
      json['payload'] = data;
      return json;
    }

    return jsonEncode(normalized(current)) == jsonEncode(normalized(next));
  }

  Future<void> _stopAll() async {
    // 일괄 삭제를 사용자 개별 중지로 보아 즉시 재동기화하지 않는다.
    ringingIds.value = {};
    await Alarm.stopAll();
    active.value = null;
  }

  Future<void> cancelAll() => _clearAll();

  /// 설정의 '알람 사용'을 끌 때도 기존처럼 예약과 저장본을 지운다.
  Future<void> applyDisabledPreference() async {
    if (!prefs.enabled) await _clearAll();
  }

  Future<void> _clearAll() async {
    if (!isSupported) return;
    await init();
    await _serial(() async {
      try {
        if (_ready) await _stopAll();
        active.value = null;
      } finally {
        await SyncedAlarmStore().clear();
      }
    });
  }

  Future<List<PendingNotificationRequest>> pending() async {
    if (!isSupported || !_ready) return [];
    return _serial(
      () async => (await Alarm.getAlarms())
          .map(
            (a) => PendingNotificationRequest(
              a.id,
              a.notificationSettings.title,
              '${a.dateTime.toLocal()} · ${a.notificationSettings.body}',
              a.payload,
            ),
          )
          .toList(),
    );
  }

  Future<void> stop(int id) async {
    if (!isSupported) return;
    await _serial(() async {
      if (!await Alarm.stop(id)) throw StateError('알람을 끄지 못했습니다. 다시 시도해 주세요.');
    });
  }

  Future<void> snooze(AlarmSettings alarm) async {
    if (!isSupported) return;
    await _serial(() async {
      if (!await Alarm.stop(alarm.id)) throw StateError('알람 중지 실패');
      final next = alarm.copyWith(
        dateTime: DateTime.now().add(
          alarm.androidSnoozeDuration ?? Duration(minutes: prefs.snoozeMinutes),
        ),
      );
      if (!await Alarm.set(alarmSettings: next)) {
        await Alarm.set(
          alarmSettings: alarm.copyWith(dateTime: DateTime.now()),
        );
        throw StateError('다시 울림 예약 실패');
      }
    });
  }

  void closeRing(int id) {
    if (active.value?.id == id) active.value = null;
  }

  Future<void> showTest() async {
    if (!isSupported) return;
    await init();
    if (!_ready || !prefs.enabled) throw StateError('알람 사용을 먼저 켜주세요.');
    await _serial(() async {
      final date = DateTime.now().add(const Duration(seconds: 10));
      if (!await Alarm.set(
        alarmSettings: _settings(-100, date, {
          'test': true,
          'title': '테스트 알람',
          'startsLabel': '10초 뒤 테스트',
          'scheduledAt': date.toIso8601String(),
        }),
      )) {
        throw StateError('테스트 알람 예약 실패. 권한을 확인해 주세요.');
      }
    });
  }
}
