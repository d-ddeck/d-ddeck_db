import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../models/common.dart';
import '../models/user.dart';

class AuthRepository {
  AuthRepository(this._api);
  final ApiClient _api;

  /// Step 1 of the entry flow. Creates a PENDING account; no session yet.
  Future<String> signup({
    required String email,
    required String password,
    required String fullName,
    String? employeeNo,
    String? phone,
    String? position,
    String? signupNote,
  }) async {
    final res = await _api.post(
      '/auth/signup',
      skipAuth: true,
      body: {
        'email': email,
        'password': password,
        'full_name': fullName,
        if (employeeNo?.isNotEmpty == true) 'employee_no': employeeNo,
        if (phone?.isNotEmpty == true) 'phone': phone,
        if (position?.isNotEmpty == true) 'position': position,
        if (signupNote?.isNotEmpty == true) 'signup_note': signupNote,
      },
    );
    return asString(asMap(res)['message'], '가입 신청이 접수되었습니다.');
  }

  Future<AuthSession> login(String email, String password) async {
    final res = await _api.post(
      '/auth/login',
      skipAuth: true,
      body: {
        'email': email,
        'password': password,
        'device_name': _deviceName(),
        'platform': _platform(),
      },
    );
    return AuthSession.fromJson(asMap(res));
  }

  Future<void> logout(String refreshToken) =>
      _api.post('/auth/logout', body: {'refresh_token': refreshToken});

  Future<UserProfile> me() async =>
      UserProfile.fromJson(asMap(await _api.get('/auth/me')));

  Future<UserProfile> updateMe({
    String? fullName,
    String? phone,
    String? position,
  }) async {
    final res = await _api.patch('/auth/me', body: {
      if (fullName != null) 'full_name': fullName,
      if (phone != null) 'phone': phone,
      if (position != null) 'position': position,
    });
    return UserProfile.fromJson(asMap(res));
  }

  /// Changing the password revokes every session, so the caller must send the
  /// user back to the login screen afterwards.
  Future<String> changePassword(String current, String next) async {
    final res = await _api.post('/auth/change-password', body: {
      'current_password': current,
      'new_password': next,
    });
    return asString(asMap(res)['message'], '비밀번호가 변경되었습니다.');
  }

  // --------------------------------------------------------------- admin
  Future<PagedList<UserProfile>> pendingUsers({int page = 1, int size = 20}) async {
    final res = await _api.get('/users/pending', query: {'page': page, 'size': size});
    return PagedList.fromJson(res, UserProfile.fromJson);
  }

  Future<PagedList<UserProfile>> listUsers({
    int page = 1,
    int size = 20,
    String? status,
    String? query,
  }) async {
    final res = await _api.get('/users', query: {
      'page': page,
      'size': size,
      'status': status,
      'q': query,
    });
    return PagedList.fromJson(res, UserProfile.fromJson);
  }

  Future<void> deleteUser(String id) => _api.delete('/users/$id');

  Future<UserProfile> updateUser(String id, Map<String, dynamic> changes) async {
    final res = await _api.patch('/users/$id', body: changes);
    return UserProfile.fromJson(asMap(res));
  }

  Future<UserProfile> approve(String userId, Role role,
      {String? departmentId}) async {
    final res = await _api.post('/users/$userId/approve', body: {
      'role': role.value,
      if (departmentId != null) 'department_id': departmentId,
    });
    return UserProfile.fromJson(asMap(res));
  }

  Future<UserProfile> reject(String userId, String reason) async {
    final res =
        await _api.post('/users/$userId/reject', body: {'reason': reason});
    return UserProfile.fromJson(asMap(res));
  }

  /// The member picker behind assignee and participant fields.
  Future<PagedList<UserBrief>> directory({String? query, int size = 50}) async {
    final res = await _api
        .get('/users/directory', query: {'q': query, 'size': size, 'page': 1});
    return PagedList.fromJson(res, UserBrief.fromJson);
  }

  Future<List<Department>> departments() async {
    final res = await _api.get('/admin/departments');
    return (res as List? ?? [])
        .map((e) => Department.fromJson(asMap(e)))
        .toList();
  }

  // ------------------------------------------------------------- devices
  /// Registers this install for push. The server stores the token now and
  /// starts using it once FCM is wired up on the backend.
  Future<void> registerDevice(String pushToken) => _api.post(
        '/auth/devices',
        body: {
          'platform': _platform(),
          'push_token': pushToken,
          'device_name': _deviceName(),
        },
      );

  static String _platform() {
    if (kIsWeb) return 'WEB';
    if (Platform.isAndroid) return 'ANDROID';
    if (Platform.isWindows) return 'WINDOWS';
    if (Platform.isLinux) return 'LINUX';
    if (Platform.isIOS) return 'IOS';
    return 'WEB';
  }

  static String _deviceName() {
    if (kIsWeb) return 'Web';
    try {
      return Platform.localHostname;
    } catch (_) {
      return _platform();
    }
  }
}
