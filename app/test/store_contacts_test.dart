import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/data/auth_repository.dart';
import 'package:ddeck_app/data/service_repository.dart';
import 'package:ddeck_app/data/store_repository.dart';
import 'package:ddeck_app/models/service.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/service/service_form_page.dart';
import 'service_work_types_test.dart' show FakeApi, FakeAuth, ticketJson;

class ContactApi extends FakeApi {
  static const stores = [
    {
      'id': 'a',
      'name': 'A 매장',
      'contact_name': '홍담당',
      'contact_phone': '010-0000-0001',
      'address': '서울 주소',
    },
    {
      'id': 'b',
      'name': 'B 매장',
      'contact_name': '김담당',
      'contact_phone': '010-0000-0002',
      'address': '부산 주소',
    },
  ];
  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    if (path == '/stores') return stores;
    if (path == '/stores/a') return stores[0];
    if (path == '/stores/b') return stores[1];
    return super.get(path, query: query, skipAuth: skipAuth);
  }
}

/// 브랜드 두 개에 매장이 섞여 있는 목록. brand_id 로 걸러 달라고 하면 걸러 준다.
class BrandApi extends FakeApi {
  static const stores = [
    {'id': 's1', 'name': '레인보우 강남', 'brand_id': 'rb'},
    {'id': 's2', 'name': '두산 판교', 'brand_id': 'ds'},
    {'id': 's3', 'name': '레인보우 수원', 'brand_id': 'rb'},
    {'id': 's4', 'name': '브랜드 없는 매장'},
  ];
  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    if (path == '/stores/brands') {
      return [
        {'brand_id': 'rb', 'brand_name': '레인보우'},
        {'brand_id': 'ds', 'brand_name': '두산'},
      ];
    }
    if (path == '/stores') {
      final brand = query?['brand_id'];
      return [
        for (final s in stores)
          if (brand == null || s['brand_id'] == brand) s,
      ];
    }
    return super.get(path, query: query, skipAuth: skipAuth);
  }
}

void main() {
  testWidgets('choosing a store first selects its brand', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = BrandApi();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider(create: (_) => AdminRepository(api)),
          Provider(create: (_) => AuthRepository(api)),
          Provider(create: (_) => ServiceRepository(api)),
          Provider(create: (_) => StoreRepository(api)),
          ChangeNotifierProvider<AuthState>(create: (_) => FakeAuth()),
        ],
        child: const MaterialApp(home: ServiceFormPage()),
      ),
    );
    await tester.pumpAndSettle();
    Finder field(String label) => find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          w.decoration.labelText == label,
    );
    String? value(String label) =>
        tester.state<FormFieldState<String>>(field(label)).value;

    expect(value('브랜드'), isNull);
    await tester.tap(field('매장 *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('레인보우 수원').last);
    await tester.pumpAndSettle();
    expect(value('브랜드'), 'rb');
    expect(value('매장 *'), 's3');

    // The store list now only offers that brand's stores.
    await tester.tap(field('매장 *'));
    await tester.pumpAndSettle();
    expect(find.text('레인보우 강남'), findsWidgets);
    expect(find.text('두산 판교'), findsNothing);
    await tester.tap(find.text('레인보우 강남').last);
    await tester.pumpAndSettle();
    expect(value('브랜드'), 'rb');
    expect(value('매장 *'), 's1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a store without a brand leaves the brand unset', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = BrandApi();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider(create: (_) => AdminRepository(api)),
          Provider(create: (_) => AuthRepository(api)),
          Provider(create: (_) => ServiceRepository(api)),
          Provider(create: (_) => StoreRepository(api)),
          ChangeNotifierProvider<AuthState>(create: (_) => FakeAuth()),
        ],
        child: const MaterialApp(home: ServiceFormPage()),
      ),
    );
    await tester.pumpAndSettle();
    final store = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          w.decoration.labelText == '매장 *',
    );
    await tester.tap(store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('브랜드 없는 매장').last);
    await tester.pumpAndSettle();
    final brand = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          w.decoration.labelText == '브랜드',
    );
    expect(tester.state<FormFieldState<String>>(brand).value, isNull);
    expect(tester.state<FormFieldState<String>>(store).value, 's4');
  });

  for (final editing in [false, true]) {
    testWidgets(
      'store contact autofill preserves existing snapshot: $editing',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = ContactApi();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider(create: (_) => AdminRepository(api)),
              Provider(create: (_) => AuthRepository(api)),
              Provider(create: (_) => ServiceRepository(api)),
              Provider(create: (_) => StoreRepository(api)),
              ChangeNotifierProvider<AuthState>(create: (_) => FakeAuth()),
            ],
            child: MaterialApp(
              home: ServiceFormPage(
                initialStoreId: 'a',
                ticket: editing
                    ? ServiceTicket.fromJson({
                        ...ticketJson,
                        'store_id': 'a',
                        'contact_name': '이전 담당',
                        'contact_phone': '이전 전화',
                        'site_address': '이전 주소',
                      })
                    : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        String value(String label) => tester
            .widget<TextField>(
              find.byWidgetPredicate(
                (w) => w is TextField && w.decoration?.labelText == label,
              ),
            )
            .controller!
            .text;
        expect(value('매장 담당자'), editing ? '이전 담당' : '홍담당');
        expect(value('연락처'), editing ? '이전 전화' : '010-0000-0001');
        expect(value('현장 주소'), editing ? '이전 주소' : '서울 주소');
        final storeField = find.byWidgetPredicate(
          (w) =>
              w is DropdownButtonFormField<String> &&
              w.decoration.labelText == '매장 *',
        );
        await tester.tap(storeField);
        await tester.pumpAndSettle();
        await tester.tap(find.text('B 매장').last);
        await tester.pumpAndSettle();
        expect(value('매장 담당자'), '김담당');
        expect(value('현장 주소'), '부산 주소');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
