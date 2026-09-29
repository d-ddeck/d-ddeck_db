import 'package:ddeck_app/data/admin_repository.dart';
import 'package:ddeck_app/ui/admin/drive_backup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Admin implements AdminRepository {
  Map<String, dynamic> data = {
    'configured': true,
    'connected': true,
    'account': 'backup@example.com',
    'enabled': false,
    'hour': 3,
    'scheduler_enabled': true,
    'setup_available': true,
  };
  bool requested = false;
  String? savedFolder;
  @override
  Future<Map<String, dynamic>> startDriveSetup() async => {
    'id': 'test',
    'stage': 'ready',
    'option': {},
  };
  @override
  Future<List<String>> driveSetupFolders(String id, String parent) async => [
    '백업',
  ];
  @override
  Future<void> finishDriveSetup(String id, String folder, bool create) async {
    savedFolder = folder;
  }

  @override
  Future<void> cancelDriveSetup(String id) async {}

  @override
  Future<Map<String, dynamic>> driveBackup() async => Map.of(data);
  @override
  Future<void> scheduleDriveBackup(bool enabled, int hour) async {
    data.addAll({'enabled': enabled, 'hour': hour});
  }

  @override
  Future<void> runDriveBackup() async {
    requested = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('공유 드라이브 rclone 연결 경로 변경', (tester) async {
    final repo = _Admin();
    repo.data.addAll({
      'connection_type': 'rclone',
      'rclone_target': 'gdrive:old',
      'folder_name': 'Backup',
    });
    await tester.pumpWidget(
      Provider<AdminRepository>.value(
        value: repo,
        child: const MaterialApp(home: DriveBackupPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('OAuth 앱 설정'), findsNothing);
    await tester.tap(find.text('연동 계정 변경'));
    await tester.pumpAndSettle();
    expect(find.text('Google 계정 연결'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'D.DDECK 백업');
    await tester.tap(find.text('이 폴더에 백업'));
    await tester.pumpAndSettle();
    expect(repo.savedFolder, 'D.DDECK 백업');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('Drive 백업 연결 계정과 예약/즉시 백업 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _Admin();
      await tester.pumpWidget(
        Provider<AdminRepository>.value(
          value: repo,
          child: const MaterialApp(home: DriveBackupPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('연결 계정: backup@example.com'), findsOneWidget);
      expect(find.text('연동 계정 변경'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(repo.data['enabled'], isTrue);
      await tester.ensureVisible(find.text('지금 백업'));
      await tester.tap(find.text('지금 백업'));
      await tester.pumpAndSettle();
      expect(repo.requested, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
