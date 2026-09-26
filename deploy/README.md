# 우분투 미니PC 서버 설치

사내 미니PC(우분투)를 d-ddeck DB 서버로 만드는 절차입니다.
Windows PC와 휴대폰은 이 서버에 접속하는 클라이언트로만 씁니다.

```
[우분투 미니PC]  ← 서버 (이 문서)
      ↑
  사내 네트워크
      ↑
[Windows PC들] [안드로이드 폰들]  ← 클라이언트
```

---

## 가장 간단한 방법: 설치 파일 하나

Windows PC 에서 서버용 설치 파일을 만듭니다.

```powershell
python installer/build_server_package.py
```

`dist/ddeck-server-1.0.8.run` 하나가 생깁니다. 이 파일만 미니PC 로 보내면 됩니다.

```powershell
scp dist/ddeck-server-1.0.8.run 사용자명@미니PC주소:~/
```

미니PC 에서:

```bash
chmod +x ddeck-server-1.0.8.run
sudo ./ddeck-server-1.0.8.run
```

끝입니다. 아래 "파일 옮기기" 와 "설치" 를 한 번에 처리합니다.
옵션도 그대로 전달됩니다:

```bash
sudo ./ddeck-server-1.0.8.run --port 8080 --admin it@mycompany.co.kr
```

> 프로젝트 폴더 전체가 아니라 `backend/` 와 `deploy/` 만 담기며,
> `.env` 와 데이터베이스 파일은 들어가지 않습니다.

---

## 직접 폴더를 옮기는 방법

소스를 자주 고치며 작업할 때는 이쪽이 편합니다.

### 1. 파일 옮기기

미니PC에 이 프로젝트 폴더를 통째로 복사합니다. 셋 중 편한 방법으로:

**Windows에서 scp로 (미니PC에 SSH가 켜져 있을 때)**
```powershell
scp -r C:\Users\kmean\OneDrive\Desktop\d-ddeck_db 사용자명@미니PC주소:~/
```

**USB로** — 폴더를 복사해 미니PC에 꽂고 홈 디렉터리로 옮깁니다.

**git으로** (원격 저장소를 만든 경우)
```bash
git clone <저장소주소> ~/d-ddeck_db
```

> `app/build`, `backend/.venv`, `.env` 는 옮기지 않아도 됩니다.
> 서버에는 `backend/` 와 `deploy/` 만 있으면 됩니다.

### 2. 설치

미니PC에서 **한 줄**입니다.

```bash
cd ~/d-ddeck_db
sudo ./deploy/install.sh
```

10~15분 정도 걸리며, 끝나면 **접속 주소와 관리자 비밀번호**가 화면에 나옵니다.

```
  설치 완료

클라이언트에서 입력할 서버 주소
    http://192.168.0.50:8000
    http://miniserver.local:8000      ← IP가 바뀌어도 동작 (권장)

최고 관리자 계정
    이메일   admin@ddeck.local
    비밀번호 Xk3mPq9Rt2Wv5Nz8
    첫 로그인 시 비밀번호 변경 화면이 강제로 뜹니다.
    이 비밀번호는 다시 표시되지 않습니다. 지금 기록해 두세요.
```

### 설치 옵션

```bash
sudo ./deploy/install.sh --port 8080                      # 8000이 이미 쓰이고 있을 때
sudo ./deploy/install.sh --admin it@mycompany.co.kr       # 관리자 이메일 지정
sudo ./deploy/install.sh --sqlite                         # PostgreSQL 없이 (소규모)
```

미니PC가 이미 다른 서버로 쓰이고 있다면 스크립트가 **포트 충돌을 먼저 검사하고 중단**하므로,
기존 서비스를 덮어쓸 걱정은 없습니다.

### 설치되는 것

| | |
|---|---|
| 위치 | `/opt/ddeck` |
| 실행 계정 | `ddeck` (로그인 불가한 시스템 계정) |
| 데이터베이스 | PostgreSQL (`ddeck` DB, 비밀번호 자동 생성) |
| 서비스 | `systemd` 등록 → **부팅 시 자동 시작, 죽으면 자동 재시작** |
| 설정 | `/opt/ddeck/backend/.env` (`SECRET_KEY` 자동 생성, 권한 600) |
| 첨부파일 | `/opt/ddeck/storage` |
| 이름 | avahi(mDNS)로 `호스트이름.local` 접속 가능 |

