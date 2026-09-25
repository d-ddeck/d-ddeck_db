import '../core/api_client.dart';

/// 인증이 필요 없는 /healthz를 확인한다. 세션 갱신을 시도하지 않는다.
Future<bool> canReachServer(ApiClient api) async {
  try {
    return await api.ping().timeout(const Duration(seconds: 3));
  } catch (_) {
    return false;
  }
}
