# d-ddeck 클라이언트 (Flutter)

사내 통합 DB 서버의 크로스 플랫폼 클라이언트. Windows · Linux · Android에서
같은 코드로 동작하며, 백엔드([../backend](../backend))의 REST API를 사용합니다.

```
회원가입  →  관리자 승인  →  로그인  →  5개 모듈 이용
```

---

## 빌드 환경

| 항목 | 상태 |
|---|---|
| Flutter | 3.35.7 (stable) |
| Windows 데스크톱 | Visual Studio 2022 필요 + **개발자 모드 필수** (아래 참고) |
| Android | SDK 36 + cmdline-tools. 릴리스 APK 18.1MB (arm64) 빌드 확인 |
| Linux (Ubuntu) | Ubuntu 실기 또는 WSL2 필요 (Windows에서 크로스 컴파일 불가) |

### Windows: 개발자 모드가 필요한 이유

`flutter_secure_storage`가 네이티브 플러그인이고, Flutter는 Windows에서
플러그인을 심볼릭 링크로 연결합니다. 심볼릭 링크 생성에는 개발자 모드가
필요하므로 **켜지 않으면 `flutter build windows`가 실패합니다.**

```powershell
# 관리자 PowerShell
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
  -Name AllowDevelopmentWithoutDevLicense -PropertyType DWord -Value 1 -Force

# 또는 GUI
start ms-settings:developers
```

### Linux 추가 의존성

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
```

`libsecret-1-dev`는 `flutter_secure_storage`가 토큰을 키링에 저장하는 데 쓰입니다.

### `flutter doctor`의 Android 라이선스 경고

Flutter 3.35.7은 라이선스 확인에 폐기된 `sdkmanager --licenses`를 호출하는데,
최신 cmdline-tools(23.0.0)가 이를 제거해 **경고가 사라지지 않습니다.**
Gradle이 빌드 중 필요한 라이선스를 자동 수락하므로 **실제 빌드에는 영향이
없습니다** (릴리스 APK 빌드로 확인). 경고를 없애려면 구버전 cmdline-tools를
`cmdline-tools/latest`에 두면 됩니다.

---

## 실행

```bash
cd app
flutter pub get

# 백엔드가 먼저 떠 있어야 합니다
#   cd ../backend && uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

flutter run -d windows     # 또는 -d linux, -d <android-device-id>
```

### 서버 주소

기본값은 플랫폼별로 다릅니다.

| 플랫폼 | 기본 서버 주소 |
|---|---|
| Windows / Linux | `http://127.0.0.1:8000` |
| Android 에뮬레이터 | `http://10.0.2.2:8000` |
| Android 실기기 | PC의 LAN IP로 **직접 입력 필요** |

로그인 화면의 **"서버 주소 설정"** 에서 바꿀 수 있고, 입력값은 보안 저장소에
남아 다음 실행에도 유지됩니다. 빌드 시 고정하려면:

```bash
flutter build windows --release --dart-define=SERVER_URL=http://192.168.0.10:8000
```

### 데모 계정

`backend/scripts/seed_demo.py` 실행 시 사용할 수 있습니다.

| 계정 | 권한 | 비밀번호 |
|---|---|---|
| `seojun.kim@ddeck.local` | ADMIN | `demo1234` |
| `hayun.lee@ddeck.local` | MANAGER | `demo1234` |
| `dohyun.park@ddeck.local` | MEMBER | `demo1234` |
| `admin@ddeck.local` | SUPERADMIN | `admin1234` |

---

## 빌드

```bash
flutter build apk --release --target-platform android-arm64   # 18.1MB
flutter build appbundle --release                              # Play 스토어용
flutter build windows --release                                # 개발자 모드 필요
flutter build linux --release                                  # Ubuntu에서
```

산출물: `build/app/outputs/flutter-apk/`, `build/windows/x64/runner/Release/`,
`build/linux/x64/release/bundle/`

## 검증

```bash
flutter analyze   # 경고 0건
flutter test      # 13건 통과
```

---

## 구조

