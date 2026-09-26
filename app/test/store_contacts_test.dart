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

void main() {
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
