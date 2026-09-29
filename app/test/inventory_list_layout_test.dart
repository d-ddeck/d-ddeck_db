import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/data/inventory_repository.dart';
import 'package:ddeck_app/data/store_repository.dart';
import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/inventory.dart';
import 'package:ddeck_app/models/store.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/inventory/inventory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Auth extends ChangeNotifier implements AuthState {
  @override
  UserProfile? get user => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Admin implements AdminRepository {
  @override
  Future<CodeGroup> codeGroup(String code) async => CodeGroup(
    id: code,
    code: code,
    name: code,
    module: 'inventory',
    items: code == 'ASSET_CATEGORY'
        ? const [
            CodeItem(id: 'arm', code: 'ROBOT_ARM', name: '로봇팔'),
            CodeItem(id: 'box', code: 'CONTROL_BOX', name: '제어박스'),
          ]
        : [],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stores implements StoreRepository {
  @override
  Future<List<Store>> all({
    bool includeClosed = false,
    String? brandId,
  }) async => [];
  @override
  Future<List<BrandSummary>> brands() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Inventory implements InventoryRepository {
  String? category;
  @override
  Future<List<StorageLocation>> locations() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #list) {
      category = invocation.namedArguments[#categoryId] as String?;
      return Future<PagedList<Asset>>.value(
        PagedList.fromJson({
          'items': [
            for (final id in ['arm', 'box'])
              if (category == null || category == id)
                {
                  'id': id,
                  'name': '제품-$id',
                  'asset_no': id,
                  'serial_no': 'SN-$id',
                  'category_id': id,
                  'store': {'id': 'store', 'name': '테스트매장'},
                  'store_id': 'store',
                },
          ],
          'total': category == null ? 2 : 1,
          'page': 1,
          'size': 50,
          'pages': 1,
        }, Asset.fromJson),
      );
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('equipment columns and category selection $platform', (
      tester,
    ) async {
      tester.view.physicalSize = Size(
        platform == TargetPlatform.windows ? 1400 : 430,
        1000,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = _Auth();
      final inventory = _Inventory();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthState>.value(value: auth),
            Provider<AdminRepository>.value(value: _Admin()),
            Provider<StoreRepository>.value(value: _Stores()),
            Provider<InventoryRepository>.value(value: inventory),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: InventoryListTab(revision: 0, onChanged: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SN-arm'), findsOneWidget);
      expect(find.text('제품-arm'), findsOneWidget);
      expect(
        find.text('현재 위치'),
        platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('테스트매장'),
        platform == TargetPlatform.windows ? findsNWidgets(2) : findsNothing,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '로봇팔'));
      await tester.pumpAndSettle();
      expect(inventory.category, 'arm');
      expect(find.text('SN-box'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '제어박스'));
      await tester.pumpAndSettle();
      expect(inventory.category, 'box');
      expect(find.text('SN-arm'), findsNothing);
      expect(find.text('SN-box'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
