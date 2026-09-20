import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Where the backend lives.
///
/// The default differs per platform because "localhost" does not mean the same
/// thing everywhere: an Android emulator reaches the host machine at 10.0.2.2,
/// and a physical phone needs the PC's LAN address. The user can override it on
/// the login screen, and the value is persisted, so a site can point the app at
/// its own server without a rebuild.
class AppConfig {
  static const String appName = 'd-ddeck';
  static const String apiPrefix = '/api/v1';

  /// Compile-time override: `flutter build windows --dart-define=SERVER_URL=...`
  static const String _compileTimeUrl = String.fromEnvironment('SERVER_URL');

  static String get defaultServerUrl {
    if (_compileTimeUrl.isNotEmpty) return _compileTimeUrl;
    if (kIsWeb) return 'http://127.0.0.1:8000';
    if (Platform.isAndroid) {
      // 10.0.2.2 is the emulator's alias for the host machine's loopback.
      // On a real device this must be changed to the PC's LAN IP.
      return 'http://10.0.2.2:8000';
    }
    return 'http://127.0.0.1:8000';
  }

  /// Normalises whatever the user typed into a usable origin.
  static String normalizeServerUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return defaultServerUrl;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    // Tolerate someone pasting the full API path or a docs link.
    if (url.endsWith(apiPrefix)) {
      url = url.substring(0, url.length - apiPrefix.length);
    }
    if (url.endsWith('/docs')) {
      url = url.substring(0, url.length - '/docs'.length);
    }
    return url;
  }

  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration receiveTimeout = Duration(seconds: 30);

  /// How often the shell re-checks the unread notification count.
  /// Push is not wired up on the server yet, so the client polls.
  static const Duration notificationPollInterval = Duration(seconds: 60);
}
