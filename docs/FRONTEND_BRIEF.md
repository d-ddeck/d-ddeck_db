# 프론트엔드 작업 브리프 — d-ddeck DB Server

백엔드 API는 완성되어 동작 중입니다. 이 문서 하나로 클라이언트 작업을 시작할 수 있도록
인증 방식, 화면별 호출 순서, 실수하기 쉬운 지점을 정리했습니다.

- **기계용 스펙**: `docs/openapi.json` (70 paths / 101 operations / 119 schemas)
- **대화형 문서**: 서버 실행 후 `http://<서버>:8000/docs`
- **베이스 URL**: `http://<서버>:8000/api/v1`

---

## 0. 먼저 합의가 필요한 사항 — 데스크톱 빌드

**FlutterFlow가 직접 빌드할 수 있는 타겟은 Web / iOS / Android 뿐입니다.**
요구된 Windows · Linux(Ubuntu) 데스크톱 앱은 FlutterFlow 빌더에서 나오지 않습니다.

가능한 경로는 하나입니다.

1. FlutterFlow에서 UI를 구성하고 **Flutter 코드로 익스포트** (유료 플랜 필요)
2. 익스포트한 프로젝트에 `flutter create --platforms=windows,linux .` 로 데스크톱 러너 추가
3. 각 OS에서 `flutter build windows` / `flutter build linux` 로 빌드

따라서 실제 산출물은 "FlutterFlow 프로젝트"가 아니라 **익스포트된 Flutter 코드베이스**가
됩니다. 아래 사항을 착수 전에 확정해 주세요.

- FlutterFlow 유료 플랜(코드 익스포트) 사용 가능 여부
- 데스크톱 빌드 담당 주체 (외주 / 사내)
- FlutterFlow 위젯 중 데스크톱 미지원 요소 사용 금지 목록
- Linux 빌드는 Ubuntu 실기/컨테이너가 필요 (크로스 컴파일 불가)

백엔드는 세 플랫폼이 동일한 REST API를 쓰므로 이 결정에 영향을 받지 않습니다.

---

## 1. 인증

### 토큰

```
Authorization: Bearer <access_token>
```

| 토큰 | 수명 | 저장 위치 |
|---|---|---|
| `access_token` | 60분 | 메모리 (앱 재시작 시 폐기) |
| `refresh_token` | 14일 | 보안 저장소 (`flutter_secure_storage` 권장) |

`access_token`은 갱신 전용이 아닌 모든 요청에 붙입니다.
`401` + `{"error":{"code":"TOKEN_EXPIRED"}}` 를 받으면 `POST /auth/refresh`로 재발급한 뒤
**원래 요청을 1회만 재시도**하세요. 재시도도 실패하면 로그인 화면으로 보냅니다.

> `refresh` 요청에는 `Authorization` 헤더를 붙이지 않습니다. 바디에 리프레시 토큰만 보냅니다.

### 진입 흐름

```
[가입 화면]  POST /auth/signup
                 ↓ 201 "관리자 승인 후 로그인할 수 있습니다"
             (관리자가 승인할 때까지 로그인 불가)
[로그인]     POST /auth/login
                 ├─ 200 → access/refresh/user 수신 → 홈
                 ├─ 403 ACCOUNT_NOT_ACTIVE → error.message 를 그대로 표시
                 ├─ 401 INVALID_CREDENTIALS → "이메일 또는 비밀번호가 올바르지 않습니다"
                 └─ 423 ACCOUNT_LOCKED → error.message 에 남은 분 수 포함
```

로그인 응답의 `user.must_change_password == true` 이면 **다른 화면으로 넘기기 전에**
비밀번호 변경 화면을 띄우세요. 최초 관리자 계정과 비밀번호 초기화 계정이 여기 해당합니다.
변경 후에는 모든 세션이 끊기므로 **다시 로그인**시켜야 합니다.

### 회원가입 입력 규칙

| 필드 | 필수 | 규칙 |
|---|---|---|
| `email` | O | 형식 검증만 (`.local` 등 사내 도메인 허용), 소문자 자동 변환 |
| `password` | O | 8자 이상, **영문 + 숫자 각 1자 이상** |
| `full_name` | O | 100자 이내 |
| `employee_no`, `phone`, `position`, `department_id`, `signup_note` | X | |

