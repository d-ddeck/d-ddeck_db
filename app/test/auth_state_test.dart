import 'package:ddeck_app/core/api_client.dart';
import 'package:ddeck_app/core/api_exception.dart';
import 'package:ddeck_app/core/token_store.dart';
import 'package:ddeck_app/data/auth_repository.dart';
import 'package:ddeck_app/data/calendar_repository.dart';
import 'package:ddeck_app/models/user.dart';
import 'package:ddeck_app/services/alarm_service.dart';
import 'package:ddeck_app/state/auth_state.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 앱 시작 시 자동 로그인(AuthState.bootstrap) 의 세션 보존 규칙.
///
/// 실제 HTTP 대신 AuthRepository 를 흉내 내어 /auth/me 가 어떤 오류로 끝났는지만
/// 정한다. ApiClient 는 진짜를 쓰되(요청은 보내지 않는다) 세션 종료 콜백
/// onSessionExpired 만 가짜 저장소가 대신 눌러 준다.
void main() {
  late Map<String, String> disk;
  late TokenStore store;
  late ApiClient api;
  late _FakeAuthRepository authRepo;
  late AuthState state;

  UserProfile profile({bool mustChangePassword = false}) =>
      UserProfile.fromJson({
        'id': 'u-1',
        'email': 'a@b.co',
        'full_name': '홍길동',
        'role': 'MEMBER',
        'status': 'ACTIVE',
        'must_change_password': mustChangePassword,
      });

  ApiException error(String code, {int? status}) =>
      ApiException(code: code, message: code, statusCode: status);

  setUp(() {
    disk = {'refresh_token': 'R-saved'};
    store = TokenStore(_FakeSecureStorage(disk));
    api = ApiClient(tokenStore: store);
    authRepo = _FakeAuthRepository();
    state = AuthState(
      api: api,
      tokenStore: store,
      authRepo: authRepo,
      calendarRepo: _FakeCalendarRepository(),
      alarms: _FakeAlarmService(),
    );
  });

  tearDown(() => state.dispose());

  /// _forceLogout 은 콜백에서 await 없이 시작되므로 뒤처리가 끝나길 기다린다.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('AuthState.bootstrap – 서버에 닿지 못한 경우', () {
    test('연결 실패(NETWORK_ERROR)면 토큰을 남기고 안내 문구를 띄운다', () async {
      authRepo.onMe = () => throw error('NETWORK_ERROR');

      await state.bootstrap();

      expect(state.phase, AuthPhase.loggedOut);
      expect(state.notice, AuthState.connectivityNotice);
      expect(
        disk['refresh_token'],
        'R-saved',
        reason: '다음 실행 때 자동 로그인을 다시 시도할 수 있어야 한다',
      );
      expect(await store.readRefreshToken(), 'R-saved');
    });

    test('프록시 오류 페이지(봉투 아닌 404) 도 연결 문제로 본다', () async {
      authRepo.onMe = () => throw error('NETWORK_ERROR', status: 404);

      await state.bootstrap();

      expect(state.phase, AuthPhase.loggedOut);
      expect(disk['refresh_token'], 'R-saved');
    });

    test('서버 점검(5xx)이면 세션을 지우지 않는다', () async {
      authRepo.onMe = () => throw error('INTERNAL_ERROR', status: 502);

      await state.bootstrap();

      expect(state.phase, AuthPhase.loggedOut);
      expect(state.notice, AuthState.connectivityNotice);
      expect(disk['refresh_token'], 'R-saved');
    });

    test('리프레시 요청만 실패해 되돌아온 401 은 거부가 아니다', () async {
      // ApiClient._doRefresh 가 5xx·연결 실패로 false 를 돌려주면 원래 401 이
      // 그대로 reject 되지만 onSessionExpired 는 불리지 않는다. 그 신호가
      // 없으면 세션 유효성을 모른다는 뜻이므로 토큰을 남긴다.
      authRepo.onMe = () => throw error('NOT_AUTHENTICATED', status: 401);

      await state.bootstrap();

      expect(state.phase, AuthPhase.loggedOut);
      expect(state.notice, AuthState.connectivityNotice);
      expect(disk['refresh_token'], 'R-saved');
    });

    test('연결 실패 뒤 다시 로그인하면 정상 동작한다', () async {
      authRepo.onMe = () => throw error('NETWORK_ERROR');
      await state.bootstrap();
      expect(state.phase, AuthPhase.loggedOut);

      authRepo.onLogin = () async => AuthSession(
        accessToken: 'A-new',
        refreshToken: 'R-new',
        user: profile(),
      );
      await state.login('a@b.co', 'pw', rememberMe: true);

      expect(state.phase, AuthPhase.ready);
      expect(state.user?.id, 'u-1');
      expect(store.accessToken, 'A-new');
      expect(disk['refresh_token'], 'R-new');
    });
  });

  group('AuthState.bootstrap – 서버가 세션을 거부한 경우', () {
    test('리프레시 토큰이 거부되면(onSessionExpired) 세션을 지운다', () async {
      authRepo.onMe = () {
        // 실제 ApiClient 는 리프레시가 401 로 끝나면 _endSession 으로
        // onSessionExpired 를 부른 뒤 원래 401 을 reject 한다.
        api.onSessionExpired?.call();
        throw error('NOT_AUTHENTICATED', status: 401);
      };

      await state.bootstrap();
      await settle();

      expect(state.phase, AuthPhase.loggedOut);
      expect(disk.containsKey('refresh_token'), isFalse);
      expect(await store.readRefreshToken(), isNull);
      expect(state.notice, '세션이 만료되었습니다. 다시 로그인해 주세요.');
    });

    test('계정 정지(403 ACCOUNT_NOT_ACTIVE) 도 세션을 지운다', () async {
      authRepo.onMe = () {
        api.onSessionExpired?.call();
        throw error('ACCOUNT_NOT_ACTIVE', status: 403);
      };

      await state.bootstrap();
      await settle();

      expect(state.phase, AuthPhase.loggedOut);
      expect(disk.containsKey('refresh_token'), isFalse);
    });

    test('그 외 4xx 판정(403·404 봉투)은 지금처럼 세션을 지운다', () async {
      authRepo.onMe = () => throw error('FORBIDDEN', status: 403);

      await state.bootstrap();

      expect(state.phase, AuthPhase.loggedOut);
      expect(disk.containsKey('refresh_token'), isFalse);
      expect(state.notice, isNull);
    });
  });

  group('AuthState.bootstrap – 정상 경로', () {
    test('저장된 토큰이 없으면 서버에 묻지 않고 로그인 화면으로', () async {
      disk.clear();
      var asked = 0;
      authRepo.onMe = () async {
        asked++;
        return profile();
      };

      await state.bootstrap();

      expect(state.phase, AuthPhase.loggedOut);
      expect(asked, 0);
      expect(state.notice, isNull);
    });

    test('세션이 살아 있으면 프로필을 채택한다', () async {
      authRepo.onMe = () async => profile();

      await state.bootstrap();

      expect(state.phase, AuthPhase.ready);
      expect(state.user?.email, 'a@b.co');
      expect(disk['refresh_token'], 'R-saved');
    });

    test('비밀번호 변경이 필요하면 그 단계로 보낸다', () async {
      authRepo.onMe = () async => profile(mustChangePassword: true);

      await state.bootstrap();

      expect(state.phase, AuthPhase.mustChangePassword);
    });
  });

  group('ApiException.isConnectivityProblem', () {
    test('응답 없음·5xx·봉투 아닌 응답은 연결 문제', () {
      expect(error('NETWORK_ERROR').isConnectivityProblem, isTrue);
      expect(error('NETWORK_ERROR', status: 404).isConnectivityProblem, isTrue);
      expect(
        error('INTERNAL_ERROR', status: 500).isConnectivityProblem,
        isTrue,
      );
      expect(error('BAD_GATEWAY', status: 503).isConnectivityProblem, isTrue);
    });

    test('서버가 내린 4xx 판정은 연결 문제가 아니다', () {
      expect(
        error('NOT_AUTHENTICATED', status: 401).isConnectivityProblem,
        isFalse,
      );
      expect(
        error('ACCOUNT_NOT_ACTIVE', status: 403).isConnectivityProblem,
        isFalse,
      );
      expect(error('NOT_FOUND', status: 404).isConnectivityProblem, isFalse);
      expect(
        error('VALIDATION_ERROR', status: 422).isConnectivityProblem,
        isFalse,
      );
    });
  });
}

// ------------------------------------------------------------------ fakes

class _FakeAuthRepository implements AuthRepository {
  Future<UserProfile> Function()? onMe;
  Future<AuthSession> Function()? onLogin;

  @override
  Future<UserProfile> me() => onMe!();

  @override
  Future<AuthSession> login(String email, String password) => onLogin!();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 로그인 직후 알림 배지 폴링이 한 번 돌기 때문에 unreadCount 만 구현한다.
class _FakeCalendarRepository implements CalendarRepository {
  @override
  Future<int> unreadCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 데스크톱 테스트에서는 AlarmService.isSupported 가 false 라 아무것도 불리지
/// 않는다. onStopped 대입만 받아 준다.
class _FakeAlarmService implements AlarmService {
  @override
  Future<void> Function()? onStopped;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// widget_test.dart 의 것과 같은 메모리 저장소. 실제 구현은 플랫폼 채널이
/// 필요해 테스트에서 동작하지 않는다.
class _FakeSecureStorage implements FlutterSecureStorage {
  _FakeSecureStorage(this.data);
  final Map<String, String> data;

  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    data.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
