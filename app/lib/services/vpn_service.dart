import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

import 'wireguard_config.dart';
import 'windows_vpn.dart';

/// 사외 접속용 WireGuard 터널.
///
/// Android는 공식 터널 라이브러리, Windows는 공식 WireGuard 서비스를 제어한다.
///
/// **설정에는 개인키가 들어 있다.** OS 보안 저장소를 사용하고, Windows 서비스
/// 실행 중에는 사용자·SYSTEM·관리자만 읽는 별도 설정 파일을 둔다.
/// 화면·로그에는 개인키를 표시하지 않는다. 사용자가 볼 수 있는 것은 "등록됨 /
/// 연결됨" 상태와 접속 대상뿐이다. 키를 확인할 방법을 일부러 두지 않았다 -
/// 볼 일이 없고, 볼 수 있으면 새어 나갈 수 있다.
class VpnService extends ChangeNotifier {
  VpnService({FlutterSecureStorage? storage, WindowsVpn? windows})
    : _windows =
          windows ?? (!kIsWeb && Platform.isWindows ? WindowsVpn() : null),
      _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;
  final WindowsVpn? _windows;
  Timer? _windowsPoll;
  bool _pollingWindows = false;
  bool _disposed = false;

  static const _kConfig = 'wg_config';
  static const _kEndpoint = 'wg_endpoint';

  /// 터널 이름. 안드로이드 설정·알림에 이 이름으로 보인다.
  static const _interfaceName = 'ddeck';
  static const _vpnName = 'd-ddeck 사외 접속';

  /// initialize() 를 한 번만 부르기 위한 표시.
  ///
  /// 인스턴스를 들고 있지 않는 이유: WireGuardFlutter.instance 가 돌려주는
  /// 타입(WireGuardFlutterInterface)이 패키지 진입점에서 export 되지 않아
  /// 필드로 선언할 수가 없다. instance 는 싱글턴 조회라 매번 불러도 싸다.
  bool _initialized = false;
  StreamSubscription<VpnStage>? _stageSub;

  bool _registered = false;
  bool _busy = false;
  VpnConnection _state = VpnConnection.disconnected;
  String? _endpoint;
  String? _error;

  /// 설정이 등록돼 있는가. 사내망에서만 쓰는 기기는 등록하지 않아도 된다.
  bool get isRegistered => _registered;

  /// 켜고 끄는 중인가. 버튼을 잠그는 데 쓴다.
  bool get isBusy => _busy;

  VpnConnection get state => _state;

  /// 접속 대상(호스트:포트). 개인키가 아니라 보여 줘도 된다.
  String? get endpoint => _endpoint;

  String? get error => _error;

