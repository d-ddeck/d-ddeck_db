# d-ddeck

사내 대응 기록·재고·매장·게시판·캘린더·근무일지를 관리합니다. 클라이언트는 `app/`의 Flutter Windows·Android 앱이며, 권장 서버는 Ubuntu의 FastAPI 서비스입니다. Linux 데스크톱 앱은 개발용 빌드 대상입니다.

현재 소스 버전은 **1.0.10**입니다. [릴리즈 다운로드](https://github.com/kmeans12345-cell/d-ddeck_db/releases/tag/v1.0.10)와 [업데이트 안내](docs/releases/1.0.10.md)를 확인하세요.

실제 화면 캡처와 업무별 사용 순서는 [사용자 가이드](docs/사용자-가이드.md)를 참고하세요. [브라우저용 HTML](docs/사용자-가이드.html)과 [인쇄용 PDF](docs/사용자-가이드.pdf)도 제공합니다.

로그인 화면과 앱 상단의 화면 모드 버튼에서 시스템 설정·라이트·다크를 선택할 수 있으며, 선택은 기기에 저장됩니다. [UI 디자인 개선안](docs/UI-디자인-개선안-2026-09-26.md)에 완료된 24개 개선 항목과 실제 화면을 정리했습니다. 넓은 화면의 목록 밀도 선택, 매장 상세 탭, 통계 분류, 재조회 중 입력 보존도 지원합니다.

| 구성 | 위치 |
|---|---|
| REST API · SQLAlchemy · Alembic | `backend/` |
| Flutter 앱 | `app/` |
| Ubuntu 서버 설치 · 백업 · 갱신 | `deploy/` |
| Windows 앱 설치 패키지 · 서버 패키지 | `installer/` |
| Android 서명 준비 | [ANDROID_SIGNING.md](docs/ANDROID_SIGNING.md) |
| 운영·복구·외부 서비스 설정 | [OPERATIONS.md](docs/OPERATIONS.md) |

## 개발 실행

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
# .env의 SECRET_KEY와 최초 관리자 비밀번호를 변경합니다.
python -m alembic upgrade head
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

Windows 개발 환경은 `.venv\Scripts\Activate.ps1`로 활성화합니다. Swagger `/docs`와 `/openapi.json`은 `DEBUG=true`에서만 열립니다. 개발용 데모 생성은 `ENVIRONMENT=development`인 별도 DB에서 `python scripts/seed_demo.py`를 실행합니다. 운영 DB에는 실행하지 마세요.

```bash
cd app
flutter pub get
flutter run
```

최초 관리자는 `.env`의 `FIRST_SUPERADMIN_*` 설정으로 생성되며 첫 로그인 때 비밀번호를 변경합니다. 일반 가입자는 관리자 승인 후 사용할 수 있습니다. 여러 기기 로그인을 허용하며 계정 메뉴에서 세션을 조회·종료합니다. 매장 폐점·장비 설정은 관리자 이상이며 폐점 매장 사용은 경고 후 허용합니다.

## 배포와 운영

- Ubuntu 서버: [설치 안내](deploy/README.md)
- Windows 서버 호환 설치: [별도 안내](deploy/README-windows.md). Windows 사용자에게는 Flutter 앱 설치 파일을 배포합니다.
- PostgreSQL: [검증·운영 안내](docs/POSTGRES.md)
- 장애 복구: [복원 연습](deploy/RESTORE_DRILL.md), [운영 절차](docs/OPERATIONS.md)
- 구 서버 이관: [구 서버 규칙](docs/LEGACY_RULES.md), `backend/scripts/migrate_from_legacy.py`

운영은 Alembic으로 스키마를 관리합니다. 기존 `create_all` DB는 백업·서비스 중지 후 `scripts/adopt_schema.py`로 검증하고 `--stamp`를 적용한 다음 업그레이드합니다. 앱 시작 시 운영 테이블을 자동 생성하지 않습니다.

## 검증

```bash
cd backend
python scripts/test_migrations.py
python scripts/smoke_test.py
python scripts/smoke_test_legacy.py
python scripts/smoke_test_review.py
python scripts/smoke_test_priority2.py
python scripts/smoke_test_priority345.py
python scripts/test_legacy_history.py
python -m unittest discover -s ../deploy -p 'test_*.py'
ruff check app scripts ../deploy
cd ../app
flutter analyze
flutter test
```

테스트는 임시 DB를 사용합니다. 실제 서버를 대상으로 하는 Flutter 계약 테스트는 데모 계정이 없는 환경에서 건너뜁니다. PostgreSQL은 CI의 별도 `ddeck_test` DB로 검사합니다. FCM 실발송·원격 백업·인증서 연결은 운영 설정 후 확인해야 합니다.
