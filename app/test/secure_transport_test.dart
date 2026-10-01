import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/core/api_exception.dart';
import 'package:ddeck_app/core/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

class Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'blocks plaintext before sending credentials; disables redirects on TLS',
    () async {
      final adapter = Adapter();
      final store = TokenStore()..accessToken = 'test-access';
      final api = ApiClient(tokenStore: store, adapter: adapter);
      await api.setServerUrl('http://192.168.0.20:8000', persist: false);
      await expectLater(
        api.get('/auth/me'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'HTTPS_REQUIRED'),
        ),
      );
      expect(adapter.requests, isEmpty);
      await api.setServerUrl('https://work.example.com', persist: false);
      await api.get('/auth/me');
      expect(adapter.requests.single.followRedirects, isFalse);
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer test-access',
      );
    },
  );
}
