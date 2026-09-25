# 아키텍처 및 설계 결정

이 문서는 "왜 이렇게 만들었는가"를 남깁니다. 스켈레톤 위에 상세 기획을 얹을 때
기존 구조를 깨지 않고 확장하려면 이 결정들을 알고 있어야 합니다.

---

## 1. 요구사항 → 구조 매핑

| 요구사항 | 구현 위치 |
|---|---|
| 5개 모듈 분류 | `app/api/v1/{service,inventory,board,calendar,admin}.py` |
| **각 기능별 설정창** | `ModuleSetting` + `CodeGroup`/`CodeItem` (아래 3절) |
| AS 입력 → 분류 → 자동 통계 | `ServiceTicket`의 4개 분류 FK + `app/services/stats.py` |
| 자산 정보 + 위치 정리 | `Asset` + `Location` 트리 + `AssetMovement` 이력 |
| 일정 공유 + 대상자 알림 | `Event`/`EventParticipant`/`EventReminder` → `Notification` |
| 관리자 서버 관리 | `/admin/settings`, `/admin/codes`, `/admin/audit-logs`, `/admin/health`, `/admin/stats` |
| 가입 → 승인 → 로그인 | `UserStatus` 상태 기계 + `/users/pending` 승인 대기열 |

---

## 2. 전체 테이블 (28개)

```
인증      users, departments, refresh_tokens, devices
관리      module_settings, code_groups, code_items, audit_logs, attachments
서비스    customers, service_tickets, service_parts, service_logs
재고      locations, assets, asset_movements
게시판    boards, posts, post_comments
캘린더    calendars, events, event_participants, event_reminders, notifications
```

공통 규약:

- **PK는 UUID.** 클라이언트가 미리 생성할 수 있고, 나중에 지점별 DB를 합칠 때
  ID 충돌이 없습니다. auto-increment였다면 병합이 사실상 불가능합니다.
- **소프트 삭제.** `deleted_at IS NULL`이 모든 목록 쿼리의 기본 조건입니다.
  통계와 감사로그가 과거 데이터를 계속 참조해야 하기 때문입니다.
- **Enum은 VARCHAR 저장** (`native_enum=False`). PostgreSQL ENUM 타입이면
  값을 하나 추가할 때마다 마이그레이션 + `ALTER TYPE`이 필요합니다.
- **타임스탬프는 전부 UTC aware** (`UTCDateTime`, 4절 참고).

---

## 3. 설정창을 모듈마다 새로 만들지 않는 이유

요구사항 2번(각 기능별 설정창)을 모듈별 전용 테이블 5개로 만들면,
설정 항목이 하나 늘 때마다 마이그레이션 + 스키마 + 화면을 모두 손봐야 합니다.
대신 두 개의 범용 저장소로 처리합니다.

**(a) `module_settings` — 키/값 설정**

```
GET  /api/v1/admin/settings/SERVICE   → 설정 항목 + 관련 분류 코드 한 번에
PUT  /api/v1/admin/settings/SERVICE   → 폼 전체를 한 번에 저장(upsert)
```

각 행은 `value`(JSON), `value_type`, `label`, `description`, `is_public`을 가집니다.
프론트는 `value_type`만 보고 위젯을 고르면 되므로, **설정 화면 하나로 5개 모듈을
전부 렌더링**할 수 있습니다. 새 설정 추가는 행 하나 삽입이고 코드 변경이 없습니다.

`is_public=true`는 일반 사용자도 읽습니다. UI를 그리는 데 필요한 값
(목록 개수, 접수번호 접두어 등)이 관리자 전용이면 화면을 그릴 수 없기 때문입니다.

**(b) `code_groups` / `code_items` — 분류 마스터**

서비스 분류·증상·원인·조치, 자산 분류, 일정 유형이 전부 같은 구조입니다.
그룹당 항목 CRUD + 드래그 정렬(`POST /codes/{id}/reorder`) 화면 하나면 됩니다.

항목 삭제는 **비활성화(soft)** 입니다. 기존 AS 건이 그 코드를 가리키고 있고,
통계가 그 이름을 계속 풀어낼 수 있어야 하기 때문입니다.

게시판만 예외입니다 — `Board` 행 자체가 그 게시판의 설정 레코드입니다
(읽기/쓰기 권한, 댓글 허용, 비밀글, 목록 개수). 게시판마다 값이 달라야 해서
전역 키/값에 담을 수 없습니다.

---

## 4. SQLite ↔ PostgreSQL 이식성

지금은 SQLite로 돌고 운영은 PostgreSQL입니다. 차이를 흡수하는 지점은 4곳뿐입니다.