## 기존 VS Code 실행 서버를 systemctl로 관리하기

`/home/.../d-ddeck_db`에서 직접 실행하던 서버는 기존 폴더와 `.env`, DB,
첨부파일, 가상환경을 유지한 채 서비스로 등록할 수 있습니다. 신규 설치용
`install.sh`나 `/opt/ddeck` 전용 `update.sh`를 이 경로에 실행하지 마세요.

프로젝트 루트에서 먼저 서비스 설정을 미리 확인합니다(변경 없음).

```bash
python3 deploy/register_systemd.py --venv .venv-linux
```

서비스 등록은 관리자 권한으로 실행합니다. 기본 서비스 이름은 `ddeck`이며,
실행 계정은 `sudo`를 호출한 사용자입니다. 다른 계정으로 설치할 때는 기존
파일에 접근 가능한 계정을 `--user 사용자명`으로 지정하세요.

```bash
sudo python3 deploy/register_systemd.py --venv .venv-linux --install
systemctl cat ddeck
```

등록 시 `systemd-analyze verify`로 유닛을 검사한 뒤 `daemon-reload`만 실행합니다.
기존 서버 종료, DB 변경, 의존성 설치, 서비스 시작 및 자동 시작 설정은 하지 않습니다.
기존 `ddeck.service`가 다른 내용이거나 마스킹되어 있으면 덮어쓰지 않습니다.
단, 초기 등록 스크립트가 생성한 설정과 정확히 일치하면 검사 종료 코드 수정만
적용하고 기존 유닛을 `.before-schema-check-fix` 파일에 보관합니다.
같은 설정으로 재실행해도 안전합니다. 가상환경이 `.venv`라면 그 이름을 사용하세요.
한글·공백이 있는 경로를 지원하며, 프로젝트 폴더는 등록 후 이동하지 마세요.

### 기존 backend/ddeck.db 보정 및 업데이트

마이그레이션 이력이 없는 구형 DB가 `2cca8909675d` 기준과 일치하거나
`asset_movements`의 매장·상태 외래 키만 누락된 경우 다음 절차를 지원합니다.
다른 스키마 차이, 고아 참조, 중복 시리얼, 사용자 정의 트리거는 자동 처리하지 않고
중단합니다. 현재 설치의 `.venv-linux`와 `backend/ddeck.db` 전용입니다.

먼저 모든 DB 쓰기 프로세스를 종료하세요. systemd뿐 아니라 기존 VS Code에서
실행한 Uvicorn도 `Ctrl+C`로 종료해야 합니다. 작업 중 앱 접속은 중단됩니다.

```bash
cd "/home/leemoon/바탕화면/d-ddeck_db"
sudo systemctl stop ddeck
sudo python3 deploy/register_systemd.py --venv .venv-linux --install
bash deploy/migrate-existing-sqlite.sh
```

마지막 명령은 **sudo 없이** 파일 소유 계정으로 실행합니다. 설정된 DB 경로와
8000 포트 사용 여부를 검사하고, `$HOME/ddeck-backups/migration-*`에 `.env`,
첨부파일, 원본 SQLite 스냅샷을 보관합니다. 복사본에서 외래 키 보정 → 기준 스키마
검증 → 기준 revision 기록 → 최신 마이그레이션 → 전체 기존 컬럼 값·행 수·참조 무결성
검사를 수행합니다. 검증 성공 후에만 실제 DB를 교체합니다. 교체 직전 원본 데이터가
바뀌었으면 중단하며, 교체 후 스키마 검사 실패 시 원본 DB를 복원합니다.

`DB UPDATE COMPLETE`가 출력된 경우에만 시작합니다.

```bash
sudo systemctl reset-failed ddeck
sudo systemctl start ddeck
systemctl is-active ddeck
sudo journalctl -u ddeck -n 40 --no-pager
curl -fsS http://127.0.0.1:8000/
```

