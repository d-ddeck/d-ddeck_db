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

`dist/ddeck-server-1.0.0.run` 하나가 생깁니다. 이 파일만 미니PC 로 보내면 됩니다.

```powershell
scp dist/ddeck-server-1.0.0.run 사용자명@미니PC주소:~/
```

미니PC 에서:

```bash
chmod +x ddeck-server-1.0.0.run
sudo ./ddeck-server-1.0.0.run
```

끝입니다. 아래 "파일 옮기기" 와 "설치" 를 한 번에 처리합니다.
옵션도 그대로 전달됩니다:

```bash
sudo ./ddeck-server-1.0.0.run --port 8080 --admin it@mycompany.co.kr
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
([../docs/POSTGRES.md](../docs/POSTGRES.md) 6절에 설정 예시가 있습니다).

**PostgreSQL 실환경은 아직 검증되지 않았습니다.** 코드는 SQLite와 PostgreSQL 양쪽을
지원하도록 작성했고 마이그레이션도 두 방언을 모두 렌더링하지만, 개발 환경에
PostgreSQL이 없어 **SQLite로만 테스트했습니다.** 설치 후 한 번 확인해 주세요:

```bash
cd /opt/ddeck/backend
sudo -u ddeck .venv/bin/python -c "
from app.core.database import engine
from sqlalchemy import inspect, text
with engine.connect() as c:
    print('연결:', c.execute(text('SELECT version()')).scalar()[:40])
print('테이블:', len(inspect(engine).get_table_names()), '개 (24개여야 정상)')
"
```

**이 스크립트들은 실행 검증을 하지 못했습니다.** 개발 환경(Windows)에 우분투가 없어
문법 검사와 로직 검토만 거쳤습니다. 처음 실행할 때는 화면을 지켜봐 주시고,
중간에 멈추면 그 메시지를 알려주시면 바로 고치겠습니다.
