import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/auth/profile_page.dart';
import 'package:ddeck_app/ui/theme.dart';
import 'package:ddeck_app/data/auth_repository.dart';
import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/data/board_repository.dart';
import 'package:ddeck_app/models/board.dart';
import 'package:ddeck_app/models/common.dart';
import 'package:ddeck_app/models/inventory.dart';
import 'package:ddeck_app/ui/admin/departments_page.dart';
import 'package:ddeck_app/ui/board/board_settings_page.dart';
import 'package:ddeck_app/ui/inventory/asset_edit_page.dart';

class _Auth extends ChangeNotifier implements AuthState {
  @override
  UserProfile? get user => UserProfile.fromJson({
    'id': 'preview',
    'email': 'preview@example.test',
    'full_name': '홍길동',
    'phone': '010-0000-0000',
    'position': '주임',
    'role': 'ADMIN',
    'status': 'APPROVED',
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AuthRepo implements AuthRepository {
  @override
  Future<List<Department>> departments() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Boards implements BoardRepository {
  @override
  Future<List<Board>> boards({bool includeInactive = false}) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Admin implements AdminRepository {
  @override
  Future<CodeGroup> codeGroup(
    String groupCode, {
    bool includeHistorical = false,
  }) async =>
      CodeGroup.fromJson({'code': groupCode, 'name': '장비 종류', 'items': []});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = String.fromEnvironment('SPACING_CAPTURE_DIR');
  const font = String.fromEnvironment('SPACING_CAPTURE_FONT');
  setUpAll(() async {
    if (font.isNotEmpty) {
      final loader = FontLoader('SpacingPreview')
        ..addFont(
          File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });
  for (final width in [390.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final dark in [false, true]) {
        for (final compact in [false, true]) {
          testWidgets('내 정보 폼 간격 $width/$scale/$dark/$compact', (tester) async {
            tester.view.physicalSize = Size(width, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final key = GlobalKey();
            final theme = dark
                ? AppTheme.dark(compact: compact)
                : AppTheme.light(compact: compact);
            await tester.pumpWidget(
              ChangeNotifierProvider<AuthState>(
                create: (_) => _Auth(),
                child: RepaintBoundary(
                  key: key,
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: font.isEmpty
                        ? theme
                        : theme.copyWith(
                            textTheme: theme.textTheme.apply(
                              fontFamily: 'SpacingPreview',
                            ),
                          ),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: const ProfilePage(),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (capture.isNotEmpty && !compact) {
              await tester.runAsync(() async {
                final boundary =
                    key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await boundary.toImage();
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final dir = Directory(capture)..createSync(recursive: true);
                await File(
                  '${dir.path}/profile-$width-$scale-$dark.png',
                ).writeAsBytes(data!.buffer.asUint8List());
                image.dispose();
              });
            }
            final fields = find.byType(TextField);
            for (var i = 1; i < 3; i++) {
              expect(
                tester.getRect(fields.at(i)).top -
                    tester.getRect(fields.at(i - 1)).bottom,
                greaterThanOrEqualTo(16 - 0.001),
              );
            }
            expect(
              tester.getRect(find.byType(FilledButton)).top -
                  tester.getRect(fields.last).bottom,
              greaterThanOrEqualTo(16 - 0.001),
            );
            final viewport = tester.getRect(find.byType(Viewport).first);
            expect(
              tester.getRect(find.text('이름')).top,
              greaterThanOrEqualTo(viewport.top),
            );
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
  for (final page in ['부서', '게시판', '장비']) {
    for (final width in [390.0, 1440.0]) {
      for (final dark in [false, true]) {
        testWidgets('$page 입력폼 간격과 스크롤 $width/$dark', (tester) async {
          tester.view.physicalSize = Size(width, 820);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                Provider<AuthRepository>(create: (_) => _AuthRepo()),
                Provider<BoardRepository>(create: (_) => _Boards()),
                Provider<AdminRepository>(create: (_) => _Admin()),
              ],
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: dark ? AppTheme.dark() : AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width < 900 ? 2 : 1),
                  ),
                  child: child!,
                ),
                home: page == '부서'
                    ? const DepartmentsPage()
                    : page == '게시판'
                    ? const BoardSettingsPage()
                    : AssetEditPage(
                        asset: Asset.fromJson({
                          'id': 'preview',
                          'name': '테스트 장비',
                        }),
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (page == '부서') await tester.tap(find.text('부서 추가'));
          if (page == '게시판') await tester.tap(find.byIcon(Icons.add));
          await tester.pumpAndSettle();
          final fields = find.byType(InputDecorator);
          expect(fields.evaluate().length, greaterThanOrEqualTo(2));
          for (var i = 1; i < fields.evaluate().length; i++) {
            expect(
              tester.getRect(fields.at(i)).top -
                  tester.getRect(fields.at(i - 1)).bottom,
              greaterThanOrEqualTo(16 - 0.001),
            );
          }
          if (page == '장비') {
            await tester.scrollUntilVisible(
              find.byType(FilledButton),
              250,
              scrollable: find.byType(Scrollable).first,
            );
            expect(find.text('저장').hitTestable(), findsOneWidget);
          } else {
            if (page == '부서') {
              await tester.tap(find.text('저장'));
              await tester.pumpAndSettle();
              expect(find.text('부서명을 입력하세요.'), findsOneWidget);
              expect(
                tester.getRect(fields.at(1)).top -
                    tester.getRect(fields.at(0)).bottom,
                greaterThanOrEqualTo(16 - 0.001),
              );
            }
            await tester.tap(find.text('취소').last);
            await tester.pumpAndSettle();
            await tester.pump(const Duration(seconds: 1));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
