import 'dart:convert';
import 'dart:io' show File, Platform;

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

  /// Site default written next to the executable by the installer.
  /// Loaded once at startup by [loadSiteConfig].
  static String? _siteUrl;

  /// The address IT configured for this machine, if any.
  static String? get siteServerUrl => _siteUrl;

  /// Reads `ddeck.config.json` from the executable's folder.
  ///
  /// This is what lets one build serve a company whose server address is not
  /// known at compile time: the installer asks once and writes the file, and
  /// moving the server later means editing that file rather than rebuilding.
  ///
  /// Never throws - a missing or malformed file just means "no site default".
  ///
  /// [directory] exists so tests can point at a temp folder; in the app it is
  /// always the folder holding the executable.
  static Future<void> loadSiteConfig({String? directory}) async {
    if (kIsWeb) return;
    try {
      final dirPath =
          directory ?? File(Platform.resolvedExecutable).parent.path;
      final file = File('$dirPath${Platform.pathSeparator}$siteConfigFileName');
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      final url = data['server_url'];
      if (url is String && url.trim().isNotEmpty) {
        _siteUrl = normalizeServerUrl(url);
        debugPrint('site config loaded');
      }
    } catch (e) {
      debugPrint('site config not loaded: $e');
    }
  }

  static const String siteConfigFileName = 'ddeck.config.json';

  @visibleForTesting
  static void resetSiteConfig() => _siteUrl = null;

  static String get defaultServerUrl {
    if (_siteUrl != null) return _siteUrl!;
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

  /// Only the local server PC may use HTTP; remote credentials require TLS.
  static String secureServerUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                const ['127.0.0.1', '::1'].contains(uri.host)))) {
      throw const FormatException('HTTPS 연결 설정이 필요합니다. 관리자에게 문의하세요.');
    }
    return uri.replace(path: '').toString();
  }

  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration receiveTimeout = Duration(seconds: 30);

  /// How often the shell re-checks the unread notification count.
  /// Push is not wired up on the server yet, so the client polls.
  static const Duration notificationPollInterval = Duration(seconds: 60);
}
