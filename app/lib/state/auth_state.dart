import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../core/config.dart';
import '../core/token_store.dart';
import '../data/auth_repository.dart';
import '../data/calendar_repository.dart';
import '../models/user.dart';

/// Where the app is in the entry flow. The root widget switches on this.
enum AuthPhase {
  /// Restoring a saved session at startup.
  loading,

  /// No usable session - show login / signup.
  loggedOut,

  /// Signed in but the server demands a password change first.
  mustChangePassword,

  /// Fully signed in.
  ready,
}

class AuthState extends ChangeNotifier {
  AuthState({
    required this.api,
    required this.tokenStore,
    required this.authRepo,
    required this.calendarRepo,
  }) {
    // Fires when a refresh fails or an admin suspends the account mid-session.
    api.onSessionExpired = () => _forceLogout('세션이 만료되었습니다. 다시 로그인해 주세요.');
  }

  final ApiClient api;
  final TokenStore tokenStore;
  final AuthRepository authRepo;
  final CalendarRepository calendarRepo;

  AuthPhase _phase = AuthPhase.loading;
  UserProfile? _user;
  String? _notice;
  int _unread = 0;
  Timer? _pollTimer;

  AuthPhase get phase => _phase;
  UserProfile? get user => _user;
  String? get notice => _notice;
  int get unreadCount => _unread;
  String get serverUrl => api.serverUrl;

  Role get role => _user?.role ?? Role.member;
  bool get isAdmin => role.atLeast(Role.admin);
  bool get isManager => role.atLeast(Role.manager);

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// Restores the saved server address and, if a refresh token survived,
  /// silently signs back in. Runs once at startup.
  Future<void> bootstrap() async {
    await api.restoreServerUrl();
    final refresh = await tokenStore.readRefreshToken();
    if (refresh == null || refresh.isEmpty) {
      _set(AuthPhase.loggedOut);
      return;
    }
    try {
      // Any authenticated call triggers the refresh interceptor, so /auth/me
      // doubles as "is this saved session still good?".
      final profile = await authRepo.me();
      _adopt(profile);
    } on ApiException {
      await tokenStore.clearSession();
      _set(AuthPhase.loggedOut);
    }
  }

  Future<void> setServerUrl(String url) async {
    await api.setServerUrl(url);
    notifyListeners();
  }

  Future<bool> pingServer() => api.ping();

  Future<void> login(String email, String password) async {
    final session = await authRepo.login(email.trim(), password);
    await tokenStore.saveSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      email: email.trim(),
    );
    _adopt(session.user);
  }

  Future<String> signup({
    required String email,
    required String password,
    required String fullName,
    String? phone,
    String? position,
    String? employeeNo,
    String? signupNote,
  }) =>
      authRepo.signup(
        email: email.trim(),
        password: password,
        fullName: fullName.trim(),
        phone: phone,
        position: position,
        employeeNo: employeeNo,
        signupNote: signupNote,
      );

  Future<void> changePassword(String current, String next) async {
    await authRepo.changePassword(current, next);
    // The server revokes every session on a password change, so there is no
    // valid token left to keep using - go back to login deliberately.
    await _forceLogout('비밀번호가 변경되었습니다. 새 비밀번호로 다시 로그인해 주세요.');
  }

  Future<void> logout() async {
    final refresh = await tokenStore.readRefreshToken();
    if (refresh != null) {
      try {
        await authRepo.logout(refresh);
      } on ApiException {
        // Already invalid server-side; clearing locally is what matters.
      }
    }
    await _forceLogout(null);
  }

  Future<void> refreshProfile() async {
    try {
      _adopt(await authRepo.me());
    } on ApiException {
      /* the interceptor handles a dead session */
    }
  }

  // ------------------------------------------------------- notifications
  /// Push is not wired up on the server yet, so the badge polls.
  Future<void> refreshUnread() async {
    if (_phase != AuthPhase.ready) return;
    try {
      final count = await calendarRepo.unreadCount();
      if (count != _unread) {
        _unread = count;
        notifyListeners();
      }
    } on ApiException {
      /* a failed badge refresh is not worth surfacing */
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      AppConfig.notificationPollInterval,
      (_) => refreshUnread(),
    );
    refreshUnread();
  }

  void _adopt(UserProfile profile) {
    _user = profile;
    if (profile.mustChangePassword) {
      _pollTimer?.cancel();
      _set(AuthPhase.mustChangePassword);
      return;
    }
    _set(AuthPhase.ready);
    _startPolling();
  }

  Future<void> _forceLogout(String? message) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await tokenStore.clearSession();
    _user = null;
    _unread = 0;
    _notice = message;
    _set(AuthPhase.loggedOut);
  }

  void _set(AuthPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
