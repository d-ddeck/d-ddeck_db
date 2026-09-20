import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/calendar.dart';

/// 일정 알람을 기기 자체에 예약한다.
///
/// 서버 푸시가 아니라 OS 알람 스케줄러를 쓰는 이유: 외근 중인 직원은 네트워크나
/// VPN 이 끊겨 있을 수 있고, 바로 그때 알림이 필요하다. 한 번 예약해 두면
/// 서버가 꺼져 있어도, 비행기 모드여도 울린다.
///
/// 서버 알림(Notification 행)은 "무엇이 바뀌었는지"를 나르고, 이쪽은
/// "제때 울리는" 역할을 맡는다. 둘은 서로 대체재가 아니다.
class AlarmService {
  AlarmService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const _channelId = 'ddeck_event_alarm';
  static const _channelName = '일정 알림';
  static const _channelDescription = '등록된 일정의 시작 전 알림';

  bool _ready = false;
  bool get isReady => _ready;

  /// 알람을 탭했을 때 열어야 할 화면. 앱이 처리한다.
  void Function(String eventId)? onAlarmTapped;

  /// 이 플랫폼에서 예약 알람을 쓸 수 있는가.
  ///
  /// flutter_local_notifications 18 은 Windows 를 지원하지 않고, Linux 는
  /// 즉시 알림만 되고 예약(zonedSchedule)은 없다. 지원하지 않는 곳에서 조용히
  /// 실패하는 대신 명시적으로 꺼서, 설정 화면이 "이 기기에서는 사용할 수
  /// 없습니다" 라고 말할 수 있게 한다.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  /// 지원하지 않는 플랫폼에서 화면에 표시할 안내.
  static String get unsupportedReason {
    if (kIsWeb) return '웹에서는 일정 알람을 사용할 수 없습니다.';
    if (Platform.isWindows) {
      return 'Windows 데스크톱은 아직 일정 알람을 지원하지 않습니다. '
          '휴대폰 앱에서 알림을 받으세요.';
    }
    if (Platform.isLinux) {
      return 'Linux 데스크톱은 아직 일정 알람을 지원하지 않습니다. '
          '휴대폰 앱에서 알림을 받으세요.';
    }
    return '이 기기에서는 일정 알람을 사용할 수 없습니다.';
  }

  Future<void> init() async {
    if (_ready || !isSupported) return;

    try {
      tzdata.initializeTimeZones();
      // 알람은 사용자의 벽시계 기준이어야 한다. 서버가 주는 UTC 를 이 존으로
      // 변환해 예약한다.
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (e) {
      // 타임존을 못 잡아도 tz.local 은 UTC 로 동작한다. 알람이 몇 시간 어긋날
      // 수 있으므로 로그를 남기되, 앱을 멈추지는 않는다.
      debugPrint('알람: 타임존 초기화 실패, UTC 기준으로 진행합니다 ($e)');
    }

    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (response) {
          final eventId = response.payload;
          if (eventId != null && eventId.isNotEmpty) {
            onAlarmTapped?.call(eventId);
          }
        },
      );
      _ready = true;
    } catch (e) {
      debugPrint('알람: 초기화 실패 ($e)');
    }
  }

  /// 알림 권한을 요청한다. Android 13+ 와 iOS 에서 필요하다.
  ///
  /// 거부당해도 앱은 정상 동작해야 하므로 결과만 돌려준다.
  Future<bool> requestPermissions() async {
    if (!isSupported) return false;
    if (!_ready) await init();
    try {
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        if (android == null) return false;
        final granted = await android.requestNotificationsPermission() ?? false;
        // 정확한 시각 알람은 Android 12+ 에서 별도 권한이다. 없으면 OS 가
        // 알람을 몇 분에서 몇십 분까지 미룰 수 있어, 회의 알림으로는 쓸모가
        // 떨어진다. 거부당해도 예약 자체는 하되 inexact 로 떨어진다.
        final exact = await android.requestExactAlarmsPermission() ?? false;
        if (!exact) {
          debugPrint('알람: 정확한 알람 권한 없음 - 울리는 시각이 밀릴 수 있습니다');
        }
        return granted;
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(alert: true, sound: true) ?? true;
    } catch (e) {
      debugPrint('알람: 권한 요청 실패 ($e)');
      return false;
    }
  }

  /// Android 에서 정확한 시각 알람이 허용돼 있는지. 설정 화면의 경고용.
  Future<bool> hasExactAlarmPermission() async {
    if (!isSupported || !Platform.isAndroid) return true;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 서버가 준 예약 목록으로 기기 알람을 통째로 맞춘다.
  ///
  /// 증분 갱신이 아니라 전부 지우고 다시 거는 방식이다. 일정이 삭제·변경됐을 때
  /// 남은 알람이 유령처럼 울리는 것을 막는 가장 확실한 방법이고, 건수가 수십 개
  /// 수준이라 비용도 문제되지 않는다.
  Future<int> sync(List<UpcomingReminder> reminders) async {
    if (!isSupported) return 0;
    if (!_ready) await init();
    if (!_ready) return 0;

    await cancelAll();

    final now = DateTime.now();
    var scheduled = 0;
    for (final r in reminders) {
      // 이미 지난 알람은 예약할 수 없다. 서버도 걸러 주지만, 동기화 도중
      // 시간이 지나는 경우가 있어 여기서도 본다.
      if (!r.scheduledAt.isAfter(now)) continue;
      if (await _schedule(r)) scheduled++;
    }
    debugPrint('알람: ${reminders.length}건 중 $scheduled건 예약');
    return scheduled;
  }

  Future<bool> _schedule(UpcomingReminder r) async {
    try {
      await _plugin.zonedSchedule(
        r.alarmId,
        r.title,
        r.body,
        tz.TZDateTime.from(r.scheduledAt, tz.local),
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.max,
            priority: Priority.high,
            // 시계 앱처럼 소리와 진동을 함께 낸다.
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.reminder,
            color: r.color == null ? null : parseHexColor(r.color!),
            styleInformation: BigTextStyleInformation(
              r.body,
              contentTitle: r.title,
              summaryText: r.calendarName,
            ),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
        ),
        // 절전(Doze) 상태에서도 정해진 시각에 울려야 한다.
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: r.eventId,
      );
      return true;
    } catch (e) {
      // 정확한 알람 권한이 없으면 여기서 실패할 수 있다. 한 건이 실패해도
      // 나머지는 계속 예약한다.
      debugPrint('알람 예약 실패 (${r.title}): $e');
      return false;
    }
  }

  Future<void> cancelAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('알람: 전체 취소 실패 ($e)');
    }
  }

  /// 예약된 알람 목록. 설정 화면에서 "몇 건이 걸려 있는지" 보여줄 때 쓴다.
  Future<List<PendingNotificationRequest>> pending() async {
    if (!_ready) return const [];
    try {
      return await _plugin.pendingNotificationRequests();
    } catch (e) {
      debugPrint('알람: 목록 조회 실패 ($e)');
      return const [];
    }
  }

  /// 설정 화면의 "테스트 알림" 버튼. 권한과 소리를 바로 확인할 수 있다.
  Future<void> showTest() async {
    if (!isSupported) return;
    if (!_ready) await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        0,
        '알림 테스트',
        '이렇게 일정 시작 전에 알려드립니다.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.max,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('알람: 테스트 알림 실패 ($e)');
    }
  }
}
