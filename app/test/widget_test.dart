import 'dart:io';

import 'package:ddeck_app/core/config.dart';
import 'package:ddeck_app/core/token_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/calendar.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/services/alarm_service.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig.normalizeServerUrl', () {
    test('adds a scheme when the user types a bare host', () {
      expect(
        AppConfig.normalizeServerUrl('192.168.0.10:8000'),
        'http://192.168.0.10:8000',
      );
    });

    test('strips a trailing slash', () {
      expect(
        AppConfig.normalizeServerUrl('http://10.0.0.5:8000/'),
        'http://10.0.0.5:8000',
      );
    });

    test('tolerates a pasted API path or docs link', () {
      expect(
        AppConfig.normalizeServerUrl('http://srv:8000/api/v1'),
        'http://srv:8000',
      );
      expect(
        AppConfig.normalizeServerUrl('http://srv:8000/docs'),
        'http://srv:8000',
      );
    });

    test('falls back to the platform default when empty', () {
      expect(AppConfig.normalizeServerUrl('  '), AppConfig.defaultServerUrl);
    });
  });

  group('JSON helpers', () {
    test('Decimal fields arrive as strings and still parse', () {
      // The server serialises Decimal as a string, so a naive `as num` would
      // throw. This is the guard for that.
      expect(asDouble('150000.00'), 150000.0);
      expect(asDouble(42), 42.0);
      expect(asDouble(null), isNull);
      expect(asDouble('not a number'), isNull);
    });

    test('UTC timestamps are converted to local time', () {
      final parsed = asDate('2026-09-20T07:30:00+00:00');
      expect(parsed, isNotNull);
      expect(parsed!.isUtc, isFalse);
      expect(parsed.toUtc(), DateTime.utc(2026, 9, 20, 7, 30));
    });

    test('PagedList accepts both the envelope and a bare array', () {
      final envelope = PagedList.fromJson({
        'items': [
          {'id': '1', 'code': 'A', 'name': '분류A'},
        ],
        'total': 7,
        'page': 1,
        'size': 1,
        'pages': 7,
      }, CodeItem.fromJson);
      expect(envelope.total, 7);
      expect(envelope.hasMore, isTrue);

      final bare = PagedList.fromJson([
        {'id': '1', 'code': 'A', 'name': '분류A'},
      ], CodeItem.fromJson);
      expect(bare.total, 1);
      expect(bare.hasMore, isFalse);
    });
  });

  group('Role ladder', () {
    test('matches the server hierarchy', () {
      expect(Role.superadmin.atLeast(Role.admin), isTrue);
      expect(Role.admin.atLeast(Role.manager), isTrue);
      expect(Role.member.atLeast(Role.manager), isFalse);
    });

    test('unknown values fall back to MEMBER rather than throwing', () {
      expect(Role.parse('NOT_A_ROLE'), Role.member);
      expect(Role.parse(null), Role.member);
    });
  });

  group('ServiceStatus', () {
    test('open states exclude completed and canceled', () {
      expect(ServiceStatus.inProgress.isOpen, isTrue);
      expect(ServiceStatus.completed.isOpen, isFalse);
      expect(ServiceStatus.canceled.isOpen, isFalse);
    });

    test('offers only sensible next transitions', () {
      expect(
        ServiceStatus.received.nextOptions,
        isNot(contains(ServiceStatus.completed)),
      );
      expect(
        ServiceStatus.inProgress.nextOptions,
        contains(ServiceStatus.completed),
      );
    });
  });

  group('ServiceTicket', () {
    test('parses a server payload including string decimals', () {
      final t = ServiceTicket.fromJson({
        'id': 'abc',
        'ticket_no': 'AS-202609-0001',
        'title': '컴프레서 수리',
        'status': 'IN_PROGRESS',
        'priority': 'HIGH',
        'channel': 'PHONE',
        'received_at': '2026-09-01T00:00:00+00:00',
        'due_at': '2026-09-04T00:00:00+00:00',
        'total_cost': '150000.00',
        'customer_name': '대한산업',
      });
      expect(t.ticketNo, 'AS-202609-0001');
      expect(t.status, ServiceStatus.inProgress);
      expect(t.totalCost, 150000.0);
      expect(t.customerLabel, '대한산업');
      // Due date is in the past and the ticket is still open.
      expect(t.isOverdue, isTrue);
    });

    test('falls back when the customer is not set at all', () {
      final t = ServiceTicket.fromJson({
        'id': 'x',
        'ticket_no': 'AS-1',
        'title': 't',
        'status': 'RECEIVED',
        'priority': 'NORMAL',
        'channel': 'WEB',
        'received_at': '2026-09-01T00:00:00+00:00',
      });
      expect(t.customerLabel, '거래처 미지정');
      expect(t.isOverdue, isFalse);
    });
  });

  group('설치 프로그램이 쓴 서버 설정 (ddeck.config.json)', () {
    late Directory dir;

    setUp(() async {
      AppConfig.resetSiteConfig();
      dir = await Directory.systemTemp.createTemp('ddeck_cfg');
    });
    tearDown(() async {
      AppConfig.resetSiteConfig();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    File cfg() => File(
      '${dir.path}${Platform.pathSeparator}'
      '${AppConfig.siteConfigFileName}',
    );

    test('설치 시 기록된 주소를 기본값으로 채택한다', () async {
      await cfg().writeAsString('{"server_url": "http://192.168.0.99:9000"}');
      await AppConfig.loadSiteConfig(directory: dir.path);
      expect(AppConfig.siteServerUrl, 'http://192.168.0.99:9000');
      expect(AppConfig.defaultServerUrl, 'http://192.168.0.99:9000');
    });

    test('스킴 없이 적어도 정규화된다', () async {
      await cfg().writeAsString('{"server_url": "miniserver.local:8000/"}');
      await AppConfig.loadSiteConfig(directory: dir.path);
      expect(AppConfig.siteServerUrl, 'http://miniserver.local:8000');
    });

    test('파일이 없으면 플랫폼 기본값으로 떨어진다', () async {
      await AppConfig.loadSiteConfig(directory: dir.path);
      expect(AppConfig.siteServerUrl, isNull);
      expect(AppConfig.defaultServerUrl, isNotEmpty);
    });

    test('깨진 파일이어도 앱이 죽지 않는다', () async {
      // IT 가 손으로 고치다 JSON 을 깨뜨리는 일은 실제로 일어난다.
      await cfg().writeAsString('{ 이건 JSON 이 아님');
      await AppConfig.loadSiteConfig(directory: dir.path);
      expect(AppConfig.siteServerUrl, isNull);
    });

    test('server_url 이 비어 있으면 무시한다', () async {
      await cfg().writeAsString('{"server_url": "   "}');
      await AppConfig.loadSiteConfig(directory: dir.path);
      expect(AppConfig.siteServerUrl, isNull);
    });
  });

  group('자동 로그인 (TokenStore)', () {
    // 실제 OS 키스토어 대신 메모리 맵으로 대체해, 기기 없이도 저장 규칙을
    // 그대로 검증한다.
    late Map<String, String> disk;
    late TokenStore store;

    setUp(() {
      disk = {};
      store = TokenStore(_FakeSecureStorage(disk));
    });

    test('자동 로그인 켜면 리프레시 토큰이 디스크에 남는다', () async {
      await store.saveSession(
        accessToken: 'A',
        refreshToken: 'R',
        remember: true,
        email: 'a@b.co',
      );
      expect(disk['refresh_token'], 'R');
      expect(await store.readRefreshToken(), 'R');
      expect(await store.readRememberMe(), isTrue);
    });

    test('자동 로그인 끄면 디스크에 남지 않는다', () async {
      await store.saveSession(
        accessToken: 'A',
        refreshToken: 'R',
        remember: false,
      );
      expect(
        disk.containsKey('refresh_token'),
        isFalse,
        reason: '공용 PC 에서 다음 사람이 그대로 들어가면 안 된다',
      );
      expect(await store.readRememberMe(), isFalse);
    });

    test('자동 로그인을 꺼도 현재 세션은 유지된다', () async {
      await store.saveSession(
        accessToken: 'A',
        refreshToken: 'R',
        remember: false,
      );
      // 디스크에는 없지만 메모리에는 있어야 한다. 없으면 액세스 토큰이
      // 만료되는 60분 뒤 사용 중에 튕긴다.
      expect(await store.readRefreshToken(), 'R');
    });

    test('끈 상태로 로그인하면 이전에 저장된 토큰이 지워진다', () async {
      await store.saveSession(
        accessToken: 'A1',
        refreshToken: 'R1',
        remember: true,
      );
      expect(disk['refresh_token'], 'R1');

      final store2 = TokenStore(_FakeSecureStorage(disk));
      await store2.saveSession(
        accessToken: 'A2',
        refreshToken: 'R2',
        remember: false,
      );
      expect(
        disk.containsKey('refresh_token'),
        isFalse,
        reason: '이전 세션 토큰이 남아 자동 로그인되면 안 된다',
      );
    });

    test('로그아웃해도 이메일과 서버 주소는 남는다', () async {
      await store.saveServerUrl('http://192.168.0.20:8000');
      await store.saveSession(
        accessToken: 'A',
        refreshToken: 'R',
        remember: true,
        email: 'a@b.co',
      );
      await store.clearSession();

      expect(await store.readRefreshToken(), isNull);
      expect(store.accessToken, isNull);
      expect(await store.readLastEmail(), 'a@b.co');
      expect(await store.readServerUrl(), 'http://192.168.0.20:8000');
    });

    test('설정이 없으면 자동 로그인은 켜진 상태가 기본', () async {
      expect(await store.readRememberMe(), isTrue);
    });
  });

  group('일정 알람 (UpcomingReminder)', () {
    Map<String, dynamic> payload({
      int offset = 30,
      bool allDay = false,
      String? location = '2층 회의실',
    }) => {
      'reminder_id': 'r-1',
      'event_id': 'e-1',
      'title': '주간 업무 회의',
      'location': location,
      'starts_at': '2026-09-21T01:00:00+00:00',
      'ends_at': '2026-09-21T02:00:00+00:00',
      'all_day': allDay,
      'scheduled_at': '2026-09-21T00:30:00+00:00',
      'offset_minutes': offset,
      'color': '#3B82F6',
      'calendar_name': '공유 캘린더',
    };

    test('서버 응답을 파싱하고 UTC 를 로컬로 바꾼다', () {
      final r = UpcomingReminder.fromJson(payload());
      expect(r.title, '주간 업무 회의');
      expect(r.offsetMinutes, 30);
      expect(r.scheduledAt.isUtc, isFalse, reason: '알람은 기기 로컬 시각으로 건다');
      expect(r.scheduledAt.toUtc(), DateTime.utc(2026, 9, 21, 0, 30));
      // 알림 시각은 시작 시각보다 offset 만큼 앞서야 한다.
      expect(r.startsAt.difference(r.scheduledAt).inMinutes, r.offsetMinutes);
    });

    test('알람 id 는 안정적이고 32비트 양수', () {
      final a = UpcomingReminder.fromJson(payload());
      final b = UpcomingReminder.fromJson(payload());
      // 같은 예약은 같은 id 여야 재동기화 때 중복으로 걸리지 않는다.
      expect(a.alarmId, b.alarmId);
      expect(a.alarmId, inInclusiveRange(0, 0x7FFFFFFF));
    });

    test('알림 문구에 시작 시각과 남은 시간이 들어간다', () {
      final r = UpcomingReminder.fromJson(payload());
      expect(r.body, contains('30분 뒤'));
      expect(r.body, contains('2층 회의실'));
    });

    test('리드타임을 사람이 읽는 단위로 바꾼다', () {
      expect(
        UpcomingReminder.fromJson(payload(offset: 0)).body,
        contains('지금 시작'),
      );
      expect(
        UpcomingReminder.fromJson(payload(offset: 60)).body,
        contains('1시간 뒤'),
      );
      expect(
        UpcomingReminder.fromJson(payload(offset: 1440)).body,
        contains('1일 뒤'),
      );
    });

    test('종일 일정과 장소 없는 일정도 문구가 깨지지 않는다', () {
      final r = UpcomingReminder.fromJson(
        payload(allDay: true, location: null),
      );
      expect(r.body, contains('오늘'));
      expect(r.body, isNot(contains('·')));
    });

    test('지원하지 않는 플랫폼에도 안내 문구가 있다', () {
      // 비어 있으면 설정 화면이 빈 칸을 보여준다.
      expect(AlarmService.unsupportedReason, isNotEmpty);
    });
  });
}

/// 테스트용 보안 저장소. 실제 구현은 플랫폼 채널이 필요해 위젯 테스트에서
/// 동작하지 않으므로, 같은 인터페이스로 메모리에 저장한다.
class _FakeSecureStorage implements FlutterSecureStorage {
  _FakeSecureStorage(this.data);
  final Map<String, String> data;

  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    data.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