`department_id`는 `GET /admin/departments`로 채웁니다(로그인 없이는 조회 불가이므로,
가입 화면에서는 자유 입력 또는 생략하고 승인 시 관리자가 지정하게 두는 편이 낫습니다).

### 권한

`MEMBER(1) < MANAGER(2) < ADMIN(3) < SUPERADMIN(4)`

`user.role`로 메뉴를 숨기되, **권한 판단을 클라이언트에만 의존하지 마세요.**
서버가 모든 경로에서 다시 검사하고 `403 FORBIDDEN`을 반환합니다.

---

## 2. 공통 규약

### 오류 (모든 실패 응답이 동일한 모양)

```json
{ "error": { "code": "RESULT_NOTE_REQUIRED",
             "message": "완료 처리하려면 처리 내용이 필요합니다.",
             "details": null } }
```

- `message`는 **한국어로 작성되어 있으니 그대로 노출**하면 됩니다.
- `code`로 분기하세요. 주요 코드:
  `NOT_AUTHENTICATED` `TOKEN_EXPIRED` `INVALID_TOKEN` `ACCOUNT_NOT_ACTIVE`
  `ACCOUNT_LOCKED` `INVALID_CREDENTIALS` `FORBIDDEN` `NOT_FOUND`
  `VALIDATION_ERROR` `EMAIL_TAKEN` `CODE_TAKEN`
- `VALIDATION_ERROR`(422)의 `details`는 필드별 배열입니다. `loc[1]`이 필드명입니다.

### 목록 응답 (페이지네이션)

```json
{ "items": [...], "total": 137, "page": 1, "size": 20, "pages": 7 }
```

요청 파라미터는 `?page=1&size=20` (size 최대 200). **파서를 제네릭 하나로 만드세요.**

> 예외: `GET /calendar/events`, `GET /inventory/locations`, `GET /admin/codes`,
> `GET /admin/audit-logs`, `GET /board/boards`, `GET /calendar/calendars`는
> 페이지 래퍼 없이 **배열을 직접** 반환합니다.

### 날짜/시간

- 모든 시각은 **UTC ISO-8601**(`2026-09-20T07:30:00+00:00`)입니다.
- 표시할 때 기기 타임존으로 변환하고, 보낼 때 UTC로 되돌리세요.
- **쿼리 파라미터에 넣을 때 반드시 URL 인코딩하세요.** `+00:00`의 `+`가 공백으로
  해석되어 422가 납니다. Dart의 `Uri(queryParameters: {...})`를 쓰면 자동 처리됩니다.

### ID

모두 UUID 문자열입니다. 정수로 파싱하지 마세요.

### 금액/수량

`Decimal`이 **문자열**로 직렬화됩니다(`"150000.00"`). `double.parse()` 하세요.

---

## 3. 화면별 호출 순서

### 3-1. 앱 시작

```
1. 저장된 refresh_token 있음?  →  POST /auth/refresh
                               →  성공: GET /auth/me 로 프로필 갱신 후 홈
                               →  실패: 로그인 화면
2. (로그인 후) POST /auth/devices        푸시 토큰 등록
3. (로그인 후) GET  /admin/settings/SYSTEM   회사명·점검모드 등 공개 설정
```

### 3-2. 홈 / 대시보드

| 위젯 | 호출 |
|---|---|
| 미읽음 뱃지 | `GET /calendar/notifications/count` |
| 내 AS 진행중 | `GET /service/tickets?only_open=true&assignee_id={me}` |
| 오늘 일정 | `GET /calendar/events?date_from=…&date_to=…` |
| AS 요약 카드 | `GET /service/stats/summary?date_from=…` |
| 승인 대기 (ADMIN) | `GET /users/pending` |

### 3-3. 서비스(AS)

```
목록      GET  /service/tickets
          ?q= &status= &priority= &assignee_id= &customer_id= &category_id=
          &only_open= &date_from= &date_to= &sort=received_desc &page= &size=
상세      GET  /service/tickets/{id}      (customer/assignee/parts/logs 포함)
접수      POST /service/tickets
수정      PATCH /service/tickets/{id}     (보낸 필드만 반영)
상태변경  POST /service/tickets/{id}/status   ← 상태는 반드시 이 경로로
작업기록  POST /service/tickets/{id}/logs
부품추가  POST /service/tickets/{id}/parts
```

접수 폼의 드롭다운 4개는 **분류 코드에서 가져옵니다**:

