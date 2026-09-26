# 클라이언트 개발 계약

현재 클라이언트는 `app/`의 Flutter 코드입니다. Windows와 Android를 배포하며 Ubuntu는 서버 역할입니다.

- 기준 스키마: [openapi.json](openapi.json). 개발 서버 `DEBUG=true`에서 `/docs`를 볼 수 있습니다.
- API 경로: `/api/v1`. 로그인 후 Bearer access token을 사용합니다.
- `ApiClient`가 refresh 회전·서버 오류·세션 종료를 처리합니다. 갱신된 refresh token을 반드시 저장하며 일시적인 통신 장애는 로그아웃으로 바꾸지 않습니다.
- `AuthState`가 로그인·승인·비밀번호 변경·기기 등록을 관리합니다. 알 수 없는 상태 값은 `unknown`으로 표시합니다.
- 조회 화면은 `AsyncView` 또는 `guardedLoad`, 변경 작업은 `runGuarded`를 사용합니다. 서버 오류를 성공 메시지로 덮지 않습니다.
- 입력 화면은 `DirtyFormScope`로 변경을 보호합니다. 저장 후 첨부 기능은 이미 저장된 ID를 사용하므로 업로드 실패 때문에 본문을 중복 생성하지 않습니다.
- 이미지 업로드는 지원되는 정지 사진의 긴 변을 1600px로 줄입니다. 원본의 애니메이션·미지원 형식은 보존합니다.
- 공통 목록 응답은 `{items,total,page,size,pages}`입니다. 모든 건을 읽어야 하는 선택 목록은 페이지를 끝까지 읽습니다.
- 날짜는 서버 UTC → 기기 시간으로 표시합니다. 날짜만 나타내는 휴일·설치일에는 시간대 변환을 적용하지 않습니다.
- 통계 숫자는 대응 건수와 원인 건수를 구분합니다. `missing` 필터는 미분류 버킷의 목록 연결에 사용합니다.

서명·Firebase·HTTPS·백업 준비는 [운영 문서](OPERATIONS.md), [Android 서명 안내](ANDROID_SIGNING.md)를 따릅니다. 서비스 계정 개인키와 Android 서명 비밀번호를 앱 소스나 dart-define에 넣지 않습니다.
