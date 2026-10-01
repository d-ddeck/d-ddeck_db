import 'dart:io';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';

/// Trust the company's public CA within this app only. Normal certificate
/// chain, expiry and hostname/IP verification remain enabled.
class CompanyTls {
  static Uint8List? _certificate;

  static Future<void> initialize() async {
    final data = await rootBundle.load('assets/company_ca.crt');
    _certificate = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    context(); // Fail at startup if the packaged certificate is malformed.
  }

  static SecurityContext context({List<int>? certificate}) {
    final result = SecurityContext(withTrustedRoots: true);
    final bytes = certificate ?? _certificate;
    if (bytes != null) result.setTrustedCertificatesBytes(bytes);
    return result;
  }

  static IOHttpClientAdapter adapter() => IOHttpClientAdapter(
    createHttpClient: () => HttpClient(context: context()),
  );
}
