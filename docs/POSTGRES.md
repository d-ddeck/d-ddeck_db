# PostgreSQL 운영

개발 기본 DB는 SQLite이며 Ubuntu 설치기는 기본으로 PostgreSQL을 구성합니다. `--sqlite`로 SQLite 설치를 선택할 수 있습니다. `DATABASE_URL` 변경만으로 기존 SQLite 데이터가 옮겨지지는 않습니다.

## 신규 PostgreSQL 서버

1. PostgreSQL에 전용 데이터베이스와 최소 권한 애플리케이션 계정을 준비합니다. DB 포트는 앱 서버에서만 접근하도록 제한합니다.
2. `backend/.env`에 `DATABASE_URL=postgresql+psycopg://사용자:비밀번호@호스트:5432/데이터베이스`를 설정합니다. 비밀번호의 URL 특수문자는 인코딩하며 `.env` 권한을 제한합니다.
3. 서버 가상환경에 `requirements.txt`를 설치하고 `python -m alembic upgrade head`, `python -m alembic check`를 실행합니다. 애플리케이션 테이블 30개와 `alembic_version`이 생깁니다.
4. 운영 설정으로 기동하여 초기 관리자 비밀번호를 변경합니다. 운영에서는 `create_all()`을 사용하지 않습니다.
5. 서비스 정의는 [설치 스크립트](../deploy/install.sh)가 기준입니다. 문서용 별도 systemd 유닛을 복사하지 않습니다.

## 검증

릴리스 CI의 `postgres-test`는 PostgreSQL 16 임시 서비스에서 빈 DB 마이그레이션, 스키마 비교, 운영 기동 시 DDL 금지, 로그인, 다운그레이드·재업그레이드를 검사합니다.

```bash
# 반드시 폐기 가능한 ddeck_test DB에서만 실행합니다.
TEST_POSTGRES_URL='postgresql+psycopg://테스트계정:비밀번호@localhost:5432/ddeck_test' \
  python scripts/test_postgres.py
```

일반 `smoke_test*.py`는 자체 임시 SQLite DB를 사용합니다. 그 결과를 PostgreSQL 통과로 해석하지 않습니다. 2026-09-26에는 공식 Ubuntu 패키지를 임시 경로에 풀어 PostgreSQL 18.6을 실행했습니다. 설치·스키마 비교·운영 기동·로그인·대응/재고/매장/통계/반복 일정 API·다운그레이드/재업그레이드, 실제 pg_dump 백업과 트랜잭션 복원이 통과했습니다. 시험 서버는 검증 후 종료했으며 운영 서버는 변경하지 않았습니다. GitHub Actions의 PostgreSQL 16 잡은 별도 CI 실행 시 검증됩니다.

## 백업·복원

`pg_dump`, `pg_restore`, `psql`을 서버와 호환되는 버전으로 설치합니다. 공통 백업 도구는 custom format dump의 목록을 검사하고 Alembic 리비전·첨부·설정을 같은 ZIP에 담습니다. 비밀번호는 프로세스 인자 대신 `PGPASSWORD` 환경으로 전달합니다.

[운영 런북](OPERATIONS.md)과 [복원 드릴](../deploy/RESTORE_DRILL.md)을 따릅니다. PostgreSQL 갱신 실패 시 자동 SQLite 롤백을 사용하지 않습니다. 서비스를 중지하고 현재 상태를 보존한 뒤 이전 dump와 동일 버전 코드를 함께 복구합니다.

## 서버 이전

- PostgreSQL → PostgreSQL: 기존 서버의 검증 백업을 새 서버에 옮기고 빈 대상 DB에 dump를 복원합니다. 첨부 저장소도 복원하고 `.env`의 호스트·경로를 변경합니다.
- Windows ↔ Ubuntu: 공통 ZIP은 양쪽에서 읽을 수 있습니다. OS의 경로와 DB URL을 새 환경에 맞게 정하며 `.env`를 무조건 덮어쓰지 않습니다.
- SQLite ↔ PostgreSQL: 파일 복사나 URL 변경으로 변환할 수 없습니다. 원본을 백업하고 별도 대상에 UUID·UTC 일시·JSON·외래 키를 보존하는 데이터 이관을 먼저 수행해야 합니다. 이 저장소의 `migrate_from_legacy.py`는 구 CS_Record 전용이며 현재 서버 DB 변환 도구가 아닙니다. 변환본에서 테이블별 건수, 첨부 해시, 계정 로그인, 재고 합계, 대응 통계가 일치하는지 확인한 뒤 접속을 전환합니다. 이종 DB 데이터 변환은 운영자가 사용하는 이관 도구로 별도 검증해야 하며 현재 설치기가 자동 수행하지 않습니다.

전환 동안 쓰기를 중지하고 기존 서버와 백업을 보존합니다. 문제가 생기면 새 서버를 중지하고 원본 서버로 연결을 돌립니다. 두 서버에 동시에 쓰지 않습니다.
