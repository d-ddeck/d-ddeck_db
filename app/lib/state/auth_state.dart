import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../core/config.dart';
import '../core/token_store.dart';
import '../data/auth_repository.dart';
import '../data/calendar_repository.dart';
import '../models/user.dart';
import '../services/alarm_service.dart';
import '../services/synced_alarm_store.dart';

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
    required this.alarms,
  }) {
    // Fires when a refresh fails or an admin suspends the account mid-session.
    alarms.onStopped = syncAlarms;
    api.onSessionExpired = () => _forceLogout('세션이 만료되었습니다. 다시 로그인해 주세요.');
  }

  final ApiClient api;
  final TokenStore tokenStore;
  final AuthRepository authRepo;
  final CalendarRepository calendarRepo;
  final AlarmService alarms;

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

  /// Whether the last login asked to stay signed in. Used to pre-check the
  /// login screen's box.
  Future<bool> readRememberMe() => tokenStore.readRememberMe();

  Future<void> login(
    String email,
    String password, {
    bool rememberMe = true,
  }) async {
    final session = await authRepo.login(email.trim(), password);
    await tokenStore.saveSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      remember: rememberMe,
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
      (_) {
        refreshUnread();
        syncAlarms();
      },
    );
    refreshUnread();
    syncAlarms();
  }

  int _scheduledAlarms = 0;
  Future<void> _alarmSyncQueue = Future<void>.value();

  /// 예약된 일정 알람 건수. 설정 화면에서 보여준다.
  int get scheduledAlarms => _scheduledAlarms;

  /// 서버의 예약 목록을 받아 기기 알람을 다시 맞춘다.
  ///
  /// 폴링마다 도는 이유는 다른 사람이 내 일정을 바꿨을 수 있기 때문이다.
  /// 통째로 다시 거는 방식이라 삭제된 일정의 알람이 남지 않는다.
  Future<void> syncAlarms() async {
    if (_phase != AuthPhase.ready || !AlarmService.isSupported) return;
    final owner = _user;
    if (owner == null) return;
    // 실패한 요청의 정리가 뒤늦게 성공한 동기화를 지우지 않도록 직렬화한다.
    await (_alarmSyncQueue = _alarmSyncQueue.then((_) => _syncAlarms(owner)));
  }

  Future<void> _syncAlarms(UserProfile owner) async {
    if (_phase != AuthPhase.ready || !identical(owner, _user)) return;
    try {
      final reminders = await calendarRepo.upcomingReminders(days: 7);
      if (_phase != AuthPhase.ready || !identical(owner, _user)) return;
      final count = await alarms.sync(reminders, ownerUserId: owner.id);
      if (_phase != AuthPhase.ready || !identical(owner, _user)) return;
      if (count != _scheduledAlarms) {
        _scheduledAlarms = count;
        notifyListeners();
      }
    } catch (_) {
      if (_phase != AuthPhase.ready || !identical(owner, _user)) return;
      try {
        final snapshot = await SyncedAlarmStore().load();
        if (_phase != AuthPhase.ready || !identical(owner, _user)) return;
        // 같은 사용자의 오프라인 알람은 유지한다. 소유자 없는 구버전
        // 저장본은 다른 계정 여부를 확인할 수 없으므로 함께 정리한다.
        if (snapshot.syncedAt != null && snapshot.ownerUserId != owner.id) {
          await alarms.cancelAll();
          _scheduledAlarms = 0;
          notifyListeners();
        }
      } catch (e) { debugPrint('이전 계정 알람 정리 실패: $e'); }
    }
  }

  void _adopt(UserProfile profile) {
    _user = profile;
    if (profile.mustChangePassword) {
      _pollTimer?.cancel();
      _set(AuthPhase.mustChangePassword);
      return;
    }
    _set(AuthPhase.ready);
    // 알림 권한은 로그인 직후에 묻는다. 앱 첫 실행에 바로 물으면 무엇에
    // 쓰는지 모른 채 거부하기 쉽다.
    if (AlarmService.isSupported) {
      alarms.requestPermissions();
    }
    _startPolling();
  }

  Future<void> _forceLogout(String? message) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _scheduledAlarms = 0;
    // 폰의 예약·저장 목록과 현재 울림은 세션 종료와 무관하게 유지한다.
    _phase = AuthPhase.loggedOut;
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
    alarms.onStopped = null;
    super.dispose();
  }
}
