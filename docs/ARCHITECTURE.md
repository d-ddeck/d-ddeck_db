# 구조와 데이터 규약

`backend/app/api/v1`은 인증·입력 검증·응답·트랜잭션 경계를 담당합니다. 도메인 규칙과 조회 조립은 `services`에 둡니다. `app/lib/data`는 Flutter API 저장소, `models`는 응답 파서, `ui`는 화면입니다.

## 테이블 30개

| 영역 | 테이블 |
|---|---|
| 인증 | users, departments, refresh_tokens, devices |
| 공통 관리 | module_settings, code_groups, code_items, audit_logs, attachments |
| 대응 | customers, service_tickets, service_logs, service_parts, service_ticket_causes, service_ticket_responders |
| 재고 | locations, assets, asset_movements |
| 매장 | stores, store_sets |
| 게시판 | boards, posts, post_comments |
| 일정 | calendars, events, event_participants, event_reminders, notifications |
| 근무일지 | worklogs, worklog_drafts |

UUID 기본키, UTC 저장, KST 업무 날짜, VARCHAR enum을 사용합니다. SQLite에서도 FK를 활성화합니다. 삭제 대상은 `deleted_at`으로 숨기며, 첨부는 별도 보존 기간 뒤 파일과 메타데이터를 정리합니다. 감사로그는 보존 기간 안에서 유지합니다.

## 주요 공통 서비스

- `ticket_rules.py`: 원인 분류 검증, 대응 번호, 렌탈 재고 연동. `ticket_view.py`: 상세·목록 응답 조립.
- `asset_rules.py`: 상태·매장·위치 규칙. `asset_movement.py`: 변경 전후 이동 이력 형식. `inventory_view.py`: 재고 현황 조회 조립.
- `code_master.py`: 코드 그룹별 공통 조회. `settings_store.py`: 모듈 설정의 타입 변환.
- `stats.py`: 목록과 통계의 필터·KST 집계. 분류 없는 대응 건수도 별도로 반환합니다.
- `attachment_access.py`: 첨부 대상의 읽기·쓰기 권한. `attachment_lifecycle.py`, `retention.py`: 삭제 전파·보존 정리.
- `notifications.py`: DB 알림과 FCM 발송 대기열. 외부 호출은 DB 커밋 후 수행하며 재시도합니다. 프로세스 중단 시 재발송될 수 있어 payload에 notification_id를 포함합니다.
- `recurrence.py`: 일·주·월·년 RRULE을 최대 400일 앞까지 구체 일정으로 전개하고 참가자·리마인더를 복제합니다. 정기 작업이 창을 연장합니다.
- `operations.py`: 관리자 상태 조회와 수동 백업 요청. 실행 명령은 고정된 백업 도구로 제한합니다.

## 인증과 권한

Access JWT는 짧게 유지하며 세션 가족 ID를 포함합니다. 매 요청에서 계정과 세션 유효성을 확인합니다. Refresh 토큰은 사용 때 교체하고 재사용은 계정의 세션을 해제합니다. 로그아웃·세션 종료·비밀번호 변경은 관련 기기 등록도 해제합니다.

사용자 역할은 MEMBER → MANAGER → ADMIN → SUPERADMIN입니다. 매장 폐점·장비 설정은 ADMIN 이상입니다. 여러 기기 로그인을 허용합니다. 폐점 매장은 경고 후 선택할 수 있고, 비활성 매장은 기본 선택 목록에서 제외됩니다.

## 운영 경계

운영 스키마는 Alembic만 변경합니다. `/healthz`는 DB 연결을 검사하고, 상세 스키마·디스크·백업 정보는 관리자 `/admin/health`에서 제공합니다. API 문서는 `DEBUG=false`에서 비공개입니다.

설치 기본은 단일 서버·단일 스케줄러입니다. 알림 선점·발송 대기열은 조건부 UPDATE를 쓰지만, 여러 서버로 확장할 때는 작업 실행·인증 제한·백업 잠금의 공유 구성을 별도로 검증해야 합니다. 첨부와 DB가 함께 있는 검증된 ZIP 백업으로 복구합니다. 자세한 절차는 [OPERATIONS.md](OPERATIONS.md)에 있습니다.
