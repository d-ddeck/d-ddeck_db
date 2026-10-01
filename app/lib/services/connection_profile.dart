import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../core/config.dart';

class ConnectionProfile {
  static Future<String> verify(
    String text,
    String publicKey, {
    DateTime? now,
  }) async {
    if (text.length > 16384) throw const FormatException('설정 파일이 너무 큽니다.');
    final envelope = jsonDecode(text) as Map<String, dynamic>;
    final payload = base64Decode(envelope['payload'] as String);
    final valid = await Ed25519().verify(
      payload,
      signature: Signature(
        base64Decode(envelope['signature'] as String),
        publicKey: SimplePublicKey(
          base64Decode(publicKey.trim()),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) throw const FormatException('관리자 서명을 확인할 수 없습니다.');
    final data = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    final current = (now ?? DateTime.now()).toUtc();
    final expires = DateTime.parse(data['expires_at'] as String).toUtc();
    final issued = DateTime.parse(data['issued_at'] as String).toUtc();
    if (data['purpose'] != 'ddeck-connection' ||
        data['schema'] != 1 ||
        !expires.isAfter(current) ||
        issued.isAfter(current.add(const Duration(minutes: 5))) ||
        !expires.isAfter(issued) ||
        expires.difference(issued) > const Duration(days: 7)) {
      throw const FormatException('만료되었거나 유효하지 않은 연결 설정입니다.');
    }
    return AppConfig.secureServerUrl(data['server_url'] as String);
  }
}
