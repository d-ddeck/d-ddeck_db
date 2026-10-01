import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/data/store_repository.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/store/store_page.dart';
import 'service_work_types_test.dart' show FakeApi, FakeAuth;

class StoreAuth extends FakeAuth {
  @override
  UserProfile? get user => null;
}

class StoreApi extends FakeApi {
  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) async {
    if (path == '/stores/brands') {
      return [
        {
          'brand_id': 'a',
          'brand_name': '브랜드 A',
          'store_count': 5,
          'open_store_count': 3,
        },
        {
          'brand_id': null,
          'brand_name': '기타',
          'store_count': 2,
          'open_store_count': 1,
        },
      ];
    }
    if (path == '/stores') {
      lastQuery = query;
      return {
        'items': [
          {'id': 'open', 'name': '운영 매장', 'is_closed': false},
          {'id': 'closed', 'name': '미운영 매장', 'is_closed': true},
        ],
        'total': 2,
        'page': 1,
        'size': 200,
      };
    }
    return super.get(path, query: query, skipAuth: skipAuth);
  }
}

void main() {
  for (final closed in [false, true]) {
    testWidgets('closed stores have a separate count and list: $closed', (
      tester,
    ) async {
      final api = StoreApi();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider(create: (_) => StoreRepository(api)),
            ChangeNotifierProvider<AuthState>(create: (_) => StoreAuth()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StoreTab(initialBrandId: closed ? '__closed__' : null),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('미운영 포함'), findsNothing);
      if (closed) {
        expect(find.textContaining('미운영 매장 ·'), findsOneWidget);
        expect(find.textContaining(RegExp(r'^운영 매장 ·')), findsNothing);
        expect(api.lastQuery?['include_closed'], true);
        expect(api.lastQuery?['include_inactive'], true);
        expect(api.lastQuery?['brand_id'], isNull);
      } else {
        expect(find.text('미운영 3'), findsOneWidget);
        expect(find.text('운영 3'), findsOneWidget);
        expect(find.text('운영 1'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
