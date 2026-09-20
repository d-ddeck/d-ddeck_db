import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistent credentials and the server address.
///
/// Backed by the OS keystore (DPAPI / Keystore / libsecret) rather than
/// SharedPreferences: the refresh token is valid for 14 days and would
/// otherwise sit in plain text on a shared office PC.
class TokenStore {
  TokenStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const _kRefresh = 'refresh_token';
  static const _kServerUrl = 'server_url';
  static const _kLastEmail = 'last_email';

  /// Short-lived (60 min) and deliberately memory-only, so it never reaches
  /// disk. A restart rebuilds it from the refresh token.
  String? accessToken;

  Future<String?> readRefreshToken() => _read(_kRefresh);
  Future<String?> readServerUrl() => _read(_kServerUrl);
  Future<String?> readLastEmail() => _read(_kLastEmail);

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
    String? email,
  }) async {
    this.accessToken = accessToken;
    await _write(_kRefresh, refreshToken);
    if (email != null) await _write(_kLastEmail, email);
  }

  Future<void> saveServerUrl(String url) => _write(_kServerUrl, url);

  /// Clears credentials but keeps the server address and last email, so the
  /// next login screen is pre-filled instead of blank.
  Future<void> clearSession() async {
    accessToken = null;
    await _delete(_kRefresh);
  }

  // Secure storage can throw on a locked keyring or a misconfigured Linux
  // session. Credentials are recoverable by logging in again, so degrade to
  // "not stored" instead of crashing the app on startup.
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      /* keep running; the session just will not survive a restart */
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      /* nothing to recover from */
    }
  }
}