```
GET /admin/codes/SERVICE_CATEGORY   → items[]  분류
GET /admin/codes/SERVICE_SYMPTOM    → items[]  증상
GET /admin/codes/SERVICE_CAUSE      → items[]  원인
GET /admin/codes/SERVICE_ACTION     → items[]  조치
```

각 `item`은 `{id, code, name, color, sort_order, is_active}`입니다.
**`sort_order`로 정렬하고, `is_active=false`는 신규 선택지에서 제외**하되
기존 데이터 표시용으로는 남겨두세요. 하드코딩 금지 — 관리자가 설정창에서 바꿉니다.

상태 전이:

```
RECEIVED → ASSIGNED → IN_PROGRESS → COMPLETED
                   ↘ PENDING_PARTS ↗
           (어느 단계에서든) → CANCELED
```

`COMPLETED`로 보낼 때 `result_note`가 비어 있으면 `400 RESULT_NOTE_REQUIRED`가
납니다(관리 설정 `require_result_note`로 끌 수 있음). 완료 처리 UI에 처리내용
입력란을 필수로 두세요.

### 3-4. AS 통계 화면

```
GET /service/stats/summary            ?date_from= &date_to= &assignee_id= …
GET /service/stats/grouped?group_by=  category|symptom|cause|action|
                                      assignee|status|priority|channel|department
GET /service/stats/trend?interval=    day|week|month
```

세 엔드포인트 **모두 같은 필터 파라미터**를 받습니다. 화면 상단 필터를 그대로
세 호출에 넘기면 숫자가 일관됩니다.

`grouped` / `by_status` / `by_priority`의 각 버킷:

```json
{ "key": "COMPLETED", "label": "완료", "color": "#10B981",
  "count": 48, "ratio": 0.8, "avg_resolution_minutes": 1243.5,
  "total_cost": "14276500.00" }
```

- **`label`과 `color`를 그대로 쓰세요.** 한글 라벨과 차트 색상을 클라이언트가
  따로 관리할 필요가 없고, 분류 코드의 색을 바꾸면 차트에도 즉시 반영됩니다.
- `ratio`는 0.0~1.0 → 파이차트 비율에 바로 사용.
- `avg_resolution_minutes`는 **분** 단위. 시간 표시하려면 60으로 나누세요.
- `trend`는 **데이터가 없는 기간을 생략**합니다. 연속 축이 필요하면
  클라이언트에서 빈 구간을 채우세요.

### 3-5. 재고관리

```
위치 트리   GET  /inventory/locations/tree     children[] 중첩 + asset_count
위치 목록   GET  /inventory/locations          평면 배열(드롭다운용, path 포함)
자산 목록   GET  /inventory/assets?q=&status=&category_id=&location_id=
                &include_sublocations=true&below_min_only=&page=&size=
자산 상세   GET  /inventory/assets/{id}        location/holder/category 포함
자산 등록   POST /inventory/assets             asset_no 생략 시 자동 채번
자산 수정   PATCH /inventory/assets/{id}
위치·보관자 POST /inventory/assets/{id}/move   ← 반드시 이 경로
이동 이력   GET  /inventory/assets/{id}/movements
요약        GET  /inventory/summary
```

> **`PATCH`로는 위치·보관자·상태가 바뀌지 않습니다.** 이력이 남지 않기 때문에
> 의도적으로 막아뒀습니다. 반드시 `/move`를 쓰세요.

`/move`의 `movement_type`이 상태를 자동으로 결정합니다:

| movement_type | 자동 상태 | 용도 |
|---|---|---|
| `MOVE` | 변화 없음 | 위치만 이동 |
| `ASSIGN` | `IN_USE` | 사용자에게 불출 |
| `RETURN` | `IN_STOCK` | 반납 (보관자 해제) |
| `REPAIR` | `REPAIR` | 수리 반출 |
| `DISPOSE` | `DISPOSED` | 폐기 |
| `STOCKTAKE` | 변화 없음 | 실사 (quantity 보내면 수량 보정) |

바코드 스캔은 `GET /inventory/assets?q=<스캔값>`로 조회합니다
(`asset_no` / `serial_no` / `barcode` / 품명 / 모델 전체 검색).

### 3-6. 게시판

```
게시판 목록  GET  /board/boards                  ← 내 권한으로 읽을 수 있는 것만 내려옴
글 목록      GET  /board/boards/{id}/posts?q=&page=&size=
글 상세      GET  /board/posts/{id}              ← 조회수 증가(본인 글 제외)
글 작성      POST /board/boards/{id}/posts
댓글         POST /board/posts/{id}/comments
```

