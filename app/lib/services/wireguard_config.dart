/// WireGuard 설정(.conf) 읽기 · 검사 · 고치기.
///
/// 공유기(ipTIME)가 피어마다 만들어 주는 설정을 앱이 이해하기 위한 것이다.
/// QR 로 찍든 파일로 가져오든 들어오는 내용은 같은 INI 형식이라, 화면과 분리해
/// 여기 하나만 둔다.
///
/// **비밀키는 다루되 드러내지 않는다.** `PrivateKey` 와 `PresharedKey` 는 그대로
/// 보존해서 다시 써 내보내지만, [summary] 나 [problems] 같은 사람이 보는 출력에는
/// 절대 싣지 않는다. 화면에 찍히거나 로그에 남으면 그 피어는 재발급해야 한다.
library;

/// 비밀로 다뤄야 하는 키. 사람이 보는 출력에서 제외한다.
const _secretKeys = {'privatekey', 'presharedkey'};

/// 현재 사내망과 공유기 WireGuard 인터페이스의 대역.
const defaultLanSubnet = '192.168.121.0/24';
const defaultVpnSubnet = '10.153.127.0/24';

/// 공유기 NAT 매핑이 끊겨 첫 접속이 지연되는 것을 막는 값.
const defaultKeepalive = 25;

/// INI 한 구역. 키 순서와 원문 대소문자를 지켜서, 다시 써 낼 때 공유기가 준
/// 파일과 최대한 비슷하게 남긴다.
class _Section {
  _Section(this.name);
  final String name;
  final List<MapEntry<String, String>> entries = [];

  String? get(String key) {
    final want = key.toLowerCase();
    for (final e in entries) {
      if (e.key.toLowerCase() == want) return e.value;
    }
    return null;
  }

  void set(String key, String value) {
    final want = key.toLowerCase();
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].key.toLowerCase() == want) {
        entries[i] = MapEntry(entries[i].key, value);
        return;
      }
    }
    entries.add(MapEntry(key, value));
  }

  void remove(String key) {
    final want = key.toLowerCase();
    entries.removeWhere((e) => e.key.toLowerCase() == want);
  }
}

class WireguardConfigException implements Exception {
  const WireguardConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WireguardConfig {
  WireguardConfig._(this._interface, this._peer);

  final _Section _interface;
  final _Section _peer;

  /// 공유기가 준 텍스트를 읽는다.
  ///
  /// QR 이 담고 있는 것도 이 텍스트 그대로다 - WireGuard QR 은 설정 파일을
  /// 그대로 인코딩한 것이라 따로 풀 것이 없다.
  static WireguardConfig parse(String text) {
    // QR 리더와 파일 입력 모두에서 BOM 과 CRLF 가 섞여 들어온다.
    final cleaned = text.replaceAll('﻿', '').replaceAll('\r\n', '\n');

    _Section? interface;
    _Section? peer;
    _Section? current;

    for (final rawLine in cleaned.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }

      if (line.startsWith('[') && line.endsWith(']')) {
        final name = line.substring(1, line.length - 1).trim().toLowerCase();
        if (name == 'interface') {
          current = interface ??= _Section('Interface');
        } else if (name == 'peer') {
          // 피어가 여럿인 설정은 사내 용도에 없다. 첫 번째만 쓴다.
          current = peer ??= _Section('Peer');
        } else {
          current = null;
        }
        continue;
      }

      final eq = line.indexOf('=');
      if (eq <= 0 || current == null) continue;
      final key = line.substring(0, eq).trim();
      // 값 안에 '=' 가 또 있다(키가 base64 라 끝이 '=' 로 끝난다). 첫 '=' 에서만 자른다.
      final value = line.substring(eq + 1).trim();
      if (key.isEmpty) continue;
      current.set(key, value);
    }

    if (interface == null) {
      throw const WireguardConfigException(
        'WireGuard 설정이 아닙니다. [Interface] 구역을 찾지 못했습니다.',
      );
    }
    if (peer == null) {
      throw const WireguardConfigException(
        'WireGuard 설정이 아닙니다. [Peer] 구역을 찾지 못했습니다.',
      );
    }
    return WireguardConfig._(interface, peer);
  }

  // --- 사람이 봐도 되는 값들 (비밀키는 여기 없다) ---

  String? get address => _interface.get('Address');
  String? get dns => _interface.get('DNS');
  String? get endpoint => _peer.get('Endpoint');
  String? get allowedIps => _peer.get('AllowedIPs');
  String? get keepalive => _peer.get('PersistentKeepalive');

  /// 서버 공개키. 공개키라 보여 줘도 된다.
  String? get peerPublicKey => _peer.get('PublicKey');

  bool get hasPrivateKey => (_interface.get('PrivateKey') ?? '').isNotEmpty;

  /// 인터넷까지 전부 터널을 타는 설정인가.
  ///
  /// ipTIME 이 만들어 주는 기본값이 이것인데, 그대로 쓰면 직원 인터넷이 회사
  /// 업로드 속도에 묶인다. 분할 터널로 고쳐 쓰라고 안내해야 한다.
  bool get isFullTunnel => _cidrs(allowedIps).any((c) => c.prefix == 0);

  /// 화면에 띄워도 되는 요약. **비밀키는 들어가지 않는다.**
  Map<String, String> get summary => {
    if (address != null) '내 주소': address!,
    if (endpoint != null) '접속 대상': endpoint!,
    if (allowedIps != null) '터널 경유 대역': allowedIps!,
    if (keepalive != null) 'Keepalive': keepalive!,
  };

