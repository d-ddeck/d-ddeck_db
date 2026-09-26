import 'package:alarm/alarm.dart';
import 'package:ddeck_app/services/alarm_service.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/core/api_exception.dart';
import 'package:ddeck_app/core/token_store.dart';
import 'package:ddeck_app/ui/common/dirty_form_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    if (options.path.endsWith('/auth/refresh')) {
      return ResponseBody.fromString(
        jsonEncode({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    requests++;
    if (requests == 1) {
      return ResponseBody.fromString(
        '{"error":{"code":"TOKEN_EXPIRED","message":"만료"}}',
        401,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    expect(options.headers['Authorization'], 'Bearer new-access');
    return ResponseBody.fromString(
      '{"error":{"code":"MAINTENANCE_MODE","message":"점검 중"}}',
      503,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final remember in [true, false]) {
    test(
      'refresh rotation persists according to remember=$remember and preserves retry error',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final store = TokenStore();
        await store.saveSession(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          remember: remember,
        );
        final api = ApiClient(tokenStore: store, adapter: _Adapter());
        await expectLater(
          api.get('/thing'),
          throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 503),
          ),
        );
        expect(await store.readRefreshToken(), 'new-refresh');
        expect(
          await TokenStore().readRefreshToken(),
          remember ? 'new-refresh' : null,
        );
        expect(api.connected.value, false);
      },
    );
  }
  test('alarm polling compares instants and preserves unchanged schedules', () {
    AlarmSettings alarm(String instant, {String title = '일정'}) => AlarmSettings(
      id: 11,
      dateTime: DateTime.parse(instant),
      volumeSettings: const VolumeSettings.fixed(),
      notificationSettings: const NotificationSettings(title: '알림', body: '본문'),
      payload: jsonEncode({
        'title': title,
        'scheduledAt': instant,
        'startsAt': instant,
      }),
    );
    final utc = alarm('2026-09-26T01:00:00Z');
    expect(
      AlarmService.sameAlarmSchedule(utc, alarm('2026-09-26T10:00:00+09:00')),
      true,
    );
    expect(
      AlarmService.sameAlarmSchedule(utc, alarm('2026-09-26T01:01:00Z')),
      false,
    );
    expect(
      AlarmService.sameAlarmSchedule(
        utc,
        alarm('2026-09-26T01:00:00Z', title: '변경'),
      ),
      false,
    );
  });
  testWidgets(
    'unsaved controller edits can be kept or discarded through back',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final text = TextEditingController();
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('home')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => DirtyFormScope(
            snapshot: () => text.text,
            child: Scaffold(
              appBar: AppBar(title: const Text('edit')),
              body: TextField(controller: text),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'changed');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('저장하지 않고 나가기'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(text.text, 'changed');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('나가기'));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    },
  );
}
