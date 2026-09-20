# d-ddeck DB Server

사내 통합 DB 서버. FlutterFlow 기반 크로스 플랫폼 클라이언트(Windows / Linux / Android)가
공통으로 사용하는 REST API 백엔드입니다.

```
회원가입  →  관리자 승인  →  로그인  →  서버 이용
```

| 모듈 | 내용 | prefix |
|---|---|---|
| 인증 | 가입 · 승인 · 로그인 · 토큰 · 세션 · 기기 등록 | `/auth`, `/users` |
| 서비스(AS) | 접수 · 처리 이력 · 부품 · **자동 통계** | `/service` |
| 재고관리 | 자산 등록 · 위치 트리 · 이동 이력 | `/inventory` |
| 게시판 | 게시판별 설정 · 게시글 · 댓글 | `/board` |
| 캘린더 | 일정 공유 · 참석자 · 알림 | `/calendar` |
| 관리기능 | **모듈별 설정창** · 분류 코드 · 부서 · 감사로그 · 서버 상태 | `/admin` |
| 첨부 | 공통 파일 업로드 / 다운로드 | `/files` |

스택: **FastAPI + SQLAlchemy 2.0 + Alembic**, 개발은 SQLite, 운영은 PostgreSQL.

---

## 빠른 시작

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate          # Linux: source .venv/bin/activate
pip install -r requirements.txt

copy .env.example .env          # Linux: cp .env.example .env
python scripts/seed_demo.py     # 데모 데이터 (선택)

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

- API 문서(Swagger): http://127.0.0.1:8000/docs
- OpenAPI JSON: http://127.0.0.1:8000/openapi.json

첫 실행 시 `.env`의 `FIRST_SUPERADMIN_*` 값으로 최고관리자가 자동 생성되고,
5개 모듈의 기본 설정·분류 코드·게시판·전사 캘린더·기본 위치가 함께 시드됩니다.

> **최초 로그인 후 반드시 비밀번호를 변경하세요.** 부트스트랩 계정은
> `must_change_password=true`로 생성되며, `.env`의 `SECRET_KEY`도 운영 전에 교체해야 합니다.
> ```bash
> python -c "import secrets;print(secrets.token_urlsafe(64))"
> ```

### 데모 계정 (`seed_demo.py` 실행 시)

| 계정 | 권한 | 비밀번호 |
|---|---|---|
| `admin@ddeck.local` | SUPERADMIN | `admin1234` |
| `seojun.kim@ddeck.local` | ADMIN | `demo1234` |
| `hayun.lee@ddeck.local` | MANAGER | `demo1234` |
| `dohyun.park@ddeck.local` | MEMBER | `demo1234` |
| `newbie@ddeck.local` | (승인 대기) | `demo1234` |

데모 데이터: 최근 90일 AS 60건, 자산 24건, 위치 9단계 트리, 게시글 9건, 일정 8건.
통계 화면이 빈 상태로 보이지 않도록 의도적으로 분포를 넣었습니다.

---

## 검증

```bash
python scripts/smoke_test.py
```

임시 SQLite 파일에 대해 진입 흐름부터 5개 모듈 전체를 왕복하는 **139개 검사**를 돌립니다.
실패 시 첫 실패 지점에서 종료 코드 1로 멈춥니다.

```bash
python -m ruff check app scripts --select F,E9
```

---

## 문서

| 문서 | 대상 | 내용 |
|---|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 백엔드 | 데이터 모델과 설계 결정의 이유 |
| [docs/FRONTEND_BRIEF.md](docs/FRONTEND_BRIEF.md) | 프론트엔드 외주 | API 계약, 화면별 호출 순서, 주의사항 |
| [deploy/README.md](deploy/README.md) | 운영 | **우분투 미니PC 서버 설치 (설치 스크립트)** |
| [docs/POSTGRES.md](docs/POSTGRES.md) | 운영 | PostgreSQL 전환 및 수동 배포 |
| [docs/openapi.json](docs/openapi.json) | 프론트엔드 외주 | 70 paths / 101 operations |

