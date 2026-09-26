import 'package:ddeck_app/services/wireguard_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// ipTIME 이 실제로 만들어 주는 모양: 전체 터널에 DNS 가 붙어 있고
/// PersistentKeepalive 는 없다.
const routerDefault = '''
[Interface]
PrivateKey = qJ8vZ1nKQ0pR3sT5uW7xY9aB2cD4eF6gH8iJ0kL2mN0=
Address = 10.109.203.7/24
DNS = 192.168.0.1

[Peer]
PublicKey = aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ3aB4c=
PresharedKey = zY9xW8vU7tS6rQ5pO4nM3lK2jI1hG0fE9dC8bA7zY6x=
AllowedIPs = 0.0.0.0/0
Endpoint = ddeck.iptime.org:51820
''';

/// 문서(deploy/README-vpn.md)가 권장하는 모양.
const splitTunnel = '''
[Interface]
PrivateKey = qJ8vZ1nKQ0pR3sT5uW7xY9aB2cD4eF6gH8iJ0kL2mN0=
Address    = 10.109.203.7/24

[Peer]
PublicKey    = aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ3aB4c=
PresharedKey = zY9xW8vU7tS6rQ5pO4nM3lK2jI1hG0fE9dC8bA7zY6x=
AllowedIPs   = 192.168.0.0/24, 10.109.203.0/24
Endpoint     = 1.2.3.4:51820
PersistentKeepalive = 25
''';

void main() {
  group('설정 읽기', () {
    test('공유기 기본 설정을 읽는다', () {
      final c = WireguardConfig.parse(routerDefault);
      expect(c.address, '10.109.203.7/24');
      expect(c.endpoint, 'ddeck.iptime.org:51820');
      expect(c.allowedIps, '0.0.0.0/0');
      expect(c.dns, '192.168.0.1');
      expect(c.hasPrivateKey, isTrue);
    });

    test('키 끝의 = 를 값에서 잘라 먹지 않는다', () {
      // base64 키는 = 로 끝난다. 첫 = 에서만 잘라야 한다.
      final c = WireguardConfig.parse(routerDefault);
      expect(c.peerPublicKey, endsWith('='));
      expect(c.peerPublicKey, 'aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ3aB4c=');
    });

    test('BOM 과 CRLF 가 섞여 있어도 읽는다', () {
      final messy = '﻿${routerDefault.replaceAll('\n', '\r\n')}';
      expect(WireguardConfig.parse(messy).address, '10.109.203.7/24');
    });

    test('주석과 빈 줄을 건너뛴다', () {
      final c = WireguardConfig.parse('''
# 홍길동 노트북
[Interface]
PrivateKey = qJ8vZ1nKQ0pR3sT5uW7xY9aB2cD4eF6gH8iJ0kL2mN0=
Address = 10.109.203.7/24
; DNS = 192.168.0.1

[Peer]
PublicKey = aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ3aB4c=
AllowedIPs = 192.168.0.0/24
Endpoint = 1.2.3.4:51820
''');
      expect(c.dns, isNull, reason: '주석 처리된 DNS 는 값이 아니다');
      expect(c.allowedIps, '192.168.0.0/24');
    });

    test('WireGuard 설정이 아니면 거절한다', () {
      expect(
        () => WireguardConfig.parse('https://example.com'),
        throwsA(isA<WireguardConfigException>()),
      );
      expect(
        () => WireguardConfig.parse('[Interface]\nAddress = 10.0.0.1/24'),
        throwsA(isA<WireguardConfigException>()),
        reason: 'Peer 가 없으면 접속할 대상이 없다',
      );
    });
  });

  group('검사', () {
    test('전체 터널을 잡아낸다', () {
      final c = WireguardConfig.parse(routerDefault);
      expect(c.isFullTunnel, isTrue);
      expect(c.problems().any((p) => p.contains('전체 터널')), isTrue);
      expect(c.problems().any((p) => p.contains('Keepalive')), isTrue);
    });

    test('권장 설정에는 지적할 것이 없다', () {
      expect(WireguardConfig.parse(splitTunnel).problems(), isEmpty);
    });

    test('요약에 비밀키가 들어가지 않는다', () {
      final c = WireguardConfig.parse(splitTunnel);
      final dumped = c.summary.values.join(' ') + c.toString();
      expect(dumped, isNot(contains('qJ8vZ1nK')), reason: 'PrivateKey 노출');
      expect(dumped, isNot(contains('zY9xW8vU')), reason: 'PresharedKey 노출');
    });
  });

  group('서버에 닿는지', () {
    test('사내 서버가 터널 대역 안에 있으면 true', () {
      final c = WireguardConfig.parse(splitTunnel);
      expect(c.covers('192.168.0.20'), isTrue);
      expect(c.covers('10.109.203.1'), isTrue);
    });

    test('대역 밖이면 false', () {
      final c = WireguardConfig.parse(splitTunnel);
      expect(
        c.covers('192.168.1.20'),
        isFalse,
        reason: '192.168.0.0/24 에 192.168.1.x 는 없다',
      );
      expect(c.covers('8.8.8.8'), isFalse);
    });

    test('전체 터널이면 무엇이든 닿는다', () {
      expect(WireguardConfig.parse(routerDefault).covers('8.8.8.8'), isTrue);
    });

    test('호스트 이름은 판단하지 않는다', () {
      expect(
        WireguardConfig.parse(splitTunnel).covers('miniserver.local'),
        isNull,
      );
    });
  });

  group('분할 터널로 고치기', () {
    test('AllowedIPs 를 회사망으로 좁히고 DNS 를 지운다', () {
      final fixed = WireguardConfig.parse(routerDefault).toSplitTunnel();
      expect(fixed.isFullTunnel, isFalse);
      expect(fixed.allowedIps, '192.168.0.0/24, 10.109.203.0/24');
      expect(fixed.dns, isNull);
      expect(fixed.keepalive, '25');
      expect(fixed.problems(), isEmpty);
    });

    test('비밀키를 그대로 보존한다', () {
      final fixed = WireguardConfig.parse(routerDefault).toSplitTunnel();
      // 내보낸 텍스트에는 있어야 공식 앱이 터널을 올릴 수 있다.
      expect(
        fixed.toIni(),
        contains('qJ8vZ1nKQ0pR3sT5uW7xY9aB2cD4eF6gH8iJ0kL2mN0='),
      );
      expect(
        fixed.toIni(),
        contains('zY9xW8vU7tS6rQ5pO4nM3lK2jI1hG0fE9dC8bA7zY6x='),
      );
    });

    test('고친 결과를 다시 읽을 수 있다', () {
      final once = WireguardConfig.parse(routerDefault).toSplitTunnel();
      final twice = WireguardConfig.parse(once.toIni());
      expect(twice.allowedIps, once.allowedIps);
      expect(twice.endpoint, once.endpoint);
    });
  });

  test('지원 요청용 가림 처리', () {
    final red = redactSecrets(routerDefault);
    expect(red, isNot(contains('qJ8vZ1nK')));
    expect(red, isNot(contains('zY9xW8vU')));
    expect(red, contains('PrivateKey = (가림)'));
    expect(
      red,
      contains('Endpoint = ddeck.iptime.org:51820'),
      reason: '비밀이 아닌 값은 남아야 문제 파악에 쓸모가 있다',
    );
  });
}
