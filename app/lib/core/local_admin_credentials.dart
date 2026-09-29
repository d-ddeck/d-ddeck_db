import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class LocalAdminCredentials {
  const LocalAdminCredentials(this.serverUrl, this.secret);
  final String serverUrl;
  final String secret;

  static Future<LocalAdminCredentials?> load() async {
    if (kIsWeb ||
        !(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      return null;
    }
    final profile =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (profile == null) return null;
    try {
      final file = File('$profile/.ddeck/local-admin-login.json');
      if (!await file.exists() || await file.length() > 4096) return null;
      return parse(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  static LocalAdminCredentials? parse(dynamic value) {
    if (value is! Map ||
        value['server_url'] is! String ||
        value['secret'] is! String) {
      return null;
    }
    final url = Uri.tryParse(value['server_url'] as String);
    final secret = value['secret'] as String;
    if (url == null ||
        !['http', 'https'].contains(url.scheme) ||
        !['localhost', '127.0.0.1', '::1'].contains(url.host) ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        (url.path.isNotEmpty && url.path != '/') ||
        secret.length < 32 ||
        secret.length > 200) {
      return null;
    }
    return LocalAdminCredentials(
      url.toString().replaceFirst(RegExp(r'/$'), ''),
      secret,
    );
  }
}
