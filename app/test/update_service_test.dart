import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:ddeck_app/services/update_service.dart';

void main() {
  test(
    'stream download verifies bytes, rejects oversize and cleans partial files',
    () async {
      final tmp = await Directory.systemTemp.createTemp('ddeck-stream-test');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        await tmp.delete(recursive: true);
      });
      List<int> content = utf8.encode('valid installer');
      server.listen((request) async {
        request.response.add(content);
        await request.response.close();
      });
      final good = List<int>.from(content);
      final service = UpdateService(directory: () async => tmp);
      final update = ClientUpdate(
        '1.0.8',
        8,
        '1.0.8-8',
        'ddeck-setup-1.0.8.exe',
        good.length,
        hashes.sha256.convert(good).toString(),
        'http://127.0.0.1:${server.port}',
      );
      final file = await service.download(update, CancelToken(), (_) {});
      expect(await file.readAsBytes(), good);
      await file.delete();
      content = List.filled(good.length + 1, 0);
      await expectLater(
        service.download(update, CancelToken(), (_) {}),
        throwsFormatException,
      );
      expect(await File('${file.path}.part').exists(), isFalse);
      expect(await file.exists(), isFalse);
      content = good;
      final cancel = CancelToken()..cancel();
      await expectLater(
        service.download(update, cancel, (_) {}),
        throwsA(isA<DioException>()),
      );
      expect(await File('${file.path}.part').exists(), isFalse);
    },
  );

  test('versions compare numerically including build; never downgrade', () {
    ClientUpdate candidate(String version, int build) =>
        ClientUpdate(version, build, '', '', 1, '', '');
    expect(candidate('1.0.10', 10).isNewerThan('1.0.9+9'), isTrue);
    expect(candidate('1.0.7', 8).isNewerThan('1.0.7+7'), isTrue);
    expect(candidate('1.0.7', 7).isNewerThan('1.0.7+7'), isFalse);
    expect(candidate('1.0.6', 100).isNewerThan('1.0.7+7'), isFalse);
    expect(
      () => ClientUpdate.versionParts('not-version'),
      throwsFormatException,
    );
  });

  test(
    'accept signed manifest; reject tampering and unsafe filenames',
    () async {
      final algorithm = Ed25519();
      final key = await algorithm.newKeyPairFromSeed(
        List.generate(32, (i) => i),
      );
      final public = base64Encode((await key.extractPublicKey()).bytes);
      final data = <String, dynamic>{
        'schema': 1,
        'version': '1.0.8',
        'build': 8,
        'release': '1.0.8-8',
        'artifacts': {
          'windows': {
            'filename': 'ddeck-setup-1.0.8.exe',
            'size': 12,
            'sha256': 'a' * 64,
          },
        },
      };
      Future<Map<String, dynamic>> sign() async {
        final bytes = utf8.encode(jsonEncode(data));
        return {
          'payload': base64Encode(bytes),
          'signature': base64Encode(
            (await algorithm.sign(bytes, keyPair: key)).bytes,
          ),
        };
      }

      final envelope = await sign();
      final release = await ClientUpdate.verified(
        envelope,
        public,
        'windows',
        'http://server',
      );
      expect(release.filename, 'ddeck-setup-1.0.8.exe');
      final tampered = Map<String, dynamic>.from(envelope);
      tampered['payload'] = base64Encode(utf8.encode('{}'));
      await expectLater(
        ClientUpdate.verified(tampered, public, 'windows', 'http://server'),
        throwsFormatException,
      );
      (data['artifacts'] as Map)['windows']['filename'] = '../evil.exe';
      await expectLater(
        ClientUpdate.verified(await sign(), public, 'windows', 'http://server'),
        throwsFormatException,
      );
    },
  );

  test(
    'file verification rejects both truncation and same-length corruption',
    () async {
      final tmp = await Directory.systemTemp.createTemp('ddeck-update-test');
      addTearDown(() => tmp.delete(recursive: true));
      final file = File('${tmp.path}/installer');
      final data = utf8.encode('installer');
      final update = ClientUpdate(
        '1.0.8',
        8,
        '',
        '',
        data.length,
        hashes.sha256.convert(data).toString(),
        '',
      );
      final service = UpdateService();
      await file.writeAsBytes(data);
      await service.verifyFile(file, update);
      await file.writeAsBytes(data.sublist(1));
      await expectLater(
        service.verifyFile(file, update),
        throwsFormatException,
      );
      await file.writeAsBytes(List.filled(data.length, 0));
      await expectLater(
        service.verifyFile(file, update),
        throwsFormatException,
      );
    },
  );
}
