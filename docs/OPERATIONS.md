# 운영과 장애 복구

현재 준비된 코드를 실제 서버에 배포하고 외부 서비스를 연결하는 절차입니다. 저장소에 운영 도메인, VPN 대역, Firebase 프로젝트, 원격 백업 계정, Android 서명키는 포함하지 않습니다.

## 최초 운영 준비

1. Ubuntu 서버에 설치하고 관리자 초기 비밀번호를 변경합니다. `install.sh --https`를 선택하면 설치 마지막에 도메인·CIDR·인증서 경로를 입력받습니다. Windows·Android 사용자에게는 앱을 배포합니다.
2. 도메인과 사내망/VPN CIDR을 정합니다. 인증서 fullchain과 private key를 서버에 설치합니다.
3. nginx 설치 후 `sudo /opt/ddeck/backend/.venv/bin/python /opt/ddeck/deploy/configure_https.py`로 설정을 미리 보고, `--apply`로 적용합니다. 입력은 실행 시 받거나 `--domain`, 반복 가능한 `--cidr`, `--cert`, `--key`로 지정합니다. 적용 시 nginx 구문 검사와 Uvicorn의 `127.0.0.1` 바인딩을 함께 설정합니다. 앱의 서버 URL도 `https://도메인`으로 바꿉니다.
4. 공개 신뢰 인증서를 권장합니다. 사내 CA를 사용하면 해당 CA를 OS 신뢰 저장소에 설치하고 Android 정책에 맞게 배포합니다. 앱 인증서 검증을 해제하지 않습니다.
5. `/healthz`와 관리자 서버 상태에서 DB·버전·디스크를 확인하고 로그인·첨부 업로드·다운로드를 확인합니다.

## 백업과 원격 보관

`sudo /opt/ddeck/deploy/backup.sh --install-cron`은 매일 03:00 백업과 15분 간격 상태 검사를 등록합니다. 백업 로그는 `/var/log/ddeck-backup.log`, 상태 경고는 `journalctl -t ddeck-monitor`에서 확인합니다. logrotate는 주간 8개를 보관합니다.

백업은 SQLite snapshot 또는 PostgreSQL custom dump, 첨부 저장소, `.env`, Alembic 리비전, 운영 설정 파일과 SHA-256 manifest를 ZIP에 담습니다. 임시 파일 검증 후 최종 이름으로 바꾸며, 기본 최근 7개를 보관합니다. 공간 부족이나 원격 업로드 실패 시 기존 백업을 먼저 지우지 않습니다. `.env`가 포함되므로 백업 폴더와 원격 저장소 접근을 제한합니다.

rclone을 설치하고 **전용 백업 폴더**를 준비한 뒤 서버 계정이 읽을 수 있는 rclone 설정을 배치합니다. `backend/.env`에 다음 값을 넣습니다.

```dotenv
RCLONE_REMOTE=회사백업:ddeck/전용백업폴더
# cron과 앱 수동 백업이 같은 rclone 설정을 읽도록 절대 경로 지정
RCLONE_CONFIG=/opt/ddeck/secrets/rclone.conf
```

업로드 후 `rclone check --download`로 검증하고 성공한 뒤 전용 폴더의 오래된 `ddeck_*.zip`을 정리합니다. 실패하면 `backups/LAST_FAILED`, 원격 실패는 `UPLOAD_FAILED`에 남습니다. 관리자 화면의 **지금 백업**은 `SCHEDULER_ENABLED=true`인 서버에서 실행합니다. 최근 성공이 없거나 36시간이 지나면 경고합니다. 수동 백업의 서버 계정도 PG 도구·rclone·설정 파일에 접근할 수 있어야 합니다.

## 복원과 갱신 실패

먼저 [복원 연습 절차](../deploy/RESTORE_DRILL.md)를 별도 경로에서 수행합니다. Linux와 Windows 모두 같은 ZIP을 해제·검증할 수 있으며 예전 tar.gz도 읽을 수 있습니다. OS를 바꿀 때 `.env`의 DB·첨부 경로를 새 환경에 맞게 설정합니다. `.env`를 자동 덮어쓰지 않습니다.

`update.sh`는 서비스 중지 → 검증 백업 → 이전 코드·가상환경·서비스 파일 보관 → 코드·의존성·Alembic 갱신 → 건강 검사를 수행합니다. 이전 코드는 `backups/revisions/`에 남습니다. 기존 SQLite DB가 backend 안에 있으면 검증 복사 후 data 폴더를 사용하도록 설정을 바꾸고 systemd 쓰기 경로를 제한합니다. 원래 DB는 확인용으로 남기며 새 위치에 동명 DB가 있으면 덮어쓰지 않고 중단합니다. 갱신 실패 시 기본은 서비스 중지 상태 유지입니다.

SQLite에서 `sudo ./deploy/update.sh --rollback-on-failure`를 명시하면 실패 시 이전 코드·가상환경·DB·첨부·서비스 파일로 복구합니다. PostgreSQL은 자동 되돌림을 하지 않으며 백업 dump를 수동 복원하고 해당 버전 코드로 맞춰야 합니다. 복구본도 장애가 나면 서비스를 다시 중지하고 로그를 확인합니다. 복구 후 남은 `backend.failed.*`, `backend.rollback`, `backups/revisions`는 정상 복구를 확인한 뒤 운영자가 정리합니다.