```
lib/
  core/          config · api_client · token_store · api_exception
  models/        서버 응답 → Dart 모델 (수작업 fromJson, codegen 불필요)
  data/          모듈별 리포지토리 (API 호출은 전부 여기로)
  state/         AuthState (ChangeNotifier)
  ui/
    auth/        로그인 · 가입 · 비밀번호 변경
    service/     AS 목록 · 상세 · 접수 폼 · 자동 통계(차트)
    inventory/   자산 · 위치 트리 · 이동 이력 · 현황
    board/       게시판 · 글 · 댓글
    calendar/    월 달력 · 일정 등록 · 참석 응답
    admin/       승인 대기열 · 기능 설정 · 감사로그 · 서버 상태
    shell.dart   네비게이션 (데스크톱 rail / 모바일 bottom bar)
    theme.dart   테마 + 공용 위젯(StatusChip, StatTile, StatePlaceholder)
    async_view.dart  로딩/에러/빈 상태 공통 래퍼
```

### 설계 메모

**토큰 처리는 인터셉터 한 곳에.** `ApiClient`가 모든 요청에 Bearer 토큰을 붙이고,
401을 받으면 리프레시 후 원래 요청을 1회 재시도합니다. 동시에 여러 요청이 401을
받아도 리프레시는 한 번만 실행됩니다(`_refreshInFlight`). 리프레시까지 실패하면
`AuthState`가 로그인 화면으로 되돌립니다.

**액세스 토큰은 메모리에만** 둡니다. 디스크에 남는 것은 리프레시 토큰뿐이고,
그마저 OS 키스토어(DPAPI / Keystore / libsecret)에 저장합니다.

**분류 항목을 하드코딩하지 않습니다.** AS 접수 폼의 분류·증상 드롭다운, 자산 분류,
일정 유형은 전부 `/admin/codes/...`에서 받아옵니다. 관리자가 설정 화면에서 항목을
추가하면 앱 재배포 없이 폼에 나타납니다.

**통계의 라벨과 색상은 서버 값을 그대로 씁니다.** 클라이언트에 한글 매핑표나 차트
팔레트를 두지 않으므로, 분류 코드의 색을 바꾸면 차트·칩·목록이 한꺼번에 따라옵니다.

**반응형은 플랫폼이 아니라 너비로 판단합니다**(`AppTheme.wideBreakpoint = 900`).
Windows 창을 좁히면 모바일 레이아웃이 되고, 안드로이드 태블릿 가로 모드는 데스크톱과
같은 2단 레이아웃을 받습니다.

**Decimal은 문자열로 옵니다.** 서버가 금액·수량을 `"150000.00"`으로 직렬화하므로
`asDouble()`로 파싱합니다. 테스트에 이 케이스가 들어 있습니다.

**날짜 쿼리는 자동 인코딩됩니다.** `ApiClient._clean()`이 `DateTime`을 UTC ISO-8601로
바꾸고 Dio가 퍼센트 인코딩하므로, `+00:00`의 `+`가 공백으로 해석돼 422가 나는
흔한 함정을 피합니다.

---

## 미구현 (외주 인계 범위)

스켈레톤은 **각 모듈의 읽기 + 핵심 쓰기 경로**까지 동작합니다. 아래는 UI 확장이
필요한 부분입니다.

- **FCM 푸시** — 기기 토큰 등록(`POST /auth/devices`)은 되어 있지만 서버 쪽 발송이
  아직 스텁이라, 현재는 **60초 폴링**으로 알림 배지를 갱신합니다.
  Firebase 연동 후 `firebase_messaging` 추가 + 서버 함수 교체로 전환됩니다.
- **딥링크 라우팅** — 알림의 `payload.route`를 읽어 스낵바로 표시만 합니다.
  `go_router` 등으로 실제 화면 이동을 연결해야 합니다.
- **첨부파일 UI** — 백엔드 `/files` API는 완성돼 있으나 업로드/다운로드 화면은 없습니다.
- **수정/삭제 화면** — AS·자산·게시글의 생성과 상태 변경은 되지만, 전체 편집 폼은
  일부만 있습니다.
- **오프라인 캐시** — 전부 온라인 전제입니다.
- **무한 스크롤** — 현재는 페이지당 50건 단건 조회입니다. `PagedList.hasMore`가
  준비돼 있으니 이어붙이면 됩니다.

API 계약과 화면별 호출 순서는 [../docs/FRONTEND_BRIEF.md](../docs/FRONTEND_BRIEF.md)를
참고하세요.
