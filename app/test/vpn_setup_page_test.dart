import 'package:ddeck_app/state/theme_state.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ddeck_app/services/vpn_service.dart';
import 'package:ddeck_app/core/token_store.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:ddeck_app/ui/auth/login_page.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ddeck_app/ui/vpn/vpn_setup_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _config = '''
[Interface]
PrivateKey = private-test-secret
Address = 10.109.203.7/24
[Peer]
PublicKey = public-test-key
PresharedKey = preshared-test-secret
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
''';

class _Picker extends FilePicker {
  Uint8List bytes = Uint8List.fromList(utf8.encode(_config));

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, ['conf']);
    return FilePickerResult([
      PlatformFile(name: 'test.conf', size: bytes.length, bytes: bytes),
    ]);
  }
}

class _Vpn extends VpnService {
  @override
  bool get supportsTunnels => true;
  VpnConnection connection = VpnConnection.disconnected;
  bool busy = false;
  String? failure;
  int toggles = 0;

  @override
  VpnConnection get state => connection;
  @override
  bool get isBusy => busy;
  @override
  String? get error => failure;
  @override
  Future<void> toggle() async {
    toggles++;
    connection = connection.isOn
        ? VpnConnection.disconnected
        : VpnConnection.connected;
    notifyListeners();
  }

  void refresh() => notifyListeners();
}

class _LoggedOutAuth extends ChangeNotifier implements AuthState {
  @override
  String get serverUrl => 'http://localhost:8000';
  @override
  final tokenStore = TokenStore();
  @override
  String? get notice => null;
  @override
  Future<bool> readRememberMe() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Picker picker;
  late _Vpn vpn;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    picker = _Picker();
    FilePicker.platform = picker;
    vpn = _Vpn();
  });

  Future<void> import(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<VpnService>.value(
        value: vpn,
        child: MaterialApp(
          // 테스트 환경에는 InkSparkle 셰이더가 없으므로 탭 효과만 끈다.
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const VpnSetupPage(),
        ),
      ),
    );
    expect(find.text('사외에서 접속하려면 VPN 등록이 필요합니다'), findsOneWidget);
    await tester.tap(find.text('VPN 등록'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('설정 파일 가져오기'));
    await tester.pumpAndSettle();
  }

  testWidgets('지원 플랫폼 로그인 화면에 VPN 표시', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<VpnService>.value(
        value: vpn,
        child: ChangeNotifierProvider<AuthState>(
          create: (_) => _LoggedOutAuth(),
          child: ChangeNotifierProvider<ThemeState>(
            create: (_) => ThemeState(),
            child: MaterialApp(
              theme: ThemeData(splashFactory: NoSplash.splashFactory),
              home: const LoginPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('로그인'), findsOneWidget);
    expect(find.text('디떽 업무 서버'), findsOneWidget);
    expect(find.textContaining('localhost'), findsNothing);
    expect(find.text('서버 주소'), findsNothing);
    expect(find.text('관리자 연결 설정 가져오기'), findsOneWidget);
    expect(
      find.text('VPN 등록'),
      VpnService.isSupported ? findsOneWidget : findsNothing,
    );
    expect(find.text('사외 접속(VPN)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('설정을 바로 등록하고 비밀키와 피어 정보를 표시하지 않는다', (tester) async {
    await import(tester);
    expect(vpn.isRegistered, isTrue);
    expect(find.textContaining('vpn.example.com:51820'), findsNothing);
    expect(find.textContaining('연결 안 됨'), findsOneWidget);
    for (final value in [
      'private-test-secret',
      'preshared-test-secret',
      'public-test-key',
      '10.109.203.7/24',
      '0.0.0.0/0',
      '192.168.0.0/24',
      'PrivateKey',
      'PresharedKey',
      'PublicKey',
      'Address',
      'AllowedIPs',
    ]) {
      expect(find.textContaining(value), findsNothing);
    }
    expect(find.byType(Table), findsNothing);
    expect(find.text('WireGuard 앱으로 보내기'), findsNothing);
    final saved = await const FlutterSecureStorage().read(key: 'wg_config');
    expect(saved, contains('192.168.0.0/24, 10.109.203.0/24'));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('연결됨'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('연결 안 됨'), findsOneWidget);
    expect(vpn.toggles, 2);
  });

  testWidgets('등록 해제는 취소할 수 있고 확인하면 설정을 삭제한다', (tester) async {
    await import(tester);
    Future<void> open() async {
      await tester.tap(find.byTooltip('VPN 관리'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('VPN 등록 해제'));
      await tester.pumpAndSettle();
    }

    await open();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(vpn.isRegistered, isTrue);
    await open();
    await tester.tap(find.text('등록 해제'));
    await tester.pumpAndSettle();
    expect(vpn.isRegistered, isFalse);
    expect(await const FlutterSecureStorage().read(key: 'wg_config'), isNull);
    expect(find.text('VPN 등록'), findsOneWidget);
  });

  testWidgets('작업 중 스위치를 잠그고 상태 전환 중 진행 표시와 오류를 보여 준다', (tester) async {
    await import(tester);
    vpn.busy = true;
    vpn.refresh();
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    for (final state in [
      VpnConnection.connecting,
      VpnConnection.disconnecting,
    ]) {
      vpn.connection = state;
      vpn.refresh();
      await tester.pump();
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining(state.label), findsOneWidget);
    }
    vpn.connection = VpnConnection.disconnected;
    vpn.busy = false;
    vpn.failure = 'VPN 권한이 필요합니다. 안내 창에서 허용해 주세요.';
    vpn.refresh();
    await tester.pumpAndSettle();
    expect(find.text(vpn.failure!), findsOneWidget);
  });

  testWidgets('파일 디코딩 실패 시 예외 원문을 노출하지 않는다', (tester) async {
    picker.bytes = Uint8List.fromList([
      ...utf8.encode('private-test-secret'),
      255,
    ]);
    await import(tester);
    expect(find.textContaining('VPN 설정을 등록하지 못했습니다.'), findsOneWidget);
    expect(find.textContaining('private-test-secret'), findsNothing);
    expect(vpn.isRegistered, isFalse);
    expect(tester.takeException(), isNull);
  });
}
