import 'dart:io';
import 'package:ddeck_app/core/company_tls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real TLS accepts company chain and rejects unknown CA and wrong IP',
    () async {
      final temp = await Directory.systemTemp.createTemp('ddeck-tls-test-');
      final python = Platform.environment['CA_TEST_PYTHON'] ?? 'python3';
      final script = File('../deploy/private_ca.py').absolute.path;
      Future<void> command(List<String> args) async {
        final result = await Process.run(python, [script, ...args]);
        expect(
          result.exitCode,
          0,
          reason: 'Test certificate generation failed',
        );
      }

      try {
        await command(['init', '--ca-dir', '${temp.path}/ca']);
        await command([
          'issue',
          '--ca-dir',
          '${temp.path}/ca',
          '--output',
          '${temp.path}/good',
          '--ip',
          '127.0.0.1',
        ]);
        await command([
          'issue',
          '--ca-dir',
          '${temp.path}/ca',
          '--output',
          '${temp.path}/wrong',
          '--ip',
          '192.0.2.1',
        ]);
        final ca = await File('${temp.path}/ca/ca.crt').readAsBytes();
        Future<void> check(
          String leaf, {
          required bool trust,
          required bool succeeds,
        }) async {
          final serverContext = SecurityContext()
            ..useCertificateChain('${temp.path}/$leaf/server.crt')
            ..usePrivateKey('${temp.path}/$leaf/server.key');
          final server = await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            serverContext,
          );
          final subscription = server.listen((request) {
            request.response.write('ok');
            request.response.close();
          }, onError: (_) {});
          final client = HttpClient(
            context: trust
                ? CompanyTls.context(certificate: ca)
                : SecurityContext(withTrustedRoots: true),
          );
          try {
            final request = client.getUrl(
              Uri.parse('https://127.0.0.1:${server.port}'),
            );
            if (succeeds) {
              final response = await (await request).close();
              expect(response.statusCode, 200);
              await response.drain<void>();
            } else {
              await expectLater(request, throwsA(isA<HandshakeException>()));
            }
          } finally {
            client.close(force: true);
            await server.close(force: true);
            await subscription.cancel();
          }
        }

        await check('good', trust: true, succeeds: true);
        await check('good', trust: false, succeeds: false);
        await check('wrong', trust: true, succeeds: false);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