  /// 막지는 않되 알려 줘야 할 것들. 비어 있으면 그대로 써도 좋다.
  List<String> problems() {
    final out = <String>[];
    if (!hasPrivateKey) {
      out.add('PrivateKey 가 없습니다. 공유기에서 받은 설정이 맞는지 확인해 주세요.');
    }
    if ((peerPublicKey ?? '').isEmpty) {
      out.add('서버 PublicKey 가 없습니다.');
    }
    if ((endpoint ?? '').isEmpty) {
      out.add('Endpoint 가 없어 어디로 접속할지 알 수 없습니다.');
    }
    if ((allowedIps ?? '').isEmpty) {
      out.add('AllowedIPs 가 없습니다.');
    } else if (isFullTunnel) {
      out.add(
        '전체 터널(0.0.0.0/0) 설정입니다. 인터넷까지 회사 회선을 거치므로 '
        '분할 터널로 고쳐 쓰기를 권합니다.',
      );
    }
    if ((keepalive ?? '').isEmpty) {
      out.add('PersistentKeepalive 가 없습니다. 첫 접속이 느릴 수 있습니다.');
    }
    return out;
  }

  /// 이 터널로 [host] 에 닿을 수 있는가.
  ///
  /// 서버 주소(192.168.121.2 같은 사내 IP)가 AllowedIPs 안에 들어 있는지 본다.
  /// 들어 있지 않으면 VPN 을 켜도 앱이 서버를 찾지 못한다 - 가져오기 화면에서
  /// 미리 잡아야 할 실수다.
  ///
  /// 호스트 이름(DDNS 등)은 IP 를 알 수 없으므로 판단하지 않고 null 을 준다.
  bool? covers(String host) {
    final ip = _parseIpv4(host);
    if (ip == null) return null;
    final ranges = _cidrs(allowedIps);
    if (ranges.isEmpty) return null;
    return ranges.any((c) => c.contains(ip));
  }

  /// 분할 터널로 고친 사본.
  ///
  /// deploy/fix-wireguard-conf.ps1 이 PC 에서 하던 일과 같다. 회사망과 VPN
  /// 대역만 터널을 타고, DNS 는 지우며(IP 로 접속하므로 불필요), keepalive 를
  /// 넣는다. 비밀키는 손대지 않는다.
  WireguardConfig toSplitTunnel({
    String lanSubnet = defaultLanSubnet,
    String vpnSubnet = defaultVpnSubnet,
    int keepaliveSeconds = defaultKeepalive,
  }) {
    final iface = _Section('Interface')..entries.addAll(_interface.entries);
    final peer = _Section('Peer')..entries.addAll(_peer.entries);
    iface.remove('DNS');
    peer.set('AllowedIPs', '$lanSubnet, $vpnSubnet');
    peer.set('PersistentKeepalive', '$keepaliveSeconds');
    return WireguardConfig._(iface, peer);
  }

  /// 파일로 저장하거나 공식 WireGuard 앱에 넘길 텍스트.
  String toIni() {
    final b = StringBuffer();
    for (final section in [_interface, _peer]) {
      b.writeln('[${section.name}]');
      for (final e in section.entries) {
        b.writeln('${e.key} = ${e.value}');
      }
      b.writeln();
    }
    return b.toString();
  }

  /// 로그에 찍혀도 비밀이 새지 않도록.
  @override
  String toString() =>
      'WireguardConfig(endpoint: $endpoint, allowedIps: $allowedIps)';

  // ------------------------------------------------------------ CIDR

  static List<_Cidr> _cidrs(String? value) {
    if (value == null || value.trim().isEmpty) return const [];
    final out = <_Cidr>[];
    for (final part in value.split(',')) {
      final cidr = _Cidr.tryParse(part.trim());
      if (cidr != null) out.add(cidr);
    }
    return out;
  }
}

/// IPv4 대역 하나. IPv6 는 사내 구성에 쓰지 않으므로 무시한다.
class _Cidr {
  const _Cidr(this.base, this.prefix);
  final int base;
  final int prefix;

  static _Cidr? tryParse(String text) {
    if (text.isEmpty) return null;
    final slash = text.indexOf('/');
    final host = slash < 0 ? text : text.substring(0, slash);
    final ip = _parseIpv4(host);
    if (ip == null) return null;
    var prefix = 32;
    if (slash >= 0) {
      prefix = int.tryParse(text.substring(slash + 1)) ?? -1;
      if (prefix < 0 || prefix > 32) return null;
    }
    final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return _Cidr(ip & mask, prefix);
  }

  bool contains(int ip) {
    if (prefix == 0) return true;
    final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return (ip & mask) == base;
  }
}

/// 점 넷 표기를 32비트 정수로. 형식이 아니면 null.
int? _parseIpv4(String text) {
  final parts = text.trim().split('.');
  if (parts.length != 4) return null;
  var out = 0;
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return null;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out = (out << 8) | n;
  }
  return out;
}

/// 사람이 보는 출력에서 비밀키를 지운다. 문제 보고나 지원 요청에 붙일 때 쓴다.
String redactSecrets(String confText) {
  final out = StringBuffer();
  for (final line in confText.replaceAll('\r\n', '\n').split('\n')) {
    final eq = line.indexOf('=');
    if (eq > 0 &&
        _secretKeys.contains(line.substring(0, eq).trim().toLowerCase())) {
      out.writeln('${line.substring(0, eq).trim()} = (가림)');
    } else {
      out.writeln(line);
    }
  }
  return out.toString();
}
