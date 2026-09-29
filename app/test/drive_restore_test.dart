import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/ui/admin/drive_restore_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Repo implements AdminRepository {
  int started = 0;
  bool supported = true;
  String stage = 'restored';
  @override
  Future<Map<String, dynamic>> driveBackupFiles() async => {
    'restore_supported': supported,
    'files': [
      {'name': 'drive_20260929_000000_000000.zip', 'size': 1024},
    ],
  };
  @override
  Future<String> startBackupRestore(String name, bool restore) async {
    started++;
    return 'ticket';
  }

  @override
  Future<Map<String, dynamic>> backupRestoreStatus(String ticket) async => {
    'stage': stage,
    'safety_backup': 'before_restore_example.zip',
    'error': '파일 검증 실패',
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> show(WidgetTester tester, _Repo repo) async {
    await tester.pumpWidget(
      Provider<AdminRepository>.value(
        value: repo,
        child: const MaterialApp(home: DriveRestorePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Restoration requires explicit confirmation and cancellation does nothing',
    (tester) async {
      final repo = _Repo();
      await show(tester, repo);
      await tester.tap(find.text('서버 복구'));
      await tester.pumpAndSettle();
      expect(find.textContaining('백업 이후 변경된 내용'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(repo.started, 0);
      await tester.tap(find.text('서버 복구'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('현재 서버 복구'));
      await tester.pumpAndSettle();
      expect(repo.started, 1);
      expect(find.text('복구 완료. 다시 로그인해 주세요.'), findsOneWidget);
      expect(find.textContaining('before_restore_example.zip'), findsOneWidget);
    },
  );
  testWidgets('Invalid archive failure is shown without a success message', (
    tester,
  ) async {
    final repo = _Repo()..stage = 'error';
    await show(tester, repo);
    await tester.tap(find.text('서버 복구'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('현재 서버 복구'));
    await tester.pumpAndSettle();
    expect(find.text('파일 검증 실패'), findsOneWidget);
    expect(find.text('복구 완료. 다시 로그인해 주세요.'), findsNothing);
  });
  testWidgets('Unsupported database cannot start automatic restore', (
    tester,
  ) async {
    final repo = _Repo()..supported = false;
    await show(tester, repo);
    await tester.tap(find.text('서버 복구'));
    await tester.pumpAndSettle();
    expect(repo.started, 0);
    expect(find.text('현재 서버 복구'), findsNothing);
  });
}
