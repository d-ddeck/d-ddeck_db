import 'dart:convert';

import 'package:dio/dio.dart';

/// The server's error envelope, parsed once so the UI never digs through JSON.
///
/// Every failing response looks like:
///   {"error": {"code": "...", "message": "...", "details": ...}}
/// and `message` is already written in Korean for end users.
class ApiException implements Exception {
  ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.details,
  });

  final String code;
  final String message;
  final int? statusCode;
  final dynamic details;

  /// The account cannot be used right now (pending approval, suspended, ...).
  bool get isAccountInactive => code == 'ACCOUNT_NOT_ACTIVE';

  /// Credentials are gone for good; the shell should bounce to the login page.

  /// 서버의 판정을 받지 못한 실패.
  ///
  /// 응답이 없거나(연결 실패·시간 초과), 서버 쪽 장애(5xx)이거나, 오류 봉투가
  /// 아닌 응답(프록시 오류 페이지 등)이라 인증 상태를 알 수 없는 경우다.
  /// 저장된 세션이 살았는지에 대한 정보가 없으므로 세션을 지우는 근거로
  /// 쓰면 안 된다.
  bool get isConnectivityProblem =>
      code == 'NETWORK_ERROR' || statusCode == null || statusCode! >= 500;

  /// Field-level problems from a 422, as {field: message}.
  Map<String, String> get fieldErrors {
    final out = <String, String>{};
    if (code != 'VALIDATION_ERROR' || details is! List) return out;
    for (final item in details as List) {
      if (item is! Map) continue;
      final loc = item['loc'];
      final msg = item['msg'];
      if (loc is List && loc.length > 1 && msg is String) {
        out[loc[1].toString()] = msg;
      }
    }
    return out;
  }

  factory ApiException.fromDio(DioException e) {
    if (e.error is ApiException) return e.error as ApiException;
    final response = e.response;
    dynamic data = response?.data;
    // 엑셀/첨부 다운로드도 오류일 때는 같은 JSON 오류 계약을 사용한다.
    if (data is List<int>) {
      try {
        data = jsonDecode(utf8.decode(data));
      } on FormatException catch (_) {
        // JSON이 아니면 아래의 통신 오류 메시지를 사용한다.
      }
    }

    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      return ApiException(
        code: (err['code'] ?? 'UNKNOWN').toString(),
        message: (err['message'] ?? '알 수 없는 오류가 발생했습니다.').toString(),
        statusCode: response?.statusCode,
        details: err['details'],
      );
    }

    // Transport-level failures never reach the envelope, so translate them
    // into something a user can act on instead of showing a stack trace.
    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => '서버 응답이 없습니다. 네트워크와 서버 주소를 확인해 주세요.',
      DioExceptionType.connectionError =>
        '서버에 연결할 수 없습니다. 서버 주소와 실행 상태를 확인해 주세요.',
      DioExceptionType.badCertificate => '서버 인증서를 확인할 수 없습니다.',
      DioExceptionType.cancel => '요청이 취소되었습니다.',
      _ => '통신 중 오류가 발생했습니다. (${response?.statusCode ?? e.type.name})',
    };
    return ApiException(
      code: 'NETWORK_ERROR',
      message: message,
      statusCode: response?.statusCode,
    );
  }

  @override
  String toString() => 'ApiException($code): $message';
}
