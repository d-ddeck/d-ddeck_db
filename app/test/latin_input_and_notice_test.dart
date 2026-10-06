import 'package:ddeck_app/core/latin_input.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/auth/signup_page.dart';
import 'package:ddeck_app/ui/common/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Auth extends ChangeNotifier implements AuthState {
  (String, String)? changed;
  @override
  Future<void> changePassword(String current, String next) async {
    changed = (current, next);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('hangulToQwerty', () {
    test('maps syllables and jamo to the same 2-beolsik keys', () {
      expect(hangulToQwerty('ㅁ'), 'a');
      expect(hangulToQwerty('안녕'), 'dkssud');
      expect(hangulToQwerty('뷁'), 'qnpfr');
      expect(hangulToQwerty('ㅃㅒ'), 'QO');
      expect(hangulToQwerty('관리자1@'), 'rhksflwk1@');
    });

    test('leaves latin input untouched', () {
      expect(hangulToQwerty('admin@ddeck.local'), 'admin@ddeck.local');
      expect(hangulToQwerty('P@ss w0rd!'), 'P@ss w0rd!');
    });
  });

  group('LatinInputFormatter', () {
    const formatter = LatinInputFormatter();

    test('converts committed hangul and keeps the cursor after it', () {
      final value = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: 'ad안',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      expect(value.text, 'addks');
      expect(value.selection, const TextSelection.collapsed(offset: 5));
    });

    test('does not touch text the IME is still composing', () {
      const composing = TextEditingValue(
        text: 'ad아',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 2, end: 3),
      );
      expect(
        formatter.formatEditUpdate(TextEditingValue.empty, composing),
        composing,
      );
    });
  });

  testWidgets('saved notice with a detail action hides after three seconds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppSnack.saved(
                context,
                label: '일정 점검',
                detail: () => const Text('상세'),
              ),
              child: const Text('save'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(find.text('일정 점검 저장되었습니다.'), findsOneWidget);
    expect(find.text('상세 보기'), findsOneWidget);
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.behavior, SnackBarBehavior.fixed);

    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.text('일정 점검 저장되었습니다.'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('일정 점검 저장되었습니다.'), findsNothing);
  });

  testWidgets('password change sends latin text like the login screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = _Auth();
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>.value(
        value: auth,
        child: const MaterialApp(home: ChangePasswordPage()),
      ),
    );
    Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );
    // Typed with the IME left in Korean mode: '관리자1234' is 'rhksflwk1234'.
    await tester.enterText(field('현재 비밀번호'), '관리자1234');
    await tester.enterText(field('새 비밀번호'), 'ㅜㄷㅈ1234ㅁ');
    await tester.enterText(field('새 비밀번호 확인'), 'new1234a');
    final current = tester.widget<TextField>(field('현재 비밀번호'));
    expect(current.controller!.text, 'rhksflwk1234');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(auth.changed, ('rhksflwk1234', 'new1234a'));
  });
}
