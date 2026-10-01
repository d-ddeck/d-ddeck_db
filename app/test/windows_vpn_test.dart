import 'package:ddeck_app/services/vpn_service.dart';
import 'package:ddeck_app/services/windows_vpn.dart';
import 'package:ddeck_app/services/wireguard_config.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const config = '''
[Interface]
PrivateKey = private-test-secret
Address = 10.153.127.7/24
[Peer]
PublicKey = public-test-key
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
''';

class FakeWindows extends WindowsVpn {
  String state = 'disconnected';
  String? failure;
  String? received;
  @override
  Future<String> status() async => state;
  @override
  Future<void> connect(String config) async {
    if (failure != null) throw WindowsVpnException(failure!);
    received = config;
    state = 'connected';
  }

  @override
  Future<void> disconnect() async {
    if (failure != null) throw WindowsVpnException(failure!);
    state = 'disconnected';
  }

  @override
  Future<void> remove() async {
    await disconnect();
    received = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeWindows windows;
  late VpnService vpn;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    windows = FakeWindows();
    vpn = VpnService(windows: windows);
  });
  tearDown(() => vpn.dispose());
  test('Windows registration connect disconnect and removal', () async {
    await vpn.register(WireguardConfig.parse(config));
    expect(vpn.isRegistered, isTrue);
    await vpn.connect();
    expect(vpn.state, VpnConnection.connected);
    expect(windows.received, contains('AllowedIPs = 0.0.0.0/0'));
    await vpn.disconnect();
    expect(vpn.state, VpnConnection.disconnected);
    await vpn.unregister();
    expect(vpn.isRegistered, isFalse);
    expect(await const FlutterSecureStorage().read(key: 'wg_config'), isNull);
  });
  test(
    'Windows keeps working DNS and routes unless split routing is requested',
    () async {
      final original = config.replaceFirst(
        'Address =',
        'DNS = 10.153.127.1\nAddress =',
      );
      await vpn.register(WireguardConfig.parse(original));
      await vpn.connect();
      expect(windows.received, contains('DNS = 10.153.127.1'));
      expect(windows.received, contains('AllowedIPs = 0.0.0.0/0'));
      await vpn.disconnect();
      await vpn.register(
        WireguardConfig.parse(original),
        forceSplitTunnel: true,
      );
      await vpn.connect();
      expect(windows.received, isNot(contains('DNS =')));
      expect(
        windows.received,
        contains('AllowedIPs = 192.168.121.0/24, 10.153.127.0/24'),
      );
      expect(windows.received, contains('PrivateKey = private-test-secret'));
    },
  );
  test(
    'UAC cancellation does not discard registration or report connected',
    () async {
      await vpn.register(WireguardConfig.parse(config));
      windows.failure = 'permission';
      await vpn.connect();
      expect(vpn.state, VpnConnection.disconnected);
      expect(vpn.isRegistered, isTrue);
      expect(vpn.error, contains('관리자 권한'));
      expect(vpn.error, isNot(contains('private-test-secret')));
    },
  );
  test(
    'Failed disconnect and unregister preserve live state and credentials',
    () async {
      await vpn.register(WireguardConfig.parse(config));
      await vpn.connect();
      windows.failure = 'permission';
      await vpn.disconnect();
      expect(vpn.state, VpnConnection.connected);
      await expectLater(vpn.unregister(), throwsA(isA<WindowsVpnException>()));
      expect(vpn.isRegistered, isTrue);
      expect(
        await const FlutterSecureStorage().read(key: 'wg_config'),
        isNotNull,
      );
    },
  );
  for (final failure in {
    'config_access': '접근 권한',
    'config_write': '저장하지 못했습니다',
    'service_install': '서비스 등록',
    'service_start': '시작되지 않았습니다',
    'service_remove': '제거하지 못했습니다',
    'process_result': '실행 결과',
    'unsafe_path': '저장 경로',
  }.entries) {
    test(
      'Windows failure ${failure.key} preserves registration and explains the stage',
      () async {
        await vpn.register(WireguardConfig.parse(config));
        windows.failure = failure.key;
        await vpn.connect();
        expect(vpn.state, VpnConnection.disconnected);
        expect(vpn.isRegistered, isTrue);
        expect(vpn.error, contains(failure.value));
        expect(vpn.error, isNot(contains('private-test-secret')));
        expect(
          await const FlutterSecureStorage().read(key: 'wg_config'),
          isNotNull,
        );
      },
    );
  }
  test('Windows startup reads current service state', () async {
    await vpn.register(WireguardConfig.parse(config));
    windows.state = 'connected';
    await vpn.bootstrap();
    expect(vpn.state, VpnConnection.connected);
  });
  test('Command hooks in imported configurations are rejected', () async {
    final text = config.replaceFirst(
      'Address =',
      'PostUp = dangerous-command\nAddress =',
    );
    await expectLater(
      vpn.register(WireguardConfig.parse(text)),
      throwsA(isA<WindowsVpnException>()),
    );
    expect(vpn.isRegistered, isFalse);
  });
}
