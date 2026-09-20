/// Drives the real built app through the entry flow.
///
/// The contract test proves the API layer; this proves the app on top of it:
/// the login screen renders, credentials reach the server, the shell appears,
/// the dashboard paints real numbers, logging out returns to login, and a
/// wrong password surfaces the server's message.
///
/// One test, one app lifecycle. Calling app.main() twice in a process leaves
/// two provider trees alive and the second run auto-restores the session the
/// first one saved, so the whole flow lives in a single testWidgets body.
///
/// Requires a running backend with demo data:
///   cd ../backend && python scripts/seed_demo.py
///   uvicorn app.main:app --host 127.0.0.1 --port 8000
///
/// Run:  flutter test integration_test/entry_flow_test.dart -d windows
library;

import 'package:ddeck_app/core/token_store.dart';
import 'package:ddeck_app/main.dart' as app;
import 'package:ddeck_app/ui/auth/login_page.dart';
import 'package:ddeck_app/ui/dashboard_page.dart';
import 'package:ddeck_app/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const demoEmail = 'seojun.kim@ddeck.local';
const demoPassword = 'demo1234';

/// Pumps until [finder] matches or the budget runs out.
///
/// pumpAndSettle is unusable here: a loading spinner animates forever while
/// the dashboard fetches, so the frame queue never settles.
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('timed out waiting for ${finder.describeMatch(Plurality.many)}'
      '${reason == null ? '' : ' ($reason)'}');
}

/// Focuses a field, types into it, and asserts the controller actually took
/// the value.
///
/// On a real device binding `enterText` silently does nothing when the field
/// is not focused, which produced a login retry that re-sent the previous
/// password. Verifying here turns that into an obvious failure.
Future<void> setField(
  WidgetTester tester,
  Finder field,
  String value,
) async {
  await tester.tap(field);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.enterText(field, value);
  await tester.pump(const Duration(milliseconds: 200));
  final controller = tester.widget<TextFormField>(field).controller;
  expect(controller?.text, value,
      reason: 'field did not accept the typed value');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('진입 흐름: 로그인 → 대시보드 → 로그아웃 → 자동로그인 선택 → 오류 메시지',
      (tester) async {
    // A previous run may have left a refresh token in the OS keystore, which
    // would auto-restore the session and skip the login screen entirely.
    await TokenStore().clearSession();

    app.main();
    await tester.pump(const Duration(seconds: 1));

    // ---------------------------------------------------------- 1. 로그인 화면
    await waitFor(tester, find.byType(LoginPage));
    expect(find.text('회원가입 신청'), findsOneWidget);
    expect(
      find.text('가입 후 관리자 승인이 완료되어야 로그인할 수 있습니다.'),
      findsOneWidget,
      reason: '진입 순서 안내가 노출되어야 한다',
    );

    final emailField = find.widgetWithText(TextFormField, '이메일');
    final passwordField = find.widgetWithText(TextFormField, '비밀번호');
    expect(emailField, findsOneWidget);
    expect(passwordField, findsOneWidget);

    // ------------------------------------------------------- 2. 정상 로그인
    await setField(tester, emailField, demoEmail);
    await setField(tester, passwordField, demoPassword);
    await tester.tap(find.widgetWithText(FilledButton, '로그인'));
    await tester.pump();

    await waitFor(tester, find.byType(HomeShell),
        reason: '로그인 성공 시 셸로 전환되어야 한다');
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(DashboardPage), findsOneWidget);

    // --------------------------------------------- 3. 대시보드가 실데이터를 그린다
    await waitFor(tester, find.textContaining('님, 안녕하세요'));
    await waitFor(tester, find.text('AS 접수 (당월)'));
    expect(find.text('완료율'), findsOneWidget);
    expect(find.text('보유 자산'), findsOneWidget);

    final assetTile = find.ancestor(
      of: find.text('보유 자산'),
      matching: find.byType(Card),
    );
    expect(assetTile, findsOneWidget);
    expect(
      find.descendant(of: assetTile, matching: find.textContaining('건')),
      findsWidgets,
      reason: '서버에서 받은 자산 건수가 렌더링되어야 한다',
    );

    // ------------------------------------------- 4. 권한에 맞는 탭 구성 (ADMIN)
    for (final label in ['홈', '서비스', '재고', '게시판', '캘린더', '관리']) {
      expect(find.text(label), findsWidgets, reason: '$label 탭이 없다');
    }

    // ------------------------------------------------- 5. 모듈 화면으로 이동
    await tester.tap(find.text('서비스').first);
    await tester.pump(const Duration(milliseconds: 400));
    await waitFor(tester, find.text('자동 통계'),
        reason: '서비스 모듈에 통계 탭이 있어야 한다');
    expect(find.text('접수 목록'), findsOneWidget);

    await tester.tap(find.text('홈').first);
    await tester.pump(const Duration(milliseconds: 400));

    // ------------------------------------------------------------ 6. 로그아웃
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('로그아웃').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilledButton, '로그아웃'));
    await tester.pump();

    await waitFor(tester, find.byType(LoginPage),
        reason: '로그아웃하면 로그인 화면으로 돌아가야 한다');
    expect(find.byType(HomeShell), findsNothing);

    // ------------------------------------------- 7. 자동 로그인 선택지 노출
    expect(
      find.widgetWithText(CheckboxListTile, '자동 로그인'),
      findsOneWidget,
      reason: '공용 PC 를 위해 끌 수 있어야 한다',
    );

    // ------------------------------------------------- 8. 잘못된 비밀번호 거절
    await setField(tester, find.widgetWithText(TextFormField, '이메일'),
        demoEmail);
    await setField(tester, find.widgetWithText(TextFormField, '비밀번호'),
        'definitely-wrong-1');
    await tester.tap(find.widgetWithText(FilledButton, '로그인'));
    await tester.pump();

    // The server's Korean message is shown verbatim - the client keeps no
    // message table of its own.
    await waitFor(tester, find.text('이메일 또는 비밀번호가 올바르지 않습니다.'));
    expect(find.byType(HomeShell), findsNothing);
  });
}
