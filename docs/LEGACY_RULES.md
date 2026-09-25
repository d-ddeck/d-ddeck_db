# 구 서버(CS_Record) 정리 방식 → 신 서버 반영표

회사가 쓰던 구 서버(`dddeckservercode/code`, Flask, v1.58.1)의 **정리 방식**(입력 규칙 · 재고 상태 규칙 · 통계 세는 법 · 매장 관리)이 신 서버(FastAPI)에 어떻게 옮겨졌는지 한 장으로 정리한다. 자료 자체는 2026-09-21 에 이관됐고(`backend/scripts/migrate_from_legacy.py`), 이 문서는 그 뒤 2026-09-25 에 옮긴 **규칙**을 다룬다.

규칙은 코드 마스터(`ASSET_STATUS` 항목의 `extra`)와 모듈 설정에 들어 있어 관리 화면에서 바꿀 수 있다. 기본값은 구 서버와 같다.

## 1. 대응 기록 (구 `records` → `service_tickets`)

| 구 서버 규칙 | 신 서버 | 어디 |
|---|---|---|
| 브랜드 → 매장 선택, 매장 필수 | `store_id` (브랜드는 매장에서 따라옴). 표시용 `customer_name` 은 매장 이름 | `POST/PATCH /service/tickets` |
| 서비스구분 1 필수, 최대 10쌍(구분·세부분류·제조사) | `causes: [{category_id, symptom_id, maker_id}]` 최대 `max_causes`(10). 첫 항목이 대표 분류 | `ticket_rules.validate_causes` |
| 세부분류는 그 구분에 딸린 것만 | 증상(`SERVICE_SYMPTOM`)의 `parent_id` 가 그 구분이어야 함 → `SYMPTOM_MISMATCH` | |
| 로봇팔·제어박스·전동 그리퍼는 제조사 필수 | 설정 `SERVICE.maker_required_categories`. 제조사는 `ASSET_MAKER` 중 같은 이름 종류의 하위 → `MAKER_REQUIRED` / `MAKER_MISMATCH` | |
| 대응인원(여러 명) | `responder_ids` → `service_ticket_responders` | |
| 종결에는 대응일·대응 내용·대응인원 | `POST /status COMPLETED`: `result_note` (설정 `require_result_note`), 대응인원 (설정 `require_responder_on_complete`), `completed_at`(대응일, 비우면 지금) | |
| 렌탈 O 면 종류·시리얼·회수 예정일 필수 | `is_rental`, `rental_type_id`, `rental_serials`, `rental_due_date` → `RENTAL_*_REQUIRED` | `ticket_rules.validate_rental` |
| 렌탈 시리얼은 재고 S/N 만 | 설정 `rental_serial_must_exist` → `RENTAL_SERIAL_UNKNOWN` (details.missing) | |
| 회수 O 면 실제 회수일 | `rental_returned` → `rental_return_date` 필수 | |
| 렌탈 저장 → 장비 '렌탈 중', 회수 → '창고' | `ticket_rules.sync_rental_assets`: 재고 이동 이력에 `reference_type=service_ticket`. 응답 `notices` 에 안내 | |
| 검색: 연도·달·브랜드·매장·구분·세부·과실·인원·상태·렌탈·내용 | `GET /service/tickets` 의 `year, month, brand_id, store_id, category_id, symptom_id, maker_id, fault_id, responder_id, status/only_open, is_rental, rental_unreturned, q` (통계·엑셀도 같은 조건) | `service.ticket_filters` |
| 접수·종결·미종결 요약 | `GET /service/stats/summary` 를 같은 조건으로 | |
| 엑셀 내려받기 | `GET /service/tickets/export.xlsx` (열 구성 동일: 서비스구분 n · 세부분류 n · 제조사 n …) | |
| 댓글 | `POST /service/tickets/{id}/logs` (작성자 표시, 최근 수정 시각 갱신) | |
| 대시보드(미종결·렌탈 D-day·최근·연도별) | `GET /service/dashboard` | |