`GET /board/boards`의 각 항목이 **그 게시판의 설정**입니다. UI를 여기 맞춰 그리세요.

| 필드 | 화면 반영 |
|---|---|
| `write_role` | 내 role 미만이면 글쓰기 버튼 숨김 |
| `allow_comment` | false면 댓글 입력창 숨김 |
| `allow_attachment` | false면 첨부 버튼 숨김 |
| `allow_secret` | false면 비밀글 체크박스 숨김 |
| `page_size` | 목록 기본 size |
| `sort_order` | 탭 순서 |

상단 고정(`is_pinned`)은 MANAGER 이상만 설정할 수 있습니다.

### 3-7. 캘린더

```
캘린더 목록  GET  /calendar/calendars           내가 볼 수 있는 것만
일정 조회    GET  /calendar/events?date_from=&date_to=&calendar_id=&mine_only=
일정 등록    POST /calendar/events
일정 수정    PATCH /calendar/events/{id}
참석 응답    POST /calendar/events/{id}/respond  {"response":"ACCEPTED"}
```

`GET /events`는 **기간과 겹치는 모든 일정**을 반환합니다(그 기간에 시작하는 것만이
아님). 여러 날에 걸친 일정이 각 날짜에 정상 표시됩니다. 최대 조회 폭은 400일입니다.

일정 등록 시:

- `participant_ids`에 주최자를 넣지 않아도 **자동으로 참석자에 추가**됩니다.
- `reminders`를 **생략하면 캘린더 기본값(기본 30분 전)이 적용**됩니다.
  알림 UI를 아직 만들지 않았다면 그냥 빼고 보내면 됩니다.
- 참석자에게 즉시 초대 알림이, 예약 시각에 리마인더 알림이 갑니다.

`is_private=true` 일정은 관계없는 사람에게 제목이 `"비공개 일정"`으로,
설명·장소가 `null`로 마스킹되어 내려옵니다. 별도 처리 없이 그대로 표시하세요.

캘린더 종류: `COMPANY`(전사) / `DEPARTMENT`(부서) / `PERSONAL`(개인).
개인 캘린더는 **본인만** 수정·삭제할 수 있습니다(관리자도 불가).
`color` 필드를 일정 색으로 쓰세요(일정별 `color`가 있으면 그것이 우선).

### 3-8. 알림

```
목록      GET  /calendar/notifications?unread_only=true&page=&size=
뱃지      GET  /calendar/notifications/count
읽음      POST /calendar/notifications/{id}/read
전체읽음  POST /calendar/notifications/read-all
```

각 알림의 `payload`가 딥링크 대상입니다:

```json
{ "route": "/calendar/event", "event_id": "…" }
{ "route": "/service/ticket",  "ticket_id": "…" }
{ "route": "/board/post",      "post_id": "…" }
{ "route": "/admin/users/pending", "user_id": "…" }
```

`route` 값으로 분기해 해당 화면으로 이동시키세요.

> **푸시는 아직 실제로 나가지 않습니다.** 서버의 FCM 연동은 어댑터 스텁 상태라
> 현재는 인앱 알림만 생성됩니다. 클라이언트는 **폴링 또는 화면 진입 시 조회**로
> 구현해 두세요. Firebase 프로젝트가 준비되면 서버 쪽 함수 하나만 교체되고,
> 등록해 둔 기기 토큰(`POST /auth/devices`)으로 푸시가 나가기 시작합니다.

### 3-9. 관리 화면

```
승인 대기  GET  /users/pending
승인       POST /users/{id}/approve   {"role":"MEMBER","department_id":"…"}
반려       POST /users/{id}/reject    {"reason":"…"}
계정 목록  GET  /users?status=&role=&department_id=&q=
계정 수정  PATCH /users/{id}
비번 초기화 POST /users/{id}/reset-password   ← 응답 message에 임시 비밀번호 1회 노출
부서       GET|POST /admin/departments
감사로그   GET  /admin/audit-logs?action=&module=&actor_id=&q=
서버 상태  GET  /admin/health
시스템통계 GET  /admin/stats
```

**권한 부여 제약**: 자신과 같거나 높은 권한은 부여할 수 없습니다(SUPERADMIN 제외).
승인 다이얼로그의 role 드롭다운에서 해당 항목을 비활성화하세요.

