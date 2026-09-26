import 'dart:async';
import 'package:flutter/services.dart';
import 'package:ddeck_app/ui/common/save_attachment_button.dart';
import 'package:ddeck_app/ui/service/service_ticket_row.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ddeck_app/ui/async_view.dart';
import 'package:ddeck_app/core/api_exception.dart';
import 'package:ddeck_app/state/theme_state.dart';

void main() {
  testWidgets('재조회 경쟁·일시 오류에도 최신 자료와 입력 유지, 권한 회수 시 제거', (tester) async {
    final requests = <Completer<String>>[];
    final key = GlobalKey<AsyncViewState<String>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncView<String>(
            key: key,
            load: () {
              final c = Completer<String>();
              requests.add(c);
              return c.future;
            },
            builder: (_, data, reload) =>
                ListView(children: [Text(data), const TextField()]),
          ),
        ),
      ),
    );
    requests[0].complete('첫 자료');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '보존할 초안');
    unawaited(key.currentState!.reload());
    await tester.pump();
    expect(find.text('첫 자료'), findsOneWidget);
    unawaited(key.currentState!.reload());
    requests[2].complete('최신 자료');
    await tester.pumpAndSettle();
    requests[1].complete('늦은 이전 응답');
    await tester.pumpAndSettle();
    expect(find.text('최신 자료'), findsOneWidget);
    expect(find.text('늦은 이전 응답'), findsNothing);
    expect(find.text('보존할 초안'), findsOneWidget);
    unawaited(key.currentState!.reload());
    requests[3].completeError(Exception('network'));
    await tester.pumpAndSettle();
    expect(find.text('최신 자료'), findsOneWidget);
    expect(find.text('보존할 초안'), findsOneWidget);
    expect(find.textContaining('이전 자료입니다'), findsOneWidget);
    unawaited(key.currentState!.reload());
    requests[4].completeError(
      ApiException(code: 'FORBIDDEN', message: '접근 권한이 없습니다', statusCode: 403),
    );
    await tester.pumpAndSettle();
    expect(find.text('최신 자료'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('접근 권한이 없습니다'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('목록 밀도와 테마를 재시작 후 복원', () async {
    SharedPreferences.setMockInitialValues({});
    final state = ThemeState();
    await state.setCompact(true);
    await state.select(ThemeMode.dark);
    final restored = ThemeState();
    await restored.load();
    expect(restored.compact, isTrue);
    expect(restored.mode, ThemeMode.dark);
    await restored.setCompact(false);
    await state.load();
    expect(state.compact, isFalse);
  });
  testWidgets('390px·200% 글자에서 대응 카드와 첨부 동작 접근', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var pressed = false;
    final ticket = ServiceTicket.fromJson({
      'id': 't',
      'ticket_no': 'AS-202609-0001',
      'title': '긴 발생 내용과 부가 설명을 포함한 대응 기록',
      'status': 'RECEIVED',
    });
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 1000),
              textScaler: TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('대응 접수'),
              actions: [SaveAttachmentButton(onPressed: () => pressed = true)],
            ),
            body: ListView(
              children: [ServiceTicketRow(ticket: ticket, onTap: () {})],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('저장 후 첨부파일 추가'), findsOneWidget);
      await tester.tap(find.byTooltip('저장 후 첨부파일 추가'));
      expect(pressed, isTrue);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('데스크톱 첨부 버튼에 텍스트 제공, 키보드로 실행', (tester) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SaveAttachmentButton(onPressed: () => pressed = true),
        ),
      ),
    );
    expect(find.text('저장 후 첨부'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(pressed, isTrue);
  });
}
