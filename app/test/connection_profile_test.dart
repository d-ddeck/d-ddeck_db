import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:ddeck_app/core/config.dart';
import 'package:ddeck_app/services/connection_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects remote HTTP, credentials and ambiguous destinations', () {
    for (final url in [
      'http://192.168.0.20:8000',
      'https://user:pass@example.com',
      'https://example.com/path',
      'https://example.com?x=1',
      'https://example.com#x',
      'file:///tmp/a',
      'example.com',
    ]) {
      expect(() => AppConfig.secureServerUrl(url), throwsFormatException);
    }
    expect(
      AppConfig.secureServerUrl('https://example.com/'),
      'https://example.com',
    );
    expect(
      AppConfig.secureServerUrl('http://127.0.0.1:8000'),
      'http://127.0.0.1:8000',
    );
  });
  test('only genuine unexpired connection profiles are accepted', () async {
    final key = await Ed25519().newKeyPair();
    final public = base64Encode((await key.extractPublicKey()).bytes);
    final now = DateTime.utc(2026, 9, 29);
    Future<String> envelope({
      String purpose = 'ddeck-connection',
      int days = 2,
      String url = 'https://example.com',
    }) async {
      final bytes = utf8.encode(
        jsonEncode({
          'purpose': purpose,
          'schema': 1,
          'server_url': url,
          'issued_at': now.toIso8601String(),
          'expires_at': now.add(Duration(days: days)).toIso8601String(),
        }),
      );
      return jsonEncode({
        'payload': base64Encode(bytes),
        'signature': base64Encode(
          (await Ed25519().sign(bytes, keyPair: key)).bytes,
        ),
      });
    }

    final valid = await envelope();
    expect(
      await ConnectionProfile.verify(valid, public, now: now),
      'https://example.com',
    );
    for (final invalid in [
      await envelope(days: -1),
      await envelope(days: 8),
      await envelope(purpose: 'update'),
      await envelope(url: 'http://10.0.0.1'),
    ]) {
      await expectLater(
        ConnectionProfile.verify(invalid, public, now: now),
        throwsFormatException,
      );
    }
    final changed = jsonDecode(valid) as Map<String, dynamic>;
    changed['payload'] = base64Encode(utf8.encode('{}'));
    await expectLater(
      ConnectionProfile.verify(jsonEncode(changed), public, now: now),
      throwsFormatException,
    );
  });
}
