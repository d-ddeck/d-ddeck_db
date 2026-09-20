# PostgreSQL 전환 및 배포

스켈레톤은 SQLite로 즉시 실행되지만, 운영 대상은 PostgreSQL입니다.
코드는 양쪽을 모두 지원하도록 작성되어 있어 **전환은 설정 한 줄**입니다.

> **우분투 서버라면 이 문서를 직접 따라 할 필요가 없습니다.**
> `sudo ./deploy/install.sh` 가 아래 1~4단계를 전부 자동으로 처리합니다.
> → [deploy/README.md](../deploy/README.md)
>
> 이 문서는 수동 설치나 다른 OS에 올릴 때, 그리고 스크립트가 무엇을 하는지
> 확인할 때 참고하세요.

> ⚠️ 이 문서의 절차는 작성 환경에 PostgreSQL이 없어 **실제 실행 검증을 하지
> 못했습니다.** 코드는 이식 가능하게 작성했고 마이그레이션도 양쪽 방언을
> 렌더링하지만, 아래 4번(검증)을 반드시 수행하세요.

---

## 1. PostgreSQL 설치

### Windows
[postgresql.org/download/windows](https://www.postgresql.org/download/windows/)
설치 관리자 실행 (PostgreSQL 16 이상 권장).

### Ubuntu
```bash
sudo apt update && sudo apt install -y postgresql postgresql-contrib
sudo systemctl enable --now postgresql
```

### Docker (가장 간단)
```bash
docker run -d --name ddeck-db \
  -e POSTGRES_USER=ddeck \
  -e POSTGRES_PASSWORD=<강한-비밀번호> \
  -e POSTGRES_DB=ddeck \
  -e TZ=UTC \
  -p 5432:5432 \
  -v ddeck-pgdata:/var/lib/postgresql/data \
  postgres:16
```

---

## 2. 데이터베이스와 계정 생성

```sql
CREATE USER ddeck WITH PASSWORD '<강한-비밀번호>';
CREATE DATABASE ddeck OWNER ddeck ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE ddeck TO ddeck;
```

> 애플리케이션은 모든 시각을 UTC로 저장합니다. 서버 타임존은 UTC로 두고
> 표시만 클라이언트에서 `Asia/Seoul`로 변환하세요.

---

## 3. 애플리케이션 설정

`backend/.env` 에서 한 줄만 바꿉니다.

```dotenv
# DATABASE_URL=sqlite+pysqlite:///./ddeck.db
DATABASE_URL=postgresql+psycopg://ddeck:<비밀번호>@127.0.0.1:5432/ddeck
```

`postgresql://` 로만 적어도 `app/core/config.py`가 psycopg3 드라이버로
자동 교정합니다. 드라이버는 `requirements.txt`에 이미 포함되어 있습니다
(`psycopg[binary]`).

운영 전 함께 바꿔야 하는 값:

```dotenv
ENVIRONMENT=production
DEBUG=false
SECRET_KEY=<아래 명령으로 생성>
CORS_ORIGINS=https://your-app-domain      # 운영에서 "*" 금지
FIRST_SUPERADMIN_PASSWORD=<강한-비밀번호>
```

```bash
python -c "import secrets;print(secrets.token_urlsafe(64))"
```

---

## 4. 스키마 생성 및 검증

### 스키마

```bash
cd backend
python -m alembic upgrade head
```

현재 `app/main.py`의 lifespan에도 `Base.metadata.create_all()`이 남아 있습니다.
Alembic으로 전환할 때 그 줄을 제거하세요 (`main.py`에 주석으로 표시해 뒀습니다).

### 검증 (필수)

```bash
python scripts/smoke_test.py
```

> 주의: 이 스크립트는 **자체적으로 임시 SQLite 파일을 사용**하도록 되어 있습니다
> (파일 상단에서 `DATABASE_URL`을 덮어씀). PostgreSQL에 대해 돌리려면 그
> `os.environ["DATABASE_URL"] = …` 줄을 **테스트 전용 PostgreSQL DB**로 바꾸고
> 실행하세요. 운영 DB를 가리키면 안 됩니다 — 데이터를 생성합니다.

139개 검사가 모두 통과하면 방언 차이(타임스탬프, JSON, 날짜 집계)가
정상 동작하는 것입니다.

### 초기 데이터

```bash
python scripts/seed_demo.py      # 데모 데이터 (운영에서는 실행하지 말 것)
```

운영에서는 서버 최초 기동 시 `app/services/bootstrap.py`가
최고관리자 · 기본 설정 · 분류 코드 · 게시판 · 전사 캘린더를 자동 생성합니다.

---

## 5. 방언 차이가 실제로 나타나는 지점

전환 후 문제가 생긴다면 아래 4곳을 먼저 보세요.

| 파일 | 내용 |
|---|---|
| `app/models/base.py` `UTCDateTime` | 타임존 정규화 (SQLite는 tz 미저장) |
| `app/models/base.py` `JSONType` | PostgreSQL에서 JSONB로 렌더링 |
| `app/services/stats.py` `resolution_minutes_expr()` | 처리시간 계산 문법 |
| `app/services/stats.py` `period_expr()` | 일/주/월 버킷팅 문법 |

**주 단위 추이만 완전히 동일하지 않습니다.** PostgreSQL은 ISO 주(`IYYY-"W"IW`),
SQLite는 월요일 기준 `%W`를 사용합니다. 차트 형태에는 영향이 없지만 주차 번호를
문서에 인용한다면 확인이 필요합니다.

---

## 6. 운영 실행

### systemd (Ubuntu)

`/etc/systemd/system/ddeck.service`:

```ini
[Unit]
Description=d-ddeck DB Server
After=network.target postgresql.service

[Service]
Type=simple
User=ddeck
WorkingDirectory=/opt/ddeck/backend
Environment="PATH=/opt/ddeck/backend/.venv/bin"
ExecStart=/opt/ddeck/backend/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now ddeck
```

### 워커 수에 대한 경고

`--workers 2` 이상으로 올리기 전에 반드시 읽으세요.

캘린더 리마인더 스케줄러(`app/services/scheduler.py`)는 **APScheduler 인프로세스**
실행입니다. 워커를 여러 개 띄우면 **같은 알림이 워커 수만큼 중복 발송**됩니다.

선택지:
- 단일 워커로 운영 (사내 규모라면 대개 충분)
- 워커에서는 `SCHEDULER_ENABLED=false`로 끄고, 스케줄러 전용 프로세스를 하나만
  띄우거나 cron에서 `POST /calendar/reminders/run`을 주기 호출
- 외부 큐(Celery / RQ)로 이전

### 리버스 프록시 (nginx)

```nginx
server {
    listen 80;
    server_name ddeck.company.local;
    client_max_body_size 30M;          # 첨부파일 한도(25MB)보다 크게

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

`X-Forwarded-For`를 넘겨야 감사로그에 프록시 IP 대신 실제 접속 IP가 남습니다
(`app/core/deps.py`의 `client_info`가 이 헤더를 먼저 봅니다).

HTTPS는 사내망이라도 적용을 권장합니다 — 로그인 비밀번호와 토큰이 평문으로
흐르지 않게 됩니다. 사설 CA 또는 Let's Encrypt(DNS 챌린지)를 사용하세요.

---

## 7. 백업

데이터는 두 곳에 있습니다. **둘 다 받아야 복구됩니다.**

```bash
# 1) 데이터베이스
pg_dump -U ddeck -Fc ddeck > /backup/ddeck_$(date +%F).dump

# 2) 첨부파일 (DB에는 경로만 저장됨)
tar czf /backup/storage_$(date +%F).tar.gz /opt/ddeck/backend/storage
```

복원:

```bash
pg_restore -U ddeck -d ddeck --clean /backup/ddeck_2026-09-20.dump
tar xzf /backup/storage_2026-09-20.tar.gz -C /
```

---

## 8. 전환 체크리스트

- [ ] PostgreSQL 설치 및 `ddeck` DB / 계정 생성
- [ ] `.env`의 `DATABASE_URL` 변경
- [ ] `SECRET_KEY` 재생성, `DEBUG=false`, `CORS_ORIGINS` 화이트리스트 지정
- [ ] `alembic upgrade head` 실행
- [ ] `main.py`의 `create_all()` 제거
- [ ] 테스트 DB에 대해 `smoke_test.py` 통과 확인 (139/139)
- [ ] 최고관리자 최초 로그인 후 비밀번호 변경
- [ ] 워커 수 = 1, 또는 스케줄러 분리
- [ ] nginx + HTTPS + `X-Forwarded-For`
- [ ] DB / storage 백업 cron 등록
