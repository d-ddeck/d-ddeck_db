import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_exception.dart';
import 'config.dart';
import 'token_store.dart';

/// The single HTTP entry point.
///
/// Two behaviours live here so no screen has to repeat them:
///
///  * every request carries the bearer token,
///  * a 401/TOKEN_EXPIRED refreshes once and replays the original request.
///
/// If the refresh itself fails the session is dead, [onSessionExpired] fires,
/// and the shell sends the user back to the login page.
class ApiClient {
  ApiClient({required this.tokenStore}) {
    _dio = Dio(
      BaseOptions(
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.receiveTimeout,
        // We parse the error envelope ourselves, so let every status through
        // to the interceptor instead of having Dio throw on 4xx first.
        validateStatus: (status) => status != null && status < 500,
        headers: {'Content-Type': 'application/json'},
      ),
    );
    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onResponse: _onResponse),
    );
  }

  final TokenStore tokenStore;
  late final Dio _dio;

  String _serverUrl = AppConfig.defaultServerUrl;
  String get serverUrl => _serverUrl;

  /// Called when the session cannot be recovered. Set by the auth state.
  void Function()? onSessionExpired;

  // A single in-flight refresh shared by every request that hits a 401 at the
  // same time. Without this, ten parallel calls would fire ten refreshes and
  // nine of them would race.
  Future<bool>? _refreshInFlight;

  Future<void> setServerUrl(String raw, {bool persist = true}) async {
    _serverUrl = AppConfig.normalizeServerUrl(raw);
    if (persist) await tokenStore.saveServerUrl(_serverUrl);
  }

  /// Decides which server address this launch uses.
  ///
  /// Precedence: the user's own choice wins, except when IT has changed the
  /// site default since we last started - then the new default is adopted.
  /// Without that exception, moving the server would strand every client that
  /// had ever opened the login screen's server field.
  Future<void> restoreServerUrl() async {
    final siteDefault = AppConfig.defaultServerUrl;
    final appliedDefault = await tokenStore.readAppliedDefault();
    final saved = await tokenStore.readServerUrl();

    if (appliedDefault != siteDefault) {
      // First run, or the installer/config file now points somewhere else.
      _serverUrl = siteDefault;
      await tokenStore.saveAppliedDefault(siteDefault);
      await tokenStore.saveServerUrl(siteDefault);
      return;
    }
    if (saved != null && saved.isNotEmpty) {
      _serverUrl = AppConfig.normalizeServerUrl(saved);
    }
  }

  String _url(String path) => '$_serverUrl${AppConfig.apiPrefix}$path';

  void _onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = tokenStore.accessToken;
    if (token != null && options.extra['skipAuth'] != true) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  Future<void> _onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    final status = response.statusCode ?? 0;
    if (status < 400) {
      handler.next(response);
      return;
    }

    final options = response.requestOptions;
    final code = _errorCode(response.data);
    final canRetry = status == 401 &&
        options.extra['skipAuth'] != true &&
        options.extra['isRetry'] != true &&
        code != 'INVALID_CREDENTIALS';

    if (canRetry && await _refreshToken()) {
      try {
        final retried = await _dio.fetch(
          options..extra = {...options.extra, 'isRetry': true},
        );
        handler.resolve(retried);
        return;
      } catch (_) {
        // fall through to the normal error path
      }
    }

    // 403 ACCOUNT_NOT_ACTIVE means an admin suspended the account mid-session;
    // refreshing would not help, so end the session immediately.
    if (status == 403 && code == 'ACCOUNT_NOT_ACTIVE') {
      _endSession();
    }

    handler.reject(
      DioException(
        requestOptions: options,
        response: response,
        type: DioExceptionType.badResponse,
      ),
    );
  }

  static String? _errorCode(dynamic data) {
    if (data is Map && data['error'] is Map) {
      return (data['error'] as Map)['code']?.toString();
    }
    return null;
  }

  Future<bool> _refreshToken() {
    return _refreshInFlight ??= _doRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<bool> _doRefresh() async {
    final refresh = await tokenStore.readRefreshToken();
    if (refresh == null || refresh.isEmpty) {
      _endSession();
      return false;
    }
    try {
      final res = await _dio.post(
        _url('/auth/refresh'),
        data: {'refresh_token': refresh},
        options: Options(extra: {'skipAuth': true, 'isRetry': true}),
      );
      if (res.statusCode == 200 && res.data is Map) {
        tokenStore.accessToken = res.data['access_token'] as String?;
        return tokenStore.accessToken != null;
      }
    } catch (e) {
      debugPrint('token refresh failed: $e');
      // 연결 실패는 세션 거부가 아니다. 폰의 오프라인 알람도 유지한다.
      if (e is DioException && (e.response == null ||
          (e.response?.statusCode ?? 0) >= 500)) {
        return false;
      }
    }
    _endSession();
    return false;
  }

  void _endSession() {
    tokenStore.accessToken = null;
    tokenStore.clearSession();
    onSessionExpired?.call();
  }

  // ---------------------------------------------------------------- verbs
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) =>
      _send(() => _dio.get(
            _url(path),
            queryParameters: _clean(query),
            options: Options(extra: {'skipAuth': skipAuth}),
          ));

  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool skipAuth = false,
  }) =>
      _send(() => _dio.post(
            _url(path),
            data: body,
            queryParameters: _clean(query),
            options: Options(extra: {'skipAuth': skipAuth}),
          ));

  Future<dynamic> patch(String path, {Object? body}) =>
      _send(() => _dio.patch(_url(path), data: body));

  Future<dynamic> put(String path, {Object? body}) =>
      _send(() => _dio.put(_url(path), data: body));

  Future<dynamic> delete(String path) => _send(() => _dio.delete(_url(path)));

  /// 멀티파트 업로드.
  ///
  /// post() 와 나눠 둔 이유는 진행률 콜백 때문이다. 사진 여러 장이면 몇 초씩
  /// 걸려서, 화면이 "얼마나 갔는지"를 보여 줄 수 있어야 한다.
  Future<dynamic> postMultipart(
    String path,
    FormData form, {
    void Function(int sent, int total)? onProgress,
  }) =>
      _send(() => _dio.post(
            _url(path),
            data: form,
            onSendProgress: onProgress,
          ));

  /// 첨부 내려받기. JSON 이 아니라 원본 바이트를 그대로 받는다.
  Future<List<int>> getBytes(String path) async {
    try {
      final res = await _dio.get<List<int>>(
        _url(path),
        options: Options(responseType: ResponseType.bytes),
      );
      return res.data ?? const [];
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> _send(Future<Response> Function() call) async {
    try {
      final res = await call();
      return res.data;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Drops nulls and serialises values the way the API expects.
  ///
  /// DateTime is the important one: the server wants UTC ISO-8601, and Dio
  /// percent-encodes it, which is what keeps the `+00:00` offset from being
  /// read as a space and rejected with a 422.
  static Map<String, dynamic>? _clean(Map<String, dynamic>? query) {
    if (query == null) return null;
    final out = <String, dynamic>{};
    query.forEach((key, value) {
      if (value == null) return;
      if (value is DateTime) {
        out[key] = value.toUtc().toIso8601String();
      } else if (value is Enum) {
        out[key] = value.name;
      } else {
        out[key] = value;
      }
    });
    return out.isEmpty ? null : out;
  }

  /// Unauthenticated probe used by the login screen's "서버 연결 확인" button.
  Future<bool> ping() async {
    try {
      final res = await _dio.get(
        '$_serverUrl/healthz',
        options: Options(extra: {'skipAuth': true}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