## 2. 재고 (구 `assets` → `assets` + `ASSET_STATUS` 코드)

상태 13종은 `ASSET_STATUS` 코드 항목이고, 항목마다 `extra` 에 규칙이 있다 (`backend/app/services/asset_rules.py`):

| 규칙 | 상태 | 뜻 |
|---|---|---|
| `store` | 설치 · 렌탈 중 | 매장 필수(`STORE_REQUIRED`). 우리 위치는 비움 |
| `as` | AS 대기 · AS 반출 | 매장에 둔 채 상태만 바뀜 (매장 재고에서 빠지지 않음) |
| `clear` | 창고 · 사무실 · 미상 | 매장·세트 자동 비움. `place` 이름의 위치로 (미상은 위치 없음, LOST) |
| `free` | 바른/자담/삼성/해외/기타 회수 · 폐기 | 매장 비움, 위치는 요청대로 |

`Asset.status`(6종 enum)는 세부 상태에서 유도된다(`extra.enum`). 상태 없이 자리만 옮기면 자리에 맞는 상태를 서버가 고른다(매장 → 설치, 창고 위치 → 창고, 매장을 떠나면 → 창고).

| 구 서버 | 신 서버 |
|---|---|
| UNIQUE(kind, serial) | 같은 종류 안 S/N 중복 → `SERIAL_TAKEN`(409), 대소문자 무시 |
| 로봇팔·제어박스·전동 그리퍼 제조사 필수 | 설정 `INVENTORY.maker_required_categories` → `MAKER_REQUIRED` |
| 입고·등록에 S/N 여러 개 | `POST /inventory/assets/bulk` (`serial_nos`, 중복은 `duplicates` 로) |
| 여러 대 한 번에 옮기기 | `POST /inventory/assets/bulk-move` (`moved / skipped / errors`) |
| 재고 현황(상태×종류 · 브랜드×종류 · 장소×종류 · AS/미상 확인 · 렌탈 중 D-day) | `GET /inventory/overview` |
| 종류 탭 위치 구분 | `GET /inventory/assets?category_id&brand_id | location_id&at_store` |
| 엑셀(요약 + 종류별 시트) | `GET /inventory/assets/export.xlsx` |
| 설치일 | `Asset.purchase_date` (이관 때 그렇게 옮겨짐) |
| 비전동 그리퍼 관리 번호 NG-0001 … | 설정 `INVENTORY.nonelectric_serial_prefix`, 매장 장비 설정에서 자동 |

## 3. 매장 (구 `stores`, `store_sets`, `store_equipment`)

| 구 서버 | 신 서버 |
|---|---|
| 폐점 저장 → 설치 장비를 회수 위치로 (브랜드 회수 / 창고 / 사무실). 렌탈 중은 안 옮김 | `POST /stores/{id}/close` (`recover_to_status_item_id`), 또는 `PATCH is_closed=true` + `recover_to_status_item_id`. 상세의 `recover_options`(첫 항목 기본) · `movable_count` · `rental_count` 로 확인 문구 |
| 매장 장비 설정(세트마다 로봇팔·제어박스·그리퍼·툴체인저 S/N) | `POST /stores/{id}/equipment`: 없는 S/N 등록, 다른 곳 장비 이동, 있으면 세트만, 비전동 세트 S/N 없으면 NG 번호 |
| 세트 이름·추가·삭제 | `POST/PATCH/DELETE /stores/{id}/sets[/{no}]` (장비 있는 세트는 삭제 불가) |
| 매장 화면: 서비스구분별 발생 · 미회수 렌탈 · 대응 이력 · 첫 설치일 | `GET /stores/{id}` 의 `category_counts`, `unreturned_rentals`, `recent_tickets`, `install_date`, `open_ticket_count` |
| 매장 검색·폐점 포함 | `GET /stores?q&include_closed` |

## 4. 통계 (구 `stats_tab`)