## 관리자 계정 복구

서버 콘솔에서 서비스의 Python과 설정으로 실행합니다.

```bash
cd /opt/ddeck/backend
sudo -u ddeck .venv/bin/python scripts/reset_admin.py --email 관리자이메일
sudo -u ddeck .venv/bin/python scripts/reset_admin.py --email 관리자이메일 --apply
```

첫 명령은 대상만 확인합니다. 적용 명령은 비밀번호를 화면에 표시하지 않고 두 번 입력받고, 잠금을 풀고 모든 세션·기기 등록을 해제하며 감사로그를 남깁니다. 이메일과 키 별칭은 전달해도 되지만 비밀번호·개인키를 채팅이나 명령줄 인자에 넣지 않습니다.

## Firebase 준비

Firebase 프로젝트와 Android 앱을 만든 뒤 FCM HTTP v1 사용 권한이 있는 서비스 계정 JSON을 서버의 저장소 밖 경로에 설치합니다. 서버 사용자만 읽도록 권한을 제한합니다.

```dotenv
FCM_PROJECT_ID=프로젝트ID
FCM_CREDENTIALS_FILE=/opt/ddeck/secrets/firebase-service-account.json
```

GitHub Actions 변수 `FIREBASE_PROJECT_ID`, `FIREBASE_APP_ID`, `FIREBASE_API_KEY`, `FIREBASE_SENDER_ID`는 앱의 Firebase 공개 설정입니다. 릴리스 워크플로가 dart-define으로 전달합니다. 서비스 계정 JSON은 여기에 등록하지 않습니다. Android 서명키는 [별도 절차](ANDROID_SIGNING.md)로 준비합니다.

설정이 없으면 앱 내 알림만 동작합니다. 설정 후 Android 로그인 → 알림 권한 허용 → 관리자 기기 등록 확인 → 테스트 일정 알림 → 세션 종료 후 수신 중지를 확인하세요. 발송 실패는 최대 8회까지 재시도하며 토큰·본문·서비스 키를 로그로 출력하지 않습니다. Firebase 실발송은 네트워크와 프로젝트 권한이 갖춰진 환경에서 검증해야 합니다.

## 보존과 로그

스케줄러는 6시간마다 반복 일정을 확장하고 만료 토큰(30일), 읽은 알림(180일), 감사로그(730일), 삭제 첨부(30일)를 최대 500건씩 정리합니다. `RETENTION_*_DAYS`로 조정합니다. 미확인 알림과 살아 있는 첨부는 보존합니다.

Ubuntu는 journald, Windows 호환 서버는 설치 폴더의 `logs/server.log`에 로그를 보관하며 파일당 10MiB, 이전 파일 5개로 순환합니다. Uvicorn access log는 운영 설치에서 끕니다. 로그에 비밀번호·토큰·개인키를 추가하지 마세요. 로그 및 백업은 서버 외부에도 보관하고 주기적으로 복원 시험을 수행합니다.

## 세션·이력 정책

한 계정의 여러 기기 로그인을 허용합니다. 앱의 내 세션 화면에서 접속 상태를 확인하고 개별 세션을 즉시 종료할 수 있습니다. 비밀번호 변경·복구는 모든 세션을 종료합니다.

대응 수정 이력·재고 이동 이력 한 줄 정리는 서버 PC에서 localhost로 접속한 관리자에게만 표시하고 서버도 접속 IP를 검사합니다. 목록에서 숨기되 원본은 보존하여 렌탈 회수와 재고 계산을 바꾸지 않습니다. 별도 감사로그에 정리한 관리자를 남깁니다. 일반 처리 댓글 수정·삭제와는 별도 기능입니다.

## SECRET_KEY 교체와 구 데이터 보관

SECRET_KEY를 바꾸면 이전 JWT를 사용할 수 없어 모든 사용자가 재로그인해야 합니다. 키를 교체하기 전에 백업을 보존하고 점검 시간을 안내한 뒤 서버를 재시작합니다. 이전 백업에는 이전 키가 포함되므로 접근 권한을 제한합니다.

구 서버 원본은 Git에 포함하지 않습니다. 승인된 보관 위치의 전체 백업(cs.db, uploads/, docs/)을 작업용 별도 폴더로 복사해 `migrate_from_legacy.py --source /절대/백업경로 --dry-run`으로 먼저 검사합니다. 실제 위치·보관 책임자는 운영 인수인계의 비공개 자산 목록에 기록합니다. 운영 DB는 먼저 Alembic으로 준비합니다. 원본 DB는 읽기 전용으로 열며 dry-run은 임시 대상에서만 실행합니다. 실제 실행 뒤 사용자·대응·자산·이력 건수와 첨부를 확인하고 재실행 시 중복 행이 생기지 않는지 확인합니다. 비밀번호 해시는 이관하지 않으며 새 계정은 초기 비밀번호 변경이 필요합니다.