### 3-10. 설정창 (5개 모듈 공통 화면 1개)

요구사항의 "각 기능별 설정창"은 **화면 하나로 전부 처리**하도록 설계했습니다.

```
GET /admin/settings/{module}    module: SYSTEM|AUTH|SERVICE|INVENTORY|BOARD|CALENDAR
PUT /admin/settings/{module}    { "settings": [ … 폼 전체 … ] }
```

응답:

```json
{ "module": "SERVICE",
  "settings": [
    { "key": "ticket_prefix", "value": "AS", "value_type": "string",
      "label": "접수번호 접두어", "description": null, "is_public": true }
  ],
  "code_groups": [
    { "code": "SERVICE_CATEGORY", "name": "서비스 분류",
      "items": [ { "id":"…", "code":"REPAIR", "name":"수리", "color":"#EF4444",
                   "sort_order":2, "is_active":true } ] }
  ] }
```

**`value_type`으로 위젯을 고르세요**:

| value_type | 위젯 |
|---|---|
| `string` | TextField |
| `int` / `float` | 숫자 TextField |
| `bool` | Switch |
| `list` | 칩 입력 (문자열 배열) |
| `json` | 고급 편집 (또는 숨김) |

`label`을 라벨로, `description`을 도움말로 씁니다. **설정 항목을 하드코딩하지 마세요.**
서버에 행을 추가하면 화면에 자동으로 나타나야 합니다.

`code_groups`는 같은 화면 아래쪽의 분류 관리 섹션입니다:

```
POST   /admin/codes/{group_id}/items      항목 추가
PATCH  /admin/codes/items/{item_id}       항목 수정
DELETE /admin/codes/items/{item_id}       비활성화(기존 데이터 분류는 유지)
POST   /admin/codes/{group_id}/reorder    {"item_ids":[…새 순서…]}  드래그 정렬
```

게시판 설정만 별도입니다 — 게시판마다 값이 다르므로
`PATCH /board/boards/{id}`로 저장합니다.

---

## 4. 첨부파일

```
업로드   POST /files          multipart: entity_type, entity_id, file
목록     GET  /files/by-entity/{entity_type}/{entity_id}
다운로드 GET  /files/{attachment_id}      ← 인증 헤더 필요
삭제     DELETE /files/{attachment_id}
```

`entity_type`: `service_ticket` | `asset` | `post` | `event` | `user`
최대 크기 기본 25MB (`/admin/settings/BOARD`의 `attachment_max_mb`로 조회).

**첨부는 대상이 먼저 생성된 뒤에 올립니다** (`entity_id`가 필요하므로).
글쓰기 화면이라면 저장 → 반환된 `id`로 업로드 순서입니다.

---

## 5. 실수하기 쉬운 지점 정리

1. 쿼리의 날짜를 **URL 인코딩하지 않으면 422**가 납니다.
2. `Decimal` 필드는 **문자열**입니다. `double.parse()` 필요.
3. AS 상태 변경은 `PATCH`가 아니라 **`POST /status`** 입니다.
4. 자산 위치 변경은 `PATCH`가 아니라 **`POST /move`** 입니다.
5. 분류 드롭다운을 **하드코딩하지 마세요.** `/admin/codes/…`에서 받아야 합니다.
6. 통계의 `label` / `color`를 **재정의하지 마세요.** 서버 값을 그대로 쓰면
   설정 변경이 자동 반영됩니다.
7. `403 ACCOUNT_NOT_ACTIVE`는 로그인 시점뿐 아니라 **이용 중에도** 발생합니다
   (관리자가 계정을 정지하면 기존 토큰이 즉시 무효화됩니다).
   전역 인터셉터에서 로그인 화면으로 보내세요.
8. `must_change_password`를 무시하고 진행하지 마세요.
9. 목록 응답이 `{items,total,…}`인 엔드포인트와 **배열 직접 반환**인 엔드포인트가
   섞여 있습니다(2절 참고). OpenAPI 스펙에서 확인하세요.

---

## 6. 로컬 개발 서버