| 지점 | 문제 | 해결 |
|---|---|---|
| `app/models/base.py` `UTCDateTime` | SQLite는 타임존을 저장하지 않아 naive로 돌아옴 → aware와 비교 시 `TypeError` | 저장 시 UTC 변환, 조회 시 UTC 부착 |
| `app/models/base.py` `JSONType` | JSONB는 PostgreSQL 전용 | `JSON().with_variant(JSONB, "postgresql")` |
| `stats.resolution_minutes_expr()` | datetime 뺄셈 문법이 다름 | PG `extract(epoch …)/60`, SQLite `julianday()*1440` |
| `stats.period_expr()` | 기간 버킷팅 문법이 다름 | PG `date_trunc`+`to_char`, SQLite `strftime` |

> `period_expr`의 주 단위만 완전히 동일하지 않습니다. PostgreSQL은 ISO 주
> (`IYYY-"W"IW`), SQLite는 월요일 기준 `%W`를 씁니다. 추이 차트 용도로는 문제
> 없지만, 주차 번호를 그대로 외부에 노출한다면 확인이 필요합니다.

**전환은 `.env`의 `DATABASE_URL` 한 줄**이면 됩니다. `bare postgresql://`로 적어도
`config.py`가 psycopg3 드라이버(`postgresql+psycopg://`)로 자동 교정합니다.

---

### SQLite 의 SAVEPOINT

pysqlite 드라이버의 기본 트랜잭션 처리는 `RELEASE SAVEPOINT` 때 통째로 커밋해 버린다. 접수번호·자산번호 채번이 `begin_nested()` 를 쓰므로, 그 뒤에 규칙 검사가 실패하면 반쪽 행이 남을 수 있었다. `app/core/database.py` 가 SQLAlchemy 문서의 처방대로 드라이버의 BEGIN 을 끄고(`isolation_level=None`) `begin` 이벤트에서 직접 `BEGIN` 을 낸다. PostgreSQL 은 영향 없다.

## 5. 인증

- **액세스 토큰(JWT, 기본 60분) + 리프레시 토큰(14일)**.
- 리프레시 토큰은 **DB에 해시로 저장**합니다(`refresh_tokens`). 서명만으로 판단하면
  세션을 강제 종료할 방법이 없기 때문입니다. 관리자는 계정 정지·비밀번호 초기화로
  모든 세션을 즉시 끊을 수 있습니다.
- **계정 상태는 매 요청마다 재확인**합니다(`core/deps.py`). 정지 처리가 액세스 토큰
  만료를 기다리지 않고 즉시 반영됩니다. (스모크 테스트에서 검증)
- 비밀번호는 bcrypt. 72바이트 초과는 bcrypt가 조용히 잘라내므로 SHA-256으로
  선해시합니다.
- 로그인 실패 누적 시 잠금(`max_failed_logins` / `lockout_minutes` 설정).
- 존재하지 않는 이메일과 틀린 비밀번호는 **같은 오류**를 반환합니다(계정 열거 방지).

**권한 4단계**: `MEMBER(1) < MANAGER(2) < ADMIN(3) < SUPERADMIN(4)`.
`require_role(Role.ADMIN)` 의존성으로 라우트를 막고, 승인·권한 부여 시
**자신과 같거나 높은 권한은 부여할 수 없습니다**(SUPERADMIN 제외).

### 이메일 검증을 `EmailStr`로 하지 않은 이유

pydantic의 `EmailStr`은 `email-validator`에 위임하는데, 이 라이브러리는
`.local`, `.lan`, `.internal` 같은 special-use TLD를 거부합니다.
**사내 온프레미스 서버가 실제로 쓰는 도메인이 바로 그것들**이라 정상 계정을
막게 됩니다. `schemas/common.py`의 `Email` 타입이 형식만 검사하고 소문자로
정규화합니다. 실제 도달 가능성은 어차피 관리자 승인 단계에서 걸러집니다.

---

## 6. AS 자동 통계

통계는 **전부 SQL 집계**입니다. 행을 파이썬으로 끌어와 세지 않으므로
접수 건이 수만 건이 되어도 응답 크기와 속도가 유지됩니다.

분류를 4개 FK(`category` / `symptom` / `cause` / `action`)로 나눈 것이 핵심입니다.
"무엇을 했나 / 어떤 증상인가 / 왜 그랬나 / 어떻게 고쳤나"가 각각 독립된 축이라,
하나의 분류 필드로는 교차 분석이 불가능합니다.

```
GET /service/stats/summary    총건수 · 완료율 · 평균 처리시간 · 만족도 · 지연 · 비용
GET /service/stats/grouped    9개 축 중 하나로 집계 (category|symptom|cause|action|
                              assignee|status|priority|channel|department)
GET /service/stats/trend      일 / 주 / 월 접수·완료 추이
```

세 엔드포인트가 **같은 필터 파라미터**(`apply_filters()`)를 받습니다. 목록 화면의
필터를 그대로 통계에 넘기면 숫자가 어긋나지 않습니다.

응답의 `StatBucket`은 `key`(안정 식별자) / `label`(한글 표시) / `color`를 모두
포함합니다. 색상은 분류 코드 마스터에서 오므로 **차트와 목록 칩의 색이 자동으로
일치**하고, 프론트가 자체 한글 매핑표를 들고 있을 필요가 없습니다.

