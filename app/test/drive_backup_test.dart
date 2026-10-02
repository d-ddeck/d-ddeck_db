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

  final powerCalls = <Map<String, dynamic>>[];
  bool powerCanceled = false;
  @override
  Future<void> setDrivePower({
    required bool enabled,
    required int graceMinutes,
    required int wakeHour,
    required int wakeMinute,
  }) async {
    final values = {
      'enabled': enabled,
      'grace_minutes': graceMinutes,
      'wake_hour': wakeHour,
      'wake_minute': wakeMinute,
    };
    powerCalls.add(values);
    data['power'] = {...data['power'] as Map<String, dynamic>, ...values};
  }

  @override
  Future<void> cancelDrivePower() async {
    powerCanceled = true;
    data['power'] = {...data['power'] as Map<String, dynamic>, 'pending': null};
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
      await tester.tap(find.widgetWithText(SwitchListTile, '매일 자동 백업'));
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

  group('백업 후 PC 전원 끄기', () {
    Future<_Admin> open(WidgetTester tester, Map<String, dynamic> power) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _Admin()..data.addAll({'enabled': true, 'power': power});
      await tester.pumpWidget(
        Provider<AdminRepository>.value(
          value: repo,
          child: const MaterialApp(home: DriveBackupPage()),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    Finder powerSwitch() =>
        find.widgetWithText(SwitchListTile, '백업 후 PC 전원 끄기');

    testWidgets('꺼져 있으면 유예·켤 시각을 숨기고, 켜면 저장한다', (tester) async {
      final repo = await open(tester, {
        'enabled': false,
        'ready': true,
        'grace_minutes': 5,
        'wake_hour': 7,
        'wake_minute': 0,
      });
      expect(find.text('끄기 전 유예  '), findsNothing);
      expect(find.text('다시 켤 시각 (한국)  '), findsNothing);
      await tester.tap(powerSwitch());
      await tester.pumpAndSettle();
      expect(repo.powerCalls.single, {
        'enabled': true,
        'grace_minutes': 5,
        'wake_hour': 7,
        'wake_minute': 0,
      });
      expect(find.text('끄기 전 유예  '), findsOneWidget);
      expect(find.text('07:00'), findsOneWidget);

      await tester.tap(find.text('5분'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15분').last);
      await tester.pumpAndSettle();
      expect(repo.powerCalls.last['grace_minutes'], 15);
      expect(repo.powerCalls.last['enabled'], isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('도우미가 없으면 켤 수 없고 설치 방법을 안내한다', (tester) async {
      final repo = await open(tester, {'enabled': false, 'ready': false});
      expect(tester.widget<SwitchListTile>(powerSwitch()).onChanged, isNull);
      expect(find.textContaining('power_helper.py --install'), findsOneWidget);
      expect(repo.powerCalls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('카운트다운 중이면 이번만 취소할 수 있다', (tester) async {
      final repo = await open(tester, {
        'enabled': true,
        'ready': true,
        'grace_minutes': 5,
        'wake_hour': 6,
        'wake_minute': 30,
        'pending': {
          'shutdown_at': '2026-10-03T03:05:00+09:00',
          'wake_at': '2026-10-03T06:30:00+09:00',
        },
      });
      expect(find.textContaining('다시 켜집니다'), findsOneWidget);
      expect(find.text('06:30'), findsOneWidget);
      await tester.tap(find.text('이번만 취소'));
      await tester.pumpAndSettle();
      expect(repo.powerCanceled, isTrue);
      expect(find.text('이번만 취소'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