```bash
cd backend
python -m venv .venv && .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env
python scripts/seed_demo.py
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

데모 계정: `seojun.kim@ddeck.local` / `demo1234` (ADMIN),
`admin@ddeck.local` / `admin1234` (SUPERADMIN).
최근 90일 AS 60건, 자산 24건, 게시글 9건, 일정 8건이 들어 있어
통계·목록 화면이 비어 보이지 않습니다.

에뮬레이터에서 호스트 PC에 접속할 때: Android 에뮬레이터는 `10.0.2.2:8000`,
실기기는 PC의 LAN IP를 사용하세요.

## 구 서버 규칙 반영(접수)

- 접수·수정: `/service/tickets` POST 및 `/{id}` PATCH, 브랜드→매장 조회, 분류 코드와 `SERVICE` 설정, `/inventory/assets?q=…` 시리얼 자동완성. 제목은 발생 내용 첫 줄(250자), 렌탈 날짜는 `YYYY-MM-DD`.
- 목록: `/service/tickets`와 `/service/stats/summary`에 같은 필터(요약은 상태 제외), `/service/tickets/export.xlsx`로 엑셀 저장·열기. 요약 계약에 `q`가 없어 검색어가 있으면 전체·종결·미종결 목록의 `total`로 요약 칩을 표시한다.
- 상세: `/service/tickets/{id}`, `/{id}/status`, `/{id}/logs`와 기존 첨부 API. 종결 시 대응 내용·대응인원·대응일을 보내고, 저장 안내 `notices`와 서버 오류 메시지를 표시한다.
- 대시보드: `/service/dashboard?limit=10`의 미종결·렌탈 미회수·최근 기록·연도별 건수와 상세/미종결 목록 이동. 기존 타일 유지.
- 통계 저장소: `/service/stats/grouped`, `/summary`, `/trend`, `/crosstab`, `/crosstab.xlsx`, `/store-years` 계약 지원.
- 매장 상세: “이 매장 기록 추가”에서 브랜드·매장을 채운 접수 폼으로 이동. 폼·필터·종결 다이얼로그는 360px와 데스크톱에서 스크롤·줄바꿈을 지원한다.

## 구 서버 규칙 반영(재고·매장)

- 재고는 **현황 → ASSET_CATEGORY 활성 항목 순서의 종류 탭 → 목록**으로 구성한다. 현황의 상태·브랜드·장소 × 종류 숫자는 목록 필터로 연결한다. 종류 탭은 브랜드/보관 장소 칩과 매장(브랜드 → 매장)/미설치(장소) 표를 제공한다. 목록은 페이지 이동, 다중 선택, 검색·종류·세부 상태·브랜드·매장·위치·설치 여부 필터와 정렬을 제공한다.
- `CodeItem.extra`의 `rule`을 등록과 단건/일괄 이동에서 함께 사용한다. `store`는 매장 필수, `as`는 매장을 유지하며 상태 변경, `clear`는 서버가 매장·세트를 비우고 지정 장소로 이동, `free`는 선택 위치로 회수한다. 상태 없는 “위치만 이동”도 지원한다. 상태 이름으로 동작을 하드코딩하지 않는다.
- 등록은 종류의 하위 품명/제조사 코드와 `INVENTORY.maker_required_categories`를 사용한다. 줄·쉼표로 나눈 S/N을 `/inventory/assets/bulk`에 보내고 등록 목록/중복 S/N을 표시한다. `purchase_date`는 화면에서 **설치일**로 표시한다. 목록 API에는 브리프 객체가 없으므로 상태·위치·매장 ID를 코드/매장/위치 목록과 연결해 표시한다.
- 단건 이동과 일괄 이동은 같은 입력 폼을 사용한다. 일괄 결과의 `moved`, `skipped`, `errors`는 목록이며 각 건수와 내용을 함께 표시한다. 자산 상세는 이동 이력의 상태/매장 ID를 이름으로 바꾸고 사유를 표시한다. 렌탈 D-day는 양수 `D-N`, 0 `D-day`, 음수 `D+N`이며 접수 상세로 연결한다.
- 엑셀은 `/inventory/assets/export.xlsx`와 기존 `ui/common/download.dart`를 사용한다. 검색·종류·세부 상태·브랜드·매장·위치·설치 여부 필터를 전달한다. 현재 서버 엑셀 계약에는 “미지정 ID”와 세부 상태 없는 enum 집계 필터가 없으므로 해당 셀의 목록은 클라이언트에서 정확하게 좁히고, 엑셀은 안내 후 중단한다. 또한 목록은 선택 장소만 표시하지만 서버 엑셀의 장소 필터는 하위 장소를 포함한다. 하위 장소가 있는 운영 환경에서는 서버 엑셀 계약에 `include_sublocations` 지원이 필요하다.
- 매장 검색은 매장명·메모, 폐점 포함 토글을 제공하고 브랜드 카드의 서버 순서를 유지한다. 매장 상세는 세트별 보유 장비, 서비스구분별 **원인 수** 막대, 미회수 렌탈, 최근 대응 이력과 해당 매장으로 미리 채운 기록 등록을 제공한다. 기존 접수 폼·상세, 날짜 직렬화·파일 다운로드 헬퍼를 재사용하며 접수 통계의 `Crosstab`/`StoreYears` 계약은 변경하지 않는다.
- 관리자의 매장 상태 편집에서 폐점으로 저장할 때 `movable_count`, `recover_options`(첫 항목 기본), “옮기지 않음”, 폐점일을 확인하고 `/stores/{id}/close`를 호출한다. `moved`/`notices`를 표시하며 렌탈 장비는 대응 기록에서 회수하도록 안내한다. 개점일은 신규 등록에서도 저장한다.
- 매장 등록 직후와 상세의 **장비 설정**에서 세트 추가·이름 변경·삭제 API, 설치일, 전동/비전동 선택, 세트 메모, 종류별 S/N·품명을 제공한다. 비전동 그리퍼의 빈 S/N은 서버가 관리 번호를 부여한다. 장비 설정의 `added`/`moved`/`kept` 결과를 표시하고 현재 장비를 갱신한다. 장비별 세트 이동은 같은 매장을 목적지로 `/move`를 호출한다. 세트 이동 후에는 입력 폼도 현재 설치 정보로 갱신한다.
- 표는 가로 스크롤, 폼·결과 다이얼로그는 세로 스크롤을 지원한다. 서버 오류는 `ApiException.message`를 그대로 SnackBar에 표시한다. 모델 파싱 회귀 테스트는 `app/test/inventory_store_models_test.dart`에 추가했으며 요청에 따라 실행하지 않았다. 위젯 테스트를 추가할 경우 `NoSplash.splashFactory`를 사용한다.

사람이 확인할 시나리오(폰과 데스크톱에서 동일하게 확인):

1. 현황의 상태/브랜드/장소 숫자를 눌러 종류와 조건이 걸린 목록으로 이동하고, 종류 탭의 위치 칩·상태 배지·엑셀 결과를 비교한다.
2. 종류별 품명/제조사와 필수 제조사 표시를 확인한 뒤 줄·쉼표 S/N(중복 포함)을 등록한다. 설치일과 등록/중복 결과를 확인한다.
3. 단건 및 여러 페이지에서 선택한 장비를 `store`/`as`/`clear`/`free`와 “위치만 이동”으로 변경한다. 매장/세트 입력, AS 매장 유지, 이동 이력의 이름·사유, 일괄 부분 실패를 확인한다.
4. 매장명·메모 검색/폐점 포함을 확인하고 상세의 원인 수·렌탈 D-day·대응 이력·기록 추가를 확인한다. 관리자 폐점 확인에서 기본 회수/다른 회수/옮기지 않음/취소를 각각 확인하고 렌탈은 남는지 확인한다.
5. 매장을 등록해 장비 설정에 진입한 뒤 세트 추가·이름 변경, 전동/비전동 슬롯, 빈 비전동 S/N 자동 번호, 신규/다른 매장/현재 매장 S/N 저장 결과를 확인한다. 장비별 세트 이동 후 삭제 및 장비가 남은 세트 삭제의 서버 오류를 확인한다.

## 구 서버 규칙 반영(통계·캘린더)

- 통계는 **메인(전체) + SERVICE_CATEGORY 활성 항목 탭**, 선택 브랜드를 공통 조건으로 사용한다. 연도·기간 필터 없이 전 기간을 집계한다. 기존 `Crosstab`, `StoreYears`, 저장소와 다운로드 헬퍼를 재사용한다.
- 연도별 빈도는 `year × category`의 행 합계·대응 건수·원인 수 기준 비율이다. 브랜드/매장 × 연도, 브랜드/매장 × 구분(구분 탭은 증상), 제조사 × 연도를 표시한다. 제조사는 메인과 로봇팔·제어박스·전동 그리퍼 탭에 표시하며, 구분 탭에서는 제조사 × 증상도 제공한다. 매장은 원인 수 내림차순이며 상위 15개 막대를 함께 표시한다.
- 교차표 머리글 아래에 “원인 수 기준 · 대응 건수는 괄호”를 표시한다. 대응 건수는 서버의 중복 제거 값을 사용하며 셀을 더해서 만들지 않는다. 숫자 배경은 1 이상 연노랑, 2 이상 노랑, 5 이상 연주황이다. 숫자·행 합계·열 합계에서 연도/브랜드/매장/구분/증상/제조사 조건을 기존 접수 목록의 `initialFilters`로 전달한다. 표별 엑셀은 같은 축과 필터로 `crosstabXlsx()`를 호출한다.
- 현재 목록 계약은 UUID 필터만 받으므로 `-`(미분류·미상) 셀은 안내 SnackBar를 표시한다. 미지정 조건을 생략한 전체 목록으로 보내지 않는다. 해당 셀의 정확한 목록 이동에는 서버의 미지정 필터 지원이 필요하다.
- 기존 grouped 파이/막대·요약·추이는 교차표 아래에 유지한다. 메인 맨 아래의 연도별/브랜드별 운영 매장은 `storeYears()` 원본 값을 사용한다. 이 API에는 브랜드 필터와 XLSX 엔드포인트가 없어 **전체 브랜드 기준**임을 명시하고 두 표는 Excel용 UTF-8 CSV로 내보낸다. 운영/개점/폐점/연말 운영/대응 매장/대응 건수/매장당 건수와 개점 연도 미상 매장을 표시한다. 운영 매장 수는 접수 건수가 아니므로 접수 목록에 연결하지 않으며, 연도별 대응 건수만 해당 연도 전체 접수로 연결한다.
- 캘린더는 `/calendar/holidays?year=`를 연도별로 불러와 캐시한다. 월간 격자에 걸치는 이전/다음 연도도 불러와 연말·연초 공휴일이 빠지지 않는다. 날짜를 UTC로 이동하지 않고 빨간 날짜·작은 공휴일 이름·툴팁으로 표시한다.
- 재고 **목록 탭 → 위치 관리**에서 트리 들여쓰기·종류·자산 수를 표시한다. ADMIN 이상에게만 위치 추가(코드·이름·종류·상위 위치)와 삭제 버튼을 제공한다. `tree()`, `createLocation()`, `DELETE /inventory/locations/{id}`를 사용하며 삭제 거절 메시지는 그대로 표시한다. 복귀 시 재고의 위치 선택지도 갱신한다.
- 변경 화면의 서버 오류는 `ApiException.message`를 그대로 SnackBar에 표시한다. 가로 스크롤 표와 스크롤 가능한 위치 폼을 사용한다. `app/test/inventory_store_models_test.dart`에 교차표·운영 매장·공휴일·위치 트리 파싱 테스트를 추가했으며 요청대로 실행하지 않았다. 위젯 테스트는 추가하지 않았으며 향후 추가 시 `NoSplash.splashFactory`를 사용한다. 전체 `dart format`은 실행하지 않았다.

사람이 확인할 시나리오(폰과 데스크톱 공통):

1. 메인/서비스구분/브랜드를 바꾸며 다중 원인 기록의 원인 수·괄호 대응 건수·비율, 1/2/5 색상, 매장 정렬·상위 15개 막대와 제조사 표 노출을 확인한다.
2. 교차표의 셀·행/열 합계에서 접수 목록 조건과 XLSX 결과를 비교한다. 미상 셀 안내, 운영 매장 전체 기준·CSV, 기존 파이/막대도 확인한다.
3. 공휴일·대체공휴일의 빨간 날짜와 이름/툴팁을 확인하고 12월↔1월 이동 및 연도 변경 시 인접 연도 공휴일·기존 일정 표시를 확인한다.
4. 일반 사용자와 ADMIN으로 위치 트리를 열어 버튼 권한 차이를 확인한다. 상위 위치를 선택해 추가하고 빈 위치 삭제·자산 있는 위치 삭제 거절 메시지·재고 복귀 후 위치 선택지 갱신을 확인한다.

검증: 변경 Dart 파일과 모델 테스트 파일을 정적 분석했으며 오류·경고는 없다. 기존 `service_page.dart`의 중괄호 스타일 안내(info) 2건만 남아 있다. 테스트·앱 빌드는 실행하지 않았다.
