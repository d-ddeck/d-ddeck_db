import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/ui/admin/admin_page.dart';
import 'package:ddeck_app/ui/theme.dart';
import 'package:alarm/alarm.dart';
import 'package:ddeck_app/services/alarm_service.dart';
import 'package:ddeck_app/ui/calendar/calendar_range_selection.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/core/api_exception.dart';
import 'package:ddeck_app/core/token_store.dart';
import 'package:ddeck_app/data/auth_repository.dart';
import 'package:ddeck_app/data/calendar_repository.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/services/synced_alarm_store.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/auth/profile_page.dart';
import 'package:ddeck_app/ui/admin/accounts_tab.dart';
import 'package:ddeck_app/ui/notifications_page.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _Auth extends ChangeNotifier implements AuthState {
  @override
  UserProfile? get user => UserProfile.fromJson({
    'id': 'me',
    'email': 'me@test.local',
    'full_name': '내 이름',
    'role': 'ADMIN',
    'status': 'APPROVED',
  });
  @override
  Role get role => Role.admin;
  @override
  bool get isAdmin => true;
  @override
  Future<void> refreshUnread() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  testWidgets('calendar drag includes the initial and final selected days', (
    tester,
  ) async {
    DateTime? start, end;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 708,
              height: 222,
              child: CalendarRangeSelection(
                firstDay: DateTime(2026, 9, 7),
                rowHeight: 100,
                weeks: 2,
                enabled: true,
                onSelected: (a, b) {
                  start = a;
                  end = b;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(CalendarRangeSelection));
    final gesture = await tester.startGesture(origin + const Offset(54, 72));
    await gesture.moveTo(origin + const Offset(354, 172));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(start, DateTime(2026, 9, 7));
    expect(end, DateTime(2026, 9, 17));
  });
  test('concurrent expired requests rotate refresh once', () async {
    final store = TokenStore();
    await store.saveSession(
      accessToken: 'old',
      refreshToken: 'refresh',
      remember: true,
    );
    var refreshes = 0;
    final api = ApiClient(
      tokenStore: store,
      adapter: _Adapter((options) async {
        if (options.path.endsWith('/auth/refresh')) {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _json({'access_token': 'new', 'refresh_token': 'rotated'});
        }
        return options.headers['Authorization'] == 'Bearer new'
            ? _json({'ok': true})
            : _json({
                'error': {'code': 'TOKEN_EXPIRED', 'message': 'expired'},
              }, 401);
      }),
    );
    final replies = await Future.wait(
      List.generate(6, (_) => api.get('/resource')),
    );
    expect(refreshes, 1);
    expect(replies.every((value) => value['ok'] == true), true);
    expect(await store.readRefreshToken(), 'rotated');
  });
  for (final code in ['FORBIDDEN', 'ACCOUNT_NOT_ACTIVE']) {
    test('403 $code only revokes suspended accounts', () async {
      final store = TokenStore();
      await store.saveSession(
        accessToken: 'old',
        refreshToken: 'refresh',
        remember: true,
      );
      var expired = 0;
      final api = ApiClient(
        tokenStore: store,
        adapter: _Adapter(
          (_) => _json({
            'error': {'code': code, 'message': 'denied'},
          }, 403),
        ),
      );
      api.onSessionExpired = () => expired++;
      await expectLater(api.get('/resource'), throwsA(isA<ApiException>()));
      expect(expired, code == 'ACCOUNT_NOT_ACTIVE' ? 1 : 0);
    });
  }
  for (final status in [401, 503]) {
    test(
      'refresh failure $status only clears definitively invalid sessions',
      () async {
        final store = TokenStore();
        await store.saveSession(
          accessToken: 'old',
          refreshToken: 'refresh',
          remember: true,
        );
        var expired = 0;
        final api = ApiClient(
          tokenStore: store,
          adapter: _Adapter(
            (options) => options.path.endsWith('/auth/refresh')
                ? _json({
                    'error': {'code': 'FAILED', 'message': 'retry later'},
                  }, status)
                : _json({
                    'error': {'code': 'TOKEN_EXPIRED', 'message': 'expired'},
                  }, 401),
          ),
        );
        api.onSessionExpired = () => expired++;
        await expectLater(api.get('/resource'), throwsA(isA<ApiException>()));
        expect(expired, status == 401 ? 1 : 0);
        if (status == 503) expect(await store.readRefreshToken(), 'refresh');
      },
    );
  }
  test(
    'alarm sync retains ringing and snoozed alarms but removes obsolete schedules',
    () {
      final now = DateTime.utc(2026, 9, 26, 1);
      AlarmSettings alarm(DateTime at, String scheduled) => AlarmSettings(
        id: 123,
        dateTime: at,
        assetAudioPath: 'assets/alarm.wav',
        volumeSettings: VolumeSettings.fixed(),
        notificationSettings: const NotificationSettings(
          title: '일정',
          body: '내용',
        ),
        payload: jsonEncode({'scheduledAt': scheduled}),
      );
      final past = alarm(
        now.subtract(const Duration(minutes: 1)),
        now.subtract(const Duration(minutes: 1)).toIso8601String(),
      );
      final snoozed = alarm(
        now.add(const Duration(minutes: 5)),
        now.toIso8601String(),
      );
      expect(
        AlarmService.shouldRetainAlarm(past, null, ringing: true, now: now),
        true,
      );
      expect(
        AlarmService.shouldRetainAlarm(past, null, ringing: false, now: now),
        false,
      );
      expect(
        AlarmService.shouldRetainAlarm(snoozed, null, ringing: false, now: now),
        true,
      );
    },
  );
  test('synced alarms preserve owner and clear completely', () async {
    final store = SyncedAlarmStore();
    await store.save([], ownerUserId: 'owner');
    expect((await store.load()).ownerUserId, 'owner');
    expect((await store.load()).syncedAt, isNotNull);
    await store.clear();
    expect((await store.load()).ownerUserId, isNull);
  });
  testWidgets('empty profile name is rejected before API call', (tester) async {
    final auth = _Auth();
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>.value(
        value: auth,
        child: const MaterialApp(home: ProfilePage()),
      ),
    );
    await tester.enterText(find.byType(TextField).first, '  ');
    await tester.tap(find.text('저장'));
    await tester.pump();
    expect(find.text('이름을 입력하세요.'), findsOneWidget);
  });
  testWidgets('notification unread filter reaches repository', (tester) async {
    final queries = <Map<String, dynamic>>[];
    final api = ApiClient(
      tokenStore: TokenStore(),
      adapter: _Adapter((options) {
        queries.add(Map.of(options.queryParameters));
        return _json({
          'items': [],
          'total': 0,
          'page': 1,
          'size': 50,
          'pages': 0,
        });
      }),
    );
    await tester.pumpWidget(
      Provider<CalendarRepository>.value(
        value: CalendarRepository(api),
        child: const MaterialApp(home: NotificationsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('아직 등록된 알림이 없습니다'), findsOneWidget);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('읽지 않음만'));
    await tester.pumpAndSettle();
    expect(queries.last['unread_only'], true);
  });
  testWidgets('accounts screen reports API errors without leaking internals', (
    tester,
  ) async {
    final auth = _Auth();
    addTearDown(auth.dispose);
    final api = ApiClient(
      tokenStore: TokenStore(),
      adapter: _Adapter(
        (_) => _json({
          'error': {'code': 'FORBIDDEN', 'message': '권한이 없습니다.'},
        }, 403),
      ),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthState>.value(value: auth),
          Provider<AuthRepository>.value(value: AuthRepository(api)),
        ],
        child: const MaterialApp(home: Scaffold(body: AccountsTab())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('권한이 없습니다.'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  for (final width in [1440.0, 390.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final dark in [false, true]) {
        testWidgets('관리 검색 제목이 탭/스크롤 경계에서 잘리지 않음 $width/$scale/$dark', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final auth = _Auth();
          addTearDown(auth.dispose);
          final api = ApiClient(
            tokenStore: TokenStore(),
            adapter: _Adapter(
              (_) => _json({'items': [], 'total': 0, 'page': 1, 'size': 50}),
            ),
          );
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<AuthState>.value(value: auth),
                Provider<AuthRepository>.value(value: AuthRepository(api)),
                Provider<AdminRepository>.value(value: AdminRepository(api)),
              ],
              child: MaterialApp(
                theme: dark ? AppTheme.dark() : AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const Scaffold(body: AdminPage()),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final entry in {
            '계정 관리': '이름·이메일 검색',
            '감사 로그': '감사 로그 검색',
          }.entries) {
            final tab = find.widgetWithText(Tab, entry.key);
            await tester.ensureVisible(tab);
            await tester.tap(tab);
            await tester.pumpAndSettle();
            if (entry.key == '계정 관리' && width < 900) {
              await tester.tap(find.text('검색 조건 0개 적용'));
              await tester.pumpAndSettle();
            }
            final field = find.widgetWithText(TextField, entry.value);
            await tester.ensureVisible(field);
            await tester.tap(field);
            await tester.enterText(field, '검색');
            await tester.pumpAndSettle();
            final label = find.text(entry.value);
            final labelTop = tester.getTopLeft(label).dy;
            expect(
              labelTop,
              greaterThanOrEqualTo(
                tester.getTopLeft(find.byType(TabBarView)).dy,
              ),
              reason: '검색 제목이 탭 위로 잘림',
            );
            for (final viewport
                in find
                    .ancestor(
                      of: label,
                      matching: find.byType(SingleChildScrollView),
                    )
                    .evaluate()) {
              expect(
                labelTop,
                greaterThanOrEqualTo(
                  tester.getTopLeft(find.byWidget(viewport.widget)).dy,
                ),
                reason: '검색 제목이 스크롤 위로 잘림',
              );
            }
            expect(tester.takeException(), isNull);
          }
        });
      }
    }
  }
}