`active`와 서버 버전 `1.0.8`을 확인한 다음 앱에서 다시 로그인하세요.
오류가 발생하면 서비스는 중지한 채 로그를 확인하고, `stamp head`를 강제로 실행하거나
검증 표식이 없는 복사본을 복원하지 마세요. 백업에는 비밀 설정과 업무 데이터가
포함되어 있으므로 공유하지 마세요.

실제 DB 변경 없이 복사본만 검증하려면 다음처럼 별도 새 출력 폴더를 지정합니다.

```bash
backend/.venv-linux/bin/python deploy/prepare_legacy_sqlite.py \
  --database backend/ddeck.db --output "$HOME/ddeck-backups/rehearsal-new"
```

### 서비스 전환

1. DB·첨부파일·`.env`를 백업하고 해당 코드 버전에 맞는 DB 마이그레이션을
   검증·완료합니다. 스키마 이력이 없으면 `backend/alembic/README.md`의
   검증 절차가 먼저 필요하며, `stamp head`로 검증을 건너뛰지 않습니다.
2. 기존 VS Code 서버 터미널에서 `Ctrl+C`로 서버를 종료합니다.
3. `ss -ltnp 'sport = :8000'`으로 포트를 사용 중인 프로세스가 없는지 확인합니다.
4. 서비스를 시작하고 상태와 API 응답을 확인합니다.

```bash
sudo systemctl start ddeck
systemctl status ddeck --no-pager
sudo journalctl -u ddeck -n 60 --no-pager
curl -fsS http://127.0.0.1:8000/healthz
curl -fsS http://127.0.0.1:8000/
```

서비스는 시작 전 `alembic check`를 실행합니다. DB가 코드와 맞지 않거나 검사가
실패하면 **시작을 건너뛰며**, DB를 자동 수정하지 않습니다. `systemctl start`의
종료 코드만으로 성공을 판단하지 말고 `systemctl is-active ddeck`과 로그를 확인하세요.
현재 구형 DB에 마이그레이션 이력이 없고 외래 키가 누락된 경우에는 먼저 보정이
필요합니다. 서비스 등록만으로 AS 관련 장비 API의 `Not Found`가 해결되지는 않습니다.

`Target database is not up to date` 뒤에 `status=255/EXCEPTION`과 반복 재시도가
나오면 초기 서비스 검사 설정입니다. 수정된 스크립트로 다시 등록하세요.

```bash
sudo systemctl stop ddeck
sudo python3 deploy/register_systemd.py --venv .venv-linux --install
sudo systemctl reset-failed ddeck
```

검사 래퍼는 Alembic의 실패 코드(255 포함)를 ExecCondition의 1로 변환하여
재시도를 막습니다. 이것은 DB 업데이트를 대신하지 않으므로 스키마 보정 후 시작하세요.

정상 동작을 확인한 후 부팅 시 자동 시작을 켭니다.

```bash
sudo systemctl enable ddeck
sudo systemctl restart ddeck  # 재시작
sudo systemctl stop ddeck     # 중지
sudo systemctl start ddeck    # 시작
sudo journalctl -u ddeck -f   # 실시간 로그
```

서비스는 기존 가상환경에서 단일 워커로 실행하며 `.env`는 애플리케이션이 읽습니다.
VS Code 터미널에서만 지정했던 환경변수는 필요한 값을 `.env`에 반영해야 합니다.
`DEBUG`에는 `true` 또는 `false`를 사용하며 `release`는 유효하지 않습니다.
실행 계정의 홈 폴더 접근을 허용하므로, `/opt/ddeck` 신규 설치 서비스와 격리 수준은
다릅니다. 파일 소유권이나 방화벽은 이 스크립트가 변경하지 않습니다.

서비스 관리만 해제하려면 다음을 실행합니다(DB·파일은 유지됩니다).

```bash
sudo systemctl disable --now ddeck
sudo rm /etc/systemd/system/ddeck.service
sudo systemctl daemon-reload
```

## 백업 등록 (꼭 하세요)

```bash
sudo ./deploy/backup.sh --install-cron
```

매일 새벽 3시에 **데이터베이스 + 첨부파일**을 함께 받아 `/opt/ddeck/backups`에 30일치 보관합니다.