---

## 7. 재고: 현재값 + 이력 분리

`Asset.location_id` / `holder_id` / `status`는 **지금 상태의 캐시**이고,
`asset_movements`가 **어떻게 거기까지 왔는지의 원장**입니다.

변경은 `POST /inventory/assets/{id}/move` 한 경로로만 일어납니다.
이 엔드포인트가 이력 행을 쓰고 캐시를 갱신하므로 둘이 어긋날 수 없습니다.
(`PATCH /assets/{id}`는 위치·보관자를 건드리지 않습니다.)

`Location.path`는 `본사 > 2층 > 창고A` 형태의 비정규화 캐시입니다. 목록 화면에서
전체 경로를 보여주려고 매번 트리를 거슬러 올라가지 않기 위한 것이고,
상위 노드 이름/위치가 바뀌면 하위 전체를 갱신합니다(`_refresh_descendant_paths`).

하위 위치 포함 검색(`include_sublocations`)은 재귀 CTE 대신 반복 조회입니다.
위치 트리는 작고, 재귀 CTE는 SQLite 지원이 제한적이기 때문입니다.

---

## 8. 캘린더 알림

`EventReminder.scheduled_at`에 **발송 시각을 미리 계산해 저장**합니다.
스케줄러가 `scheduled_at <= now AND sent_at IS NULL` 한 번의 인덱스 범위 스캔으로
발송 대상을 찾습니다. 매번 `starts_at - offset`을 계산했다면 인덱스를 못 씁니다.

일정 시각이 바뀌면 리마인더를 전부 다시 만듭니다(`_set_reminders(replace=True)`).

알림은 **`notifications` 행이 원본**이고, 푸시는 그 위의 best-effort 미러입니다.
푸시 실패가 요청을 실패시키지 않습니다. `FCM_SERVER_KEY`가 비어 있으면
인앱 알림만 남고 조용히 넘어갑니다.

> `app/services/scheduler.py`는 APScheduler 인프로세스 실행입니다. 자체 호스팅
> 단일 서버에는 맞지만, **워커를 여러 개로 늘리면 같은 알림이 중복 발송**됩니다.
> 그 시점에는 리더 1개만 돌리거나 외부 큐로 옮겨야 합니다.

---

## 9. 오류 규격

모든 오류가 같은 모양입니다. 클라이언트가 파서를 하나만 두면 됩니다.

```json
{ "error": { "code": "ACCOUNT_NOT_ACTIVE", "message": "관리자 승인 대기 중입니다.",
             "details": { "status": "PENDING" } } }
```

`code`는 분기용 안정 식별자, `message`는 그대로 사용자에게 보여줄 한글 문구입니다.

---

## 10. 감사로그

`audit_logs`는 **append-only**입니다(수정 컬럼 없음). 로그인/실패, 승인/반려,
설정 변경, 주요 CRUD가 기록되고 `changes`에 필드별 before/after가 들어갑니다.
비밀번호류 필드는 `audit.diff()`에서 항상 제외됩니다.

`actor_email`을 별도로 복사해 둡니다. 계정이 삭제돼도 "누가 했는지"가 남아야 하기
때문입니다.

감사 행은 **호출자의 커밋에 함께 실립니다**. 롤백된 트랜잭션의 감사 기록만
살아남는 일이 없습니다.

---

## 11. 알아둘 제약

- `Base.metadata.create_all()`이 지금의 스키마 생성 경로입니다(`main.py` lifespan).
  구조가 확정되면 이 줄을 빼고 `alembic upgrade head`로 전환하세요.
- 세션은 `autoflush=False`입니다. 방금 `add()`한 행을 집계 쿼리로 읽으려면
  명시적 `db.flush()`가 필요합니다(`_recalc_costs`가 그렇게 합니다).
- 접수번호·자산번호 채번은 행 수 카운트 기반이라 동시 삽입 시 충돌할 수 있습니다.
  실제 방어는 `ticket_no` / `asset_no`의 UNIQUE 인덱스이고,
  savepoint 안에서 다음 번호로 최대 5회 재시도합니다.
- 첨부파일은 소프트 삭제만 하고 디스크 파일은 남습니다. 정리 잡이 필요합니다.

## 12. 구 서버(CS_Record)에서 옮겨 온 규칙

회사가 쓰던 구 서버의 입력 규칙 · 재고 상태 규칙 · 통계 세는 법 · 매장 관리 방식은 `docs/LEGACY_RULES.md` 에 대응표로 정리돼 있다. 코드는 `backend/app/services/asset_rules.py`(재고 상태 13종의 규칙, 코드 항목 `extra` 에 저장) 와 `backend/app/services/ticket_rules.py`(대응 기록 검증 · 렌탈 ↔ 재고 연동) 에 모여 있고, 동작 확인은 `backend/scripts/smoke_test_legacy.py` 가 한다.
