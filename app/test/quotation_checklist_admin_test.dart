import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/models/admin.dart';
import 'package:ddeck_app/ui/admin/quotation_checklist_page.dart';

class _Admin implements AdminRepository {
  List<ModuleSetting>? saved;
  final setting = ModuleSetting(
    key: 'quotation_checklist',
    valueType: 'json',
    label: '견적서 체크리스트',
    value: [
      {
        'id': 'rainbow',
        'label': '레인보우 입고',
        'notes': '전원 차단 후 보관',
        'items': [],
        'active': true,
      },
    ],
  );

  @override
  Future<ModuleSettings> settings(SettingsModule module) async =>
      ModuleSettings(module: 'SERVICE', settings: [setting], codeGroups: []);

  @override
  Future<ModuleSettings> saveSettings(
    SettingsModule module,
    List<ModuleSetting> settings,
  ) async {
    saved = settings;
    return ModuleSettings(
      module: 'SERVICE',
      settings: settings,
      codeGroups: [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('admin adds a checklist entry and saves only that setting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _Admin();
    await tester.pumpWidget(
      Provider<AdminRepository>.value(
        value: repo,
        child: const MaterialApp(home: QuotationChecklistPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('레인보우 입고'), findsOneWidget);

    await tester.tap(find.text('항목 추가'));
    await tester.pumpAndSettle();
    // Empty entry is refused.
    await tester.enterText(find.widgetWithText(TextFormField, '이름 *'), '두산 입고');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(find.text('채울 안내사항이나 품목을 하나 이상 입력하세요.'), findsOneWidget);

    await tester.tap(find.text('품목 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '품목 *'), '입고 점검');
    await tester.enterText(
      find.widgetWithText(TextFormField, '단가(원) *'),
      '50000',
    );
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(find.text('두산 입고'), findsOneWidget);

    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    final saved = repo.saved!.single;
    expect(saved.key, 'quotation_checklist');
    final value = saved.value as List;
    expect(value.map((e) => (e as Map)['label']), ['레인보우 입고', '두산 입고']);
    expect(((value.last as Map)['items'] as List).single, {
      'name': '입고 점검',
      'specification': '',
      'quantity': '1',
      'unit_price': '50000',
      'note': '',
    });
  });
}
