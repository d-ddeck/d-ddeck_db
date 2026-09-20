/// Live contract test: drives the real backend through the real client stack.
///
/// Unit tests prove the parsers handle a payload we wrote down; this proves the
/// payload the server actually sends still matches. It is the check that
/// catches a field rename on the backend before the UI does.
///
/// Requires a running server with demo data:
///   cd ../backend && python scripts/seed_demo.py
///   uvicorn app.main:app --host 127.0.0.1 --port 8000
///
/// Run:  flutter test test/api_contract_test.dart
/// The whole group is skipped when nothing answers on the port, so this stays
/// safe in CI without a backend.
library;

import 'dart:io';

import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/core/token_store.dart';
import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/data/auth_repository.dart';
import 'package:ddeck_app/data/board_repository.dart';
import 'package:ddeck_app/data/calendar_repository.dart';
import 'package:ddeck_app/data/inventory_repository.dart';
import 'package:ddeck_app/data/service_repository.dart';
import 'package:ddeck_app/models/admin.dart';
import 'package:ddeck_app/models/inventory.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:flutter_test/flutter_test.dart';

const serverUrl = 'http://127.0.0.1:8000';
const demoEmail = 'seojun.kim@ddeck.local';
const demoPassword = 'demo1234';

Future<bool> serverIsUp() async {
  try {
    final socket = await Socket.connect('127.0.0.1', 8000,
        timeout: const Duration(milliseconds: 600));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  // flutter_secure_storage has no implementation in the test harness. TokenStore
  // already degrades to "not stored" on failure, so the in-memory access token
  // is enough to exercise every authenticated call.
  TestWidgetsFlutterBinding.ensureInitialized();

  // The test binding installs an HttpOverrides that answers every request with
  // a canned 400 so unit tests cannot hit the network by accident. This suite
  // is deliberately the exception, so clear it.
  HttpOverrides.global = null;

  // Decided before the group is declared, so a missing backend skips
  // cleanly instead of failing every test with a connection error.
  final up = await serverIsUp();
  final skipReason =
      up ? null : 'backend not running on $serverUrl - skipping live contract tests';

  late ApiClient api;
  late AuthRepository authRepo;
  late ServiceRepository serviceRepo;
  late InventoryRepository inventoryRepo;
  late BoardRepository boardRepo;
  late CalendarRepository calendarRepo;
  late AdminRepository adminRepo;
  late UserProfile me;

  setUpAll(() async {
    if (!up) return;
    api = ApiClient(tokenStore: TokenStore());
    await api.setServerUrl(serverUrl, persist: false);
    authRepo = AuthRepository(api);
    serviceRepo = ServiceRepository(api);
    inventoryRepo = InventoryRepository(api);
    boardRepo = BoardRepository(api);
    calendarRepo = CalendarRepository(api);
    adminRepo = AdminRepository(api);

    final session = await authRepo.login(demoEmail, demoPassword);
    api.tokenStore.accessToken = session.accessToken;
    me = session.user;
  });

  group('live backend contract', () {
    test('healthz answers before anything else', () async {
      expect(await api.ping(), isTrue);
    });

    test('login returns a usable session and profile', () {
      expect(me.email, demoEmail);
      expect(me.role, Role.admin);
      expect(me.status, UserStatus.approved);
      expect(me.fullName, isNotEmpty);
    });

    test('/auth/me round-trips the same account', () async {
      final profile = await authRepo.me();
      expect(profile.id, me.id);
      expect(profile.departmentName, isNotNull,
          reason: 'demo users belong to a department');
    });

    test('ticket list parses, including string decimals', () async {
      final page = await serviceRepo.list(size: 20);
      expect(page.total, greaterThan(0));
      expect(page.items, isNotEmpty);

      final t = page.items.first;
      expect(t.ticketNo, isNotEmpty);
      expect(t.status, isA<ServiceStatus>());
      // received_at is required on the server, so it must never fall back.
      expect(t.receivedAt.year, greaterThan(2000));

      final priced = page.items.where((x) => x.totalCost != null);
      if (priced.isNotEmpty) {
        expect(priced.first.totalCost, greaterThan(0));
      }
    });

    test('ticket detail carries joined parts and logs', () async {
      final page = await serviceRepo.list(size: 20);
      final detail = await serviceRepo.get(page.items.first.id);
      expect(detail.logs, isNotEmpty,
          reason: 'every ticket gets an intake log row');
    });

    test('statistics summary is internally consistent', () async {
      final s = await serviceRepo.summary();
      expect(s.total, greaterThan(0));
      expect(
        s.completedCount + s.openCount + s.canceledCount,
        lessThanOrEqualTo(s.total),
      );
      expect(s.completionRate, inInclusiveRange(0.0, 1.0));
      expect(s.byStatus, isNotEmpty);
      // Labels and colours must come from the server; the client has no table.
      expect(s.byStatus.first.label, isNotEmpty);
      expect(
        s.byStatus.map((b) => b.ratio).reduce((a, b) => a + b),
        closeTo(1.0, 0.02),
      );
    });

    test('every statistics axis the UI offers actually works', () async {
      for (final axis in StatAxis.values) {
        final g = await serviceRepo.grouped(axis);
        expect(g.groupBy, axis.value, reason: 'axis ${axis.value}');
        expect(g.total, greaterThan(0));
      }
    });

    test('trend returns points for each interval', () async {
      for (final interval in ['day', 'week', 'month']) {
        final t = await serviceRepo.trend(interval: interval);
        expect(t.interval, interval);
        expect(t.points, isNotEmpty, reason: 'interval $interval');
      }
    });

    test('date filters are encoded correctly (no 422)', () async {
      // The +00:00 offset must be percent-encoded; this is the regression
      // guard for that, since a raw + becomes a space and fails validation.
      final from = DateTime.now().subtract(const Duration(days: 30));
      final s = await serviceRepo.summary(dateFrom: from);
      expect(s.total, greaterThanOrEqualTo(0));
    });

    test('code master drives the form dropdowns', () async {
      for (final code in [
        'SERVICE_CATEGORY',
        'SERVICE_SYMPTOM',
        'SERVICE_CAUSE',
        'SERVICE_ACTION',
        'ASSET_CATEGORY',
        'EVENT_CATEGORY',
      ]) {
        final group = await adminRepo.codeGroup(code);
        expect(group.selectable, isNotEmpty, reason: code);
        expect(group.items.first.name, isNotEmpty);
      }
    });

    test('asset list and location tree parse', () async {
      final page = await inventoryRepo.list(size: 30);
      expect(page.total, greaterThan(0));
      expect(page.items.first.assetNo, isNotEmpty);

      final tree = await inventoryRepo.tree();
      expect(tree, isNotEmpty);
      final flat = StorageLocation.flatten(tree);
      expect(flat.length, greaterThan(tree.length),
          reason: 'the demo tree is nested');
    });

    test('inventory summary parses its buckets', () async {
      final s = await inventoryRepo.summary();
      expect(s.totalAssets, greaterThan(0));
      expect(s.byStatus, isNotEmpty);
      expect(s.byLocation, isNotEmpty);
    });

    test('boards arrive with their own settings', () async {
      final boards = await boardRepo.boards();
      expect(boards, isNotEmpty);
      final notice = boards.firstWhere((b) => b.code == 'NOTICE');
      // The write gate the UI uses must match the server's rule.
      expect(notice.writeRole, Role.admin);
      expect(notice.canWrite(Role.member), isFalse);
      expect(notice.canWrite(Role.admin), isTrue);

      final posts = await boardRepo.posts(notice.id);
      expect(posts.items, isNotEmpty);
    });

    test('calendar events overlapping a window come back', () async {
      final calendars = await calendarRepo.calendars();
      expect(calendars, isNotEmpty);

      final now = DateTime.now();
      final events = await calendarRepo.events(
        from: now.subtract(const Duration(days: 7)),
        to: now.add(const Duration(days: 21)),
      );
      expect(events, isNotEmpty, reason: 'demo data seeds a week of events');
      expect(events.first.endsAt.isBefore(events.first.startsAt), isFalse);
    });

    test('notification count endpoint parses', () async {
      final count = await calendarRepo.unreadCount();
      expect(count, greaterThanOrEqualTo(0));
    });

    test('admin health and stats parse', () async {
      final health = await adminRepo.health();
      expect(health.databaseOk, isTrue);
      expect(health.uptimeLabel, isNotEmpty);

      final stats = await adminRepo.stats();
      expect(stats.tables.length, 24, reason: 'the schema has 24 tables');
      expect(stats.usersActive, greaterThan(0));
    });

    test('settings screens load for every module', () async {
      for (final module in SettingsModule.values) {
        final s = await adminRepo.settings(module);
        expect(s.module, module.value);
        // Each row must declare a type the settings UI knows how to render.
        for (final row in s.settings) {
          expect(
            ['string', 'int', 'float', 'bool', 'list', 'json'],
            contains(row.valueType),
            reason: '${module.value}.${row.key}',
          );
        }
      }
    });

    test('member directory feeds the assignee picker', () async {
      final page = await authRepo.directory(size: 50);
      expect(page.items, isNotEmpty);
      expect(page.items.first.fullName, isNotEmpty);
    });

    test('pending approval queue is readable by an admin', () async {
      final page = await authRepo.pendingUsers();
      expect(page.total, greaterThanOrEqualTo(1),
          reason: 'demo data leaves one account waiting');
      expect(page.items.first.signupNote, isNotNull);
    });
  }, skip: skipReason);
}
