import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

import 'wireguard_config.dart';

/// 사외 접속용 WireGuard 터널.
///
/// 터널을 앱이 직접 올리고 내린다. 바탕은 WireGuard 공식 안드로이드
/// 라이브러리(`com.wireguard.android:tunnel`)이고, 이 클래스가 하는 일은
/// 설정을 안전하게 보관하고 켜고 끄는 것뿐이다.
///
/// **설정에는 개인키가 들어 있다.** 그래서 OS 키스토어(안드로이드 Keystore)에만
/// 넣고, 화면·로그 어디에도 꺼내지 않는다. 사용자가 볼 수 있는 것은 "등록됨 /
/// 연결됨" 상태와 접속 대상뿐이다. 키를 확인할 방법을 일부러 두지 않았다 -
/// 볼 일이 없고, 볼 수 있으면 새어 나갈 수 있다.
class VpnService extends ChangeNotifier {
  VpnService({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;

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
  /// 데스크톱은 터널을 만들려면 관리자 권한이 필요해서 일반 사용자로 실행되는
  /// 이 앱이 할 수 없다. 사내망 PC 는 VPN 이 필요 없고, 외부 PC 는 공식
  /// WireGuard 클라이언트를 쓰면 된다.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  /// 저장된 설정이 있는지 확인하고 터널 상태를 따라가기 시작한다.
  ///
  /// 앱 시작 때 한 번 부른다. 설정이 없어도 조용히 지나간다 - 사내망 전용
  /// 기기에서는 VPN 을 쓸 일이 없다.
  Future<void> bootstrap() async {
    if (!isSupported) return;
    _registered = (await _read(_kConfig)) != null;
    _endpoint = await _read(_kEndpoint);
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
  bool get supportsTunnels => isSupported;

  Future<void> register(
    WireguardConfig config, {
    bool forceSplitTunnel = true,
  }) async {
    if (!supportsTunnels) {
      throw UnsupportedError("PC에서는 공식 WireGuard 앱을 사용해 주세요.");
    }
    final effective = (forceSplitTunnel && config.isFullTunnel)
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
    if (_state == VpnConnection.connected) {
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
    if (!isSupported || _busy) return;
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
    if (!isSupported || _busy) return;
    _busy = true;
    notifyListeners();
    try {
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
      // 키스토어를 못 쓰는 기기에서도 앱은 계속 돌아야 한다. 등록만 안 남는다.
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }

  @override
  void dispose() {
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