- 분류 축은 **원인 행**을 센다. 한 건에 구분이 셋이면 세 칸에 각각 1. 화면은 옆에 중복 뺀 **대응 건수**를 같이 보여 준다. 비율의 분모는 원인 총수.
- 서비스구분 탭(`category_id` 필터)은 **그 구분의 원인 행만** 본다.
- 연도는 한국 시각 기준.

| 구 서버 표 | 신 서버 |
|---|---|
| 연도별 발생 빈도 (원인 수 · 대응 건수 · 비율) | `GET /service/stats/crosstab?rows=year&cols=category` 의 행 합계 |
| 연도별 브랜드별 / 연도별 매장별(차트) | `crosstab?rows=brand|store&cols=year` |
| 브랜드별·매장별 세부 구분별 | 메인 `cols=category`, 구분 탭 `cols=symptom&category_id=` |
| 제조사별 연도별 · 세부 구분별 | `rows=maker` |
| 연도별 운영 매장 · 브랜드별 운영 매장 | `GET /service/stats/store-years` |
| 표마다 엑셀 | `GET /service/stats/crosstab.xlsx?rows&cols&…` |
| 숫자를 누르면 그 건들의 목록 | 목록 필터 `year, brand_id, store_id, category_id, symptom_id, maker_id` |
| 축 하나짜리 집계 | `GET /service/stats/grouped?group_by=…` (`responder` 추가) · `trend?interval=year` |

## 5. 캘린더

한국 공휴일·대체공휴일(2024~2050 음력표) → `GET /calendar/holidays?year=`. 추가 휴일은 설정 `CALENDAR.extra_holidays` (`05-01:노동절, 2028-04-12:선거`).

## 5b. 근무일지 (구 `worklogs` → `worklogs` · `worklog_drafts`, 2026-09-25 추가)

| 구 서버 | 신 서버 |
|---|---|
| 작성자·일자마다 한 장, 같은 날 두 장이면 먼저 쓴 장으로 | `POST /worklogs` → 409 `WORKLOG_EXISTS` + `details.id` |
| 직급은 계정(관리 › 사용자)의 것을 그대로, 없으면 목록에서 | `User.position` 우선, 없으면 `WORKLOG_POSITION` 코드에서 (`POSITION_REQUIRED`) |
| 요약 줄마다 1. 2. 번호 | 서버 `numbered()` 가 다시 매김 |
| 연장 근무 X 면 내용 비움, 공개 범위 기본 비공개 | 같음 (`visibility` PRIVATE/TEAM) |
| 보기: 본인·관리자, 팀 공개면 모두. 고치기·지우기: 본인·관리자 | `can_edit`, 403 |
| 임시 저장 계정당 한 장, 등록하면 삭제 | `GET/PUT/DELETE /worklogs/draft` |
| 첨부, 엑셀, 검색(연도·달·작성자·연장·내용) | `/files` entity `worklog`, `GET /worklogs/export.xlsx`, `GET /worklogs?…` |
| 글 파일(.txt) 폴더 저장 | 옮기지 않음 (첨부는 서버 저장소) |

## 6. 아직 옮기지 않은 것

- 출고 대조(게시판의 제조사 출고 엑셀 ↔ 재고) — `dddeckservercode/code/docs/디떽_출고이력.xlsx` 참고
- 매장 사진 5항목 분류(첨부는 매장 단위로만), 변경 이력 한 줄 삭제 권한(localhost 관리자), 한 계정 한 곳 로그인, 관리 › 서버 화면(백업·전원)

## 7. 동작 확인

```bash
cd backend
.venv-linux/bin/python scripts/smoke_test.py          # 전 모듈 (185)
.venv-linux/bin/python scripts/smoke_test_legacy.py   # 구 서버 규칙 (143)
```

SQLite 에서 SAVEPOINT 가 제대로 롤백되도록 `app/core/database.py` 가 pysqlite 의 BEGIN 을 끄고 직접 낸다. 접수번호·자산번호 채번(`begin_nested`)과 일괄 이동의 건별 롤백이 이것에 기댄다.
