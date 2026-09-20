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
  static const _kRememberMe = 'remember_me';
  // The site default that was in effect last time we started. Keeping it lets
  // us tell "the user chose this address" apart from "this was just the
  // default", so IT can move the server and have clients follow.
  static const _kAppliedDefault = 'applied_default_url';

  /// Short-lived (60 min) and deliberately memory-only, so it never reaches
  /// disk. A restart rebuilds it from the refresh token.
  String? accessToken;

  /// The current session's refresh token.
  ///
  /// Always held here so a session survives an access-token expiry even when
  /// the user declined "stay signed in"; only written to disk when they did
  /// accept, so declining really does end the session at app close.
  String? _refreshInMemory;

  /// Memory first: right after login it is the freshest value, and when the
  /// user declined to be remembered it is the only copy.
  Future<String?> readRefreshToken() async =>
      _refreshInMemory ?? await _read(_kRefresh);

  Future<String?> readServerUrl() => _read(_kServerUrl);
  Future<String?> readLastEmail() => _read(_kLastEmail);
  Future<String?> readAppliedDefault() => _read(_kAppliedDefault);

  /// Whether the user asked to stay signed in. Defaults to true: the common
  /// case is a personal work device, and the login screen lets them opt out.
  Future<bool> readRememberMe() async =>
      (await _read(_kRememberMe)) != 'false';

  Future<void> saveRememberMe(bool value) =>
      _write(_kRememberMe, value ? 'true' : 'false');

  Future<void> saveAppliedDefault(String url) => _write(_kAppliedDefault, url);

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
    required bool remember,
    String? email,
  }) async {
    this.accessToken = accessToken;
    _refreshInMemory = refreshToken;
    await saveRememberMe(remember);
    if (remember) {
      await _write(_kRefresh, refreshToken);
    } else {
      // A stale token from a previous "remember me" session must not survive
      // a login where the user opted out.
      await _delete(_kRefresh);
    }
    if (email != null) await _write(_kLastEmail, email);
  }

  Future<void> saveServerUrl(String url) => _write(_kServerUrl, url);

  /// Clears credentials but keeps the server address, last email and the
  /// remember-me choice, so the next login screen is pre-filled.
  Future<void> clearSession() async {
    accessToken = null;
    _refreshInMemory = null;
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
