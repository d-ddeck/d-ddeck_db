import 'dart:io';

import 'package:ddeck_app/core/config.dart';
import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/service.dart';
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
      expect(
        parsed.toUtc(),
        DateTime.utc(2026, 9, 20, 7, 30),
      );
    });

    test('PagedList accepts both the envelope and a bare array', () {
      final envelope = PagedList.fromJson(
        {
          'items': [
            {'id': '1', 'code': 'A', 'name': '분류A'},
          ],
          'total': 7,
          'page': 1,
          'size': 1,
          'pages': 7,
        },
        CodeItem.fromJson,
      );
      expect(envelope.total, 7);
      expect(envelope.hasMore, isTrue);

      final bare = PagedList.fromJson(
        [
          {'id': '1', 'code': 'A', 'name': '분류A'},
        ],
        CodeItem.fromJson,
      );
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

    File cfg() => File('${dir.path}${Platform.pathSeparator}'
        '${AppConfig.siteConfigFileName}');

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
}
