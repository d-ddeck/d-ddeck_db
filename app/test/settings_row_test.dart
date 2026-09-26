import 'package:ddeck_app/models/admin.dart';
import 'package:ddeck_app/ui/admin/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 설정 화면의 부모처럼, 행이 바뀌었다고 알리면 setState 로 리빌드한다.
/// 이 리빌드가 컨트롤러를 새로 만들어 입력을 되돌리던 것이 1-21 결함이다.
Widget _host(ModuleSetting setting, {VoidCallback? onChanged}) => MaterialApp(
  home: Scaffold(
    body: StatefulBuilder(
      builder: (context, setState) => SettingRow(
        setting: setting,
        onChanged: () => setState(() => onChanged?.call()),
      ),
    ),
  ),
);

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  group('기능 설정 목록형(list) 편집기', () {
    testWidgets('쉼표로 끝나는 입력도 그대로 남고 값은 목록으로 파싱된다', (tester) async {
      final setting = ModuleSetting(
        key: 'equipment_types',
        valueType: 'list',
        value: ['기존값'],
      );
      var notified = 0;
      await tester.pumpWidget(_host(setting, onChanged: () => notified++));
      expect(_fieldText(tester), '기존값');

      await tester.enterText(find.byType(TextField), '로봇팔, 제어박스,');
      await tester.pump();

      // 사용자가 친 글자(끝의 쉼표 포함)는 그대로 있어야 다음 항목을 이어
      // 칠 수 있다.
      expect(_fieldText(tester), '로봇팔, 제어박스,');
      expect(find.text('로봇팔, 제어박스,'), findsOneWidget);
      // 모델에는 정규화된 목록이 들어간다.
      expect(setting.value, ['로봇팔', '제어박스']);
      expect(notified, 1);
    });

    testWidgets('입력 중(포커스) 부모가 리빌드돼도 입력이 되돌아가지 않는다', (tester) async {
      final setting = ModuleSetting(
        key: 'equipment_types',
        valueType: 'list',
        value: <String>[],
      );
      await tester.pumpWidget(_host(setting));

      await tester.enterText(find.byType(TextField), '로봇팔, ');
      await tester.pump();
      // 저장 버튼 상태 갱신 등 다른 이유로 부모가 통째로 다시 그려지는 상황.
      await tester.pumpWidget(_host(setting));

      expect(_fieldText(tester), '로봇팔, ');
      expect(setting.value, ['로봇팔']);
    });

    testWidgets('포커스가 없을 때 바깥에서 값이 바뀌면 표시가 따라간다', (tester) async {
      final setting = ModuleSetting(
        key: 'equipment_types',
        valueType: 'list',
        value: ['A'],
      );
      await tester.pumpWidget(_host(setting));
      expect(_fieldText(tester), 'A');

      // 저장 뒤 서버 재조회처럼 같은 자리의 설정 값이 바뀐 경우.
      setting.value = ['B', 'C'];
      await tester.pumpWidget(_host(setting));

      expect(_fieldText(tester), 'B, C');
    });

    testWidgets('숫자 항목도 친 그대로 남고 값만 변환된다', (tester) async {
      final setting = ModuleSetting(
        key: 'due_days',
        valueType: 'int',
        value: 3,
      );
      await tester.pumpWidget(_host(setting));
      expect(_fieldText(tester), '3');

      await tester.enterText(find.byType(TextField), '14');
      await tester.pump();

      expect(_fieldText(tester), '14');
      expect(setting.value, 14);
    });
  });
}
