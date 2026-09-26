import 'package:ddeck_app/state/theme_state.dart';
import 'package:ddeck_app/ui/common/theme_mode_button.dart';
import 'package:ddeck_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('선택한 모드 재실행 복원과 잘못된 저장값 복구', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ThemeState();
    await first.load();
    expect(first.mode, ThemeMode.system);
    await first.select(ThemeMode.dark);
    final restored = ThemeState();
    await restored.load();
    expect(restored.mode, ThemeMode.dark);
    await restored.select(ThemeMode.light);
    final light = ThemeState();
    await light.load();
    expect(light.mode, ThemeMode.light);
    SharedPreferences.setMockInitialValues({
      ThemeState.preferenceKey: 'invalid',
    });
    await light.load();
    expect(light.mode, ThemeMode.system);
    first.dispose();
    restored.dispose();
    light.dispose();
  });

  testWidgets('모드 메뉴 즉시 적용과 시스템 밝기 추종', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = ThemeState();
    await state.load();
    addTearDown(state.dispose);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: Consumer<ThemeState>(
          builder: (_, state, _) => MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: state.mode,
            home: Scaffold(
              appBar: AppBar(actions: const [ThemeModeButton()]),
              body: Builder(
                builder: (context) => Text(Theme.of(context).brightness.name),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('화면 모드: 시스템 설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다크 모드'));
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
    await tester.tap(find.byTooltip('화면 모드: 다크 모드'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('라이트 모드'));
    await tester.pumpAndSettle();
    expect(find.text('light'), findsOneWidget);
    await state.select(ThemeMode.system);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
  });
}