> ⚠️ 백업이 미니PC 안에만 있으면 디스크가 고장날 때 같이 사라집니다.
> `/opt/ddeck/backups` 를 NAS나 외장 디스크로도 복사하도록 설정하세요.

```bash
sudo ./deploy/backup.sh                              # 지금 한 번
sudo ./deploy/backup.sh --restore /경로/ddeck_*.tar.gz   # 복구
```

## 클라이언트 연결

Windows 앱과 안드로이드 앱의 **로그인 화면 → "서버 주소 설정"** 에 위에서 나온 주소를 입력합니다.
한 번 입력하면 저장되어 다음부터는 그냥 로그인만 하면 됩니다.

매번 입력하는 게 번거로우면 **빌드에 주소를 고정**해서 배포하세요.

```bash
flutter build windows --release --dart-define=SERVER_URL=http://miniserver.local:8000
flutter build apk --release --target-platform android-arm64 \
  --dart-define=SERVER_URL=http://miniserver.local:8000
```

> **`.local` 이름을 권장하는 이유**: 미니PC의 IP가 바뀌어도 주소를 다시 배포할 필요가 없습니다.
> 다만 일부 안드로이드 기기는 mDNS를 지원하지 않으니, 그런 경우를 대비해
> 공유기에서 미니PC에 **고정 IP(DHCP 예약)** 를 걸어두는 편이 안전합니다.

---

## 운영

```bash
systemctl status ddeck          # 상태
systemctl restart ddeck         # 재시작
journalctl -u ddeck -f          # 로그 실시간
journalctl -u ddeck --since today | grep -i error
```

**코드 갱신** — 새 코드를 미니PC에 복사한 뒤:
```bash
sudo ./deploy/update.sh
```
갱신 전 자동 백업 → 의존성 설치 → 마이그레이션 → 재시작 → 동작 확인까지 합니다.
실패하면 중단하고 로그를 보여줍니다.

**제거**
```bash
sudo ./deploy/uninstall.sh          # 서비스/코드만 (데이터 보존)
sudo ./deploy/uninstall.sh --purge  # 전부 삭제 (되돌릴 수 없음)
```

---

## 알아둘 것

**워커는 1개여야 합니다.** 일정 알림 스케줄러가 서버 프로세스 안에서 돌기 때문에,
`--workers 2` 이상으로 늘리면 **같은 알림이 워커 수만큼 중복 발송**됩니다.
systemd 유닛에 이미 단일 워커로 고정해 두었고, 그 이유도 주석으로 남겼습니다.

**HTTP는 평문입니다.** 사내망이라도 로그인 비밀번호와 토큰이 그대로 흐릅니다.
외부에서 접속하게 만들 계획이라면 nginx + HTTPS를 반드시 앞에 두세요
([운영 문서](../docs/OPERATIONS.md)의 설치 시 입력 절차를 따릅니다).

PostgreSQL 18.6 임시 서버에서 스키마·주요 API·실제 백업/복원을 검증했습니다.
CI에는 PostgreSQL 16 잡이 있습니다. 설치한 운영 환경에서도 연결과 테이블을 확인하세요:

```bash
cd /opt/ddeck/backend
sudo -u ddeck .venv/bin/python -c "
from app.core.database import engine
from sqlalchemy import inspect, text
with engine.connect() as c:
    print('연결:', c.execute(text('SELECT version()')).scalar()[:40])
print('테이블:', len(inspect(engine).get_table_names()), '개 (애플리케이션 30개 + alembic_version 1개)')
"
```

셸 구문과 격리된 갱신·백업·복원 테스트를 통과했습니다. 실제 systemd/nginx 구성,
Windows 작업 스케줄러, Android/Windows 릴리스 빌드는 해당 환경에서 확인해야 합니다.
운영 서버에 설치·갱신을 실행한 것은 아닙니다.

## 현재 운영 절차

원격 백업·HTTPS/CIDR·계정 복구·갱신 되돌림·Firebase 설정은 [운영 문서](../docs/OPERATIONS.md)를 따릅니다. Ubuntu는 서버, Windows·Android는 앱 배포 대상입니다. 신규 SQLite 설치의 DB는 `/opt/ddeck/data/ddeck.db`에 저장합니다.