  /// 이 플랫폼에서 앱이 터널을 올릴 수 있는가.
  ///
  /// Windows 서비스 생성·제거 시에만 UAC 권한을 요청한다.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isWindows;
  }

  /// 저장된 설정이 있는지 확인하고 터널 상태를 따라가기 시작한다.
  ///
  /// 앱 시작 때 한 번 부른다. 설정이 없어도 조용히 지나간다 - 사내망 전용
  /// 기기에서는 VPN 을 쓸 일이 없다.
  Future<void> bootstrap() async {
    if (!supportsTunnels) return;
    _registered = (await _read(_kConfig)) != null;
    _endpoint = await _read(_kEndpoint);
    if (_windows != null) {
      await _refreshWindows();
      _windowsPoll ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refreshWindows(),
      );
      return;
    }
    if (!_registered) {
      notifyListeners();
      return;
    }
    try {
      await _ensureInitialized();
      final wg = WireGuardFlutter.instance;
      _stageSub ??= wg.vpnStageSnapshot.listen(_onStage);
      _onStage(await wg.stage());
    } catch (e) {
      // 터널 상태를 못 읽어도 등록 사실은 유효하다. 켜기를 누를 때 다시 시도한다.
      _error = _friendly(e);
    }
    notifyListeners();
  }

  /// QR 이나 파일에서 읽은 설정을 등록한다.
  ///
  /// 전체 터널(0.0.0.0/0)이면 회사망만 타도록 좁혀서 저장한다. 직원 개인
  /// 인터넷까지 회사 회선을 거치게 두지 않으려는 것이고, 구 서버가 PC 에서
  /// 스크립트로 하던 일과 같다.
  bool get supportsTunnels => isSupported || _windows != null;
  bool get isWindowsClient => _windows != null;

  Future<void> _refreshWindows() async {
    if (_pollingWindows || _busy || _disposed) return;
    _pollingWindows = true;
    try {
      final state = await _windows!.status();
      if (!_busy && !_disposed) {
        _state = VpnConnection.values.firstWhere(
          (s) => s.name == state,
          orElse: () => VpnConnection.disconnected,
        );
        if (_state.isOn) _registered = true;
      }
    } catch (e) {
      _error = _friendly(e);
    } finally {
      _pollingWindows = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> register(
    WireguardConfig config, {
    bool? forceSplitTunnel,
  }) async {
    if (!supportsTunnels) {
      throw UnsupportedError("PC에서는 공식 WireGuard 앱을 사용해 주세요.");
    }
    if (_windows != null && (_state.isOn || _state.isMoving)) {
      throw StateError(
        'Disconnect the tunnel before replacing its configuration',
      );
    }
    if (_windows != null &&
        RegExp(
          r'^\s*(PreUp|PostUp|PreDown|PostDown)\s*=',
          multiLine: true,
          caseSensitive: false,
        ).hasMatch(config.toIni())) {
      throw const WindowsVpnException('invalid_config');
    }
    // Keep Windows routes/DNS identical to the working official configuration.
    // Existing stored configurations need re-importing; their original values
    // cannot be recovered after an older version normalized them.
    final splitTunnel = forceSplitTunnel ?? (_windows == null);
    final effective = (splitTunnel && config.isFullTunnel)
        ? config.toSplitTunnel()
        : config;

    await _write(_kConfig, effective.toIni());
    await _write(_kEndpoint, effective.endpoint ?? '');

    _registered = true;
    _endpoint = effective.endpoint;
    _error = null;
    notifyListeners();
  }

  /// 등록을 지운다. 기기를 반납하거나 피어를 재발급받을 때.
  Future<void> unregister() async {
    if (_windows != null) {
      await _windows.remove();
      _state = VpnConnection.disconnected;
    } else if (_state == VpnConnection.connected) {
      await disconnect();
    }
    await _delete(_kConfig);
    await _delete(_kEndpoint);
    _registered = false;
    _endpoint = null;
    _error = null;
    notifyListeners();
  }

  Future<void> connect() async {
    if (!supportsTunnels || _busy) return;
    final conf = await _read(_kConfig);
    if (conf == null) {
      _error = 'VPN 설정이 등록되지 않았습니다.';
      notifyListeners();
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      if (_windows != null) {
        await _windows.connect(conf);
        final status = await _windows.status();
        _state = status == 'connected'
            ? VpnConnection.connected
            : VpnConnection.disconnected;
        if (!_state.isOn) throw const WindowsVpnException('failed');
        return;
      }
      await _ensureInitialized();
      final wg = WireGuardFlutter.instance;
      _stageSub ??= wg.vpnStageSnapshot.listen(_onStage);
      // serverAddress 는 플러그인이 도달 확인에 쓴다. 설정에서 읽은 값 그대로.
      await wg.startVpn(
        serverAddress: _endpoint ?? '',
        wgQuickConfig: conf,
        providerBundleIdentifier: 'kr.co.ddeck.ddeck_app',
      );
    } catch (e) {
      _error = _friendly(e);
      _state = VpnConnection.disconnected;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    if (!supportsTunnels || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      _error = null;
      if (_windows != null) {
        await _windows.disconnect();
        _state = VpnConnection.disconnected;
        return;
      }
      await _ensureInitialized();
      await WireGuardFlutter.instance.stopVpn();
    } catch (e) {
      _error = _friendly(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> toggle() =>
      _state == VpnConnection.connected ? disconnect() : connect();

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await WireGuardFlutter.instance.initialize(
      interfaceName: _interfaceName,
      vpnName: _vpnName,
    );
    _initialized = true;
  }

  void _onStage(VpnStage stage) {
    _state = switch (stage) {
      VpnStage.connected => VpnConnection.connected,
      VpnStage.connecting ||
      VpnStage.preparing ||
      VpnStage.authenticating ||
      VpnStage.waitingConnection => VpnConnection.connecting,
      VpnStage.disconnecting => VpnConnection.disconnecting,
      _ => VpnConnection.disconnected,
    };
    notifyListeners();
  }

  /// 플러그인 예외를 사람이 읽을 문구로.
  ///
  /// 예외 원문을 그대로 띄우지 않는 이유: 메시지에 설정 내용이 섞여 나올 수
  /// 있고, 그 안에 개인키가 들어 있을 수 있다.
  String _friendly(Object e) {
    if (e is WindowsVpnException) {
      return switch (e.code) {
        'not_installed' => '공식 WireGuard를 먼저 설치한 뒤 다시 연결하세요.',
        'permission' => 'Windows 관리자 권한 요청을 취소했거나 권한이 없습니다. 연결 버튼으로 다시 시도하세요.',
        'config_access' =>
          'VPN 설정 폴더의 접근 권한을 설정하지 못했습니다. Windows 계정 권한과 보안 프로그램의 차단 여부를 확인하세요.',
        'config_write' =>
          'VPN 설정 파일을 저장하지 못했습니다. 저장 공간과 보안 프로그램의 차단 여부를 확인하세요.',
        'service_install' =>
          'WireGuard 터널 서비스 등록에 실패했습니다. 공식 WireGuard의 로그에서 오류를 확인하세요.',
        'service_start' =>
          'WireGuard 터널 서비스가 시작되지 않았습니다. 공식 WireGuard의 같은 터널을 비활성화한 뒤 다시 시도하고 로그를 확인하세요.',
        'service_remove' =>
          '기존 WireGuard 터널 서비스를 제거하지 못했습니다. Windows 관리자 권한과 서비스 상태를 확인하세요.',
        'process_result' =>
          'WireGuard 실행 결과를 확인하지 못했습니다. 공식 WireGuard에서 터널 상태를 확인하세요.',
        'unsafe_path' => 'VPN 설정 저장 경로가 안전한 일반 폴더가 아닙니다. 관리자에게 문의하세요.',
        'timeout' => '연결 처리 시간이 초과되었습니다. Windows 권한 창과 VPN 상태를 확인하세요.',
        'invalid_config' =>
          '올바른 WireGuard 설정 파일을 선택하세요. 실행 명령이 포함된 설정은 지원하지 않습니다.',
        _ => 'Windows VPN 작업에 실패했습니다. WireGuard 설치와 설정 파일을 확인하세요.',
      };
    }
    final text = e.toString().toLowerCase();
    if (text.contains('permission') || text.contains('denied')) {
      return 'VPN 권한이 필요합니다. 안내 창에서 허용해 주세요.';
    }
    if (text.contains('not initialized')) {
      return 'VPN 을 준비하지 못했습니다. 앱을 다시 시작해 주세요.';
    }
    return 'VPN 연결에 실패했습니다. 잠시 후 다시 시도해 주세요.';
  }

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      throw StateError("VPN 보안 저장소에 설정을 저장하지 못했습니다.");
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      throw StateError("VPN 보안 저장소의 설정을 삭제하지 못했습니다.");
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _windowsPoll?.cancel();
    _stageSub?.cancel();
    super.dispose();
  }
}

/// 화면이 신경 쓰는 만큼의 상태. 플러그인의 세부 단계는 여기서 접는다.
enum VpnConnection {
  disconnected('연결 안 됨'),
  connecting('연결 중'),
  connected('연결됨'),
  disconnecting('해제 중');

  const VpnConnection(this.label);
  final String label;

  bool get isOn => this == VpnConnection.connected;
  bool get isMoving =>
      this == VpnConnection.connecting || this == VpnConnection.disconnecting;
}