스펙 변경 시: `python scripts/export_openapi.py`

---

## 서버 설치 (우분투 미니PC)

```bash
sudo ./deploy/install.sh
```

의존성 · PostgreSQL · `.env` · 마이그레이션 · systemd 서비스 · 방화벽을 한 번에 처리하고
접속 주소와 관리자 비밀번호를 출력합니다. 자세한 내용은
[deploy/README.md](deploy/README.md).

---

## 디렉터리

```
backend/
  app/
    core/        설정 · DB 엔진 · 보안(JWT/bcrypt) · 공통 의존성 · 에러 규격
    models/      SQLAlchemy 모델 24개 테이블
    schemas/     Pydantic 요청/응답 스키마
    api/v1/      모듈별 라우터
    services/    감사로그 · 알림 · 통계 · 설정 · 부트스트랩 · 스케줄러
  alembic/       마이그레이션
  scripts/       smoke_test / seed_demo / export_openapi
  storage/       첨부파일 (DB에는 경로만 저장)
app/             Flutter 클라이언트 (Windows / Linux / Android)
deploy/          우분투 서버 설치 · 갱신 · 백업 · 제거 스크립트
docs/
```

---

## 현재 범위

**동작하는 것**

- 진입 흐름 전체 (가입 → 승인/반려 → 로그인 → 토큰 갱신 → 세션 관리)
- 4단계 권한(MEMBER / MANAGER / ADMIN / SUPERADMIN)과 권한 상승 방지
- 계정 정지 시 기존 액세스 토큰 즉시 무효화
- 5개 모듈 CRUD + 모듈별 설정창 + 분류 코드 마스터
- AS 자동 통계 (요약 / 9개 축 분류별 집계 / 일·주·월 추이)
- 자산 위치 트리와 전체 이동 이력
- 일정 등록 → 참석자 알림 → 예약 시각 리마인더 발송
- 전 변경 이력 감사로그, 서버 상태·통계 화면

**아직 없는 것 (상세 기획 단계에서 붙일 것)**

- FCM 실제 발송 — `app/services/notifications.py`의 `send_push()`가 로그만 남기는
  어댑터 스텁입니다. Firebase 프로젝트가 생기면 이 함수 하나만 교체하면 됩니다.
- 반복 일정(RRULE) 전개 — 문자열은 저장되지만 개별 반복 인스턴스로 펼치지 않습니다.
- AS 부품 사용 시 재고 자동 차감 — 설정 키(`auto_deduct_parts`)와 연결 필드
  (`ServicePart.asset_id`)는 준비됐지만 차감 로직은 미구현입니다.
- 첨부파일 실제 삭제 — 소프트 삭제만 하고 디스크 파일은 남습니다(정리 잡 필요).
- PostgreSQL 실환경 검증 — 이 환경에 PostgreSQL이 없어 **SQLite로만 테스트했습니다.**
  포팅 가능하도록 짰고 마이그레이션도 양쪽 방언을 렌더링하지만,
  운영 DB 연결 후 `smoke_test.py`를 한 번 더 돌려 확인해야 합니다.

---

## 클라이언트 측 제약 (프론트 외주에 전달 필요)

**FlutterFlow의 빌드 타겟은 Web / iOS / Android 뿐입니다.** Windows·Linux 데스크톱
앱은 FlutterFlow에서 직접 빌드할 수 없고, 코드 익스포트(유료 플랜) 후 로컬에서
`flutter build windows` / `flutter build linux`로 빌드해야 합니다.

백엔드는 세 플랫폼이 동일한 REST API를 쓰므로 영향이 없지만,
프론트 작업 착수 전 **코드 익스포트 전제**를 반드시 합의해야 합니다.
자세한 내용은 [docs/FRONTEND_BRIEF.md](docs/FRONTEND_BRIEF.md)를 참고하세요.
