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
}
