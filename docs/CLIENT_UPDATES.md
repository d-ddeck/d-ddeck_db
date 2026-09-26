# Windows·Android 실행 시 업데이트

새 기능이 포함된 클라이언트를 최초 한 번 설치하면, 다음부터 실행할 때 설정된
사내 서버에 새 버전을 확인합니다. 새 버전이 있으면 다운로드 및 설치 / 나중에를
선택할 수 있습니다. 설정 메뉴의 **업데이트 확인**에서도 다시 확인합니다.
로그인 전에도 확인할 수 있으며, 서버나 VPN이 연결되지 않으면 시작을 막지 않습니다.

다운로드 진행률, 취소, 실패 후 재시도를 지원합니다. 파일 다운로드가 끝나면
Ed25519로 서명된 배포 정보의 SHA-256·크기를 검증한 뒤 OS 설치 화면을 엽니다.
서명 공개 키는 앱에 포함되어 있어 HTTP 사내망에서도 변조된 설치 파일을 실행하지
않습니다. 강제·무인 설치는 하지 않습니다.

- Windows: 기존 설치 위치와 현재 서버 주소를 설치 프로그램에 전달합니다.
  작성 중인 내용을 저장하고 설치 안내에 따라 실행 중인 프로그램을 닫아 주세요.
  설치 완료 화면에서 프로그램을 다시 실행합니다.
- Android: 최초 설치 시 “이 출처 허용” 설정이 필요할 수 있습니다. 설정에서 허용 후
  앱으로 돌아와 **설치 계속**을 누릅니다. OS 설치 화면에서 업데이트를 승인해야 합니다.
  기존 APK와 같은 패키지 ID·릴리스 서명 키가 필요합니다. 현재 배포 대상은 arm64입니다.
  사내 APK 배포용 기능이며 Play 스토어용 배포에는 별도 업데이트 정책이 필요합니다.
- 1.0.7 및 이전 앱에는 이 기능이 없습니다. 최초 한 번 새 설치 파일로 직접 설치해야 합니다.

## 배포 흐름

1. 기존 버전 관리 절차대로 버전과 빌드 번호를 증가시키고 릴리스합니다.
2. GitHub Actions가 Windows EXE·Android APK를 빌드하고 `update-manifest.json`을 서명합니다.
3. Ubuntu 서버가 비공개 GitHub Release에서 세 파일을 받아 검증·게시합니다.
4. 앱은 GitHub 인증 정보 없이 서버의 `/api/v1/updates/latest`와 해당 파일 경로를 사용합니다.

릴리스 CI의 `UPDATE_SIGNING_KEY_BASE64` secret에는 32바이트 Ed25519 개인 키의
base64 인코딩이 필요합니다. 이 작업에서 해당 secret을 설정했습니다. 로컬 원본은
`~/.local/share/ddeck-release-signing/update-ed25519.key`에 권한 600으로 보관했습니다.
Android keystore와 다른 용도의 키입니다. 키를 교체하면 기존 앱이 서명을 신뢰하지
못하므로 임의로 재생성하지 마세요. 키 내용은 저장소·채팅·로그에 올리지 않습니다.

공개 키는 아래 두 파일에 동일하게 보관하며, CI는 개인 키와 일치하는지 검사합니다.

- `backend/app/core/update_public_key.txt`
- `app/assets/update_public_key.txt`

## 서버에 업데이트 게시

신규 API가 포함된 서버 코드를 반영하고 서비스를 재시작해야 합니다. DB 스키마
변경은 없습니다. 기존 `/home/...` 설치에서 `deploy/update.sh`는 사용하지 않습니다.

```bash
cd "/home/leemoon/바탕화면/d-ddeck_db"
sudo systemctl restart ddeck
```

서버 파일 소유 계정으로 GitHub CLI 인증을 준비합니다. GitHub 토큰은 서버에만
보관하며 앱이나 `.env`에 넣지 않습니다.

```bash
gh auth login
bash deploy/sync_client_updates.sh
```

이 명령은 GitHub의 최신 정식 릴리스를 가져옵니다. 버전을 지정할 수도 있습니다.

```bash
bash deploy/sync_client_updates.sh v1.0.8
```

**서명된 manifest를 포함한 첫 릴리스부터 사용 가능합니다.** 이전 릴리스에는 파일이
없어 동기화가 실패하며, 이미 게시된 업데이트는 유지됩니다. 기존 서명 키와 다르거나
파일 해시가 일치하지 않으면 게시하지 않습니다. 이전 버전으로 덮어쓰지도 않습니다.
업데이트 파일은 설정된 `STORAGE_DIR/client-updates`에 저장됩니다. `.env`와 업무 첨부는
업데이트 API에서 제공하지 않습니다.

GitHub CLI 대신 내려받은 세 파일을 한 폴더에 넣고 직접 게시할 수도 있습니다.

```bash
cd backend
DEBUG=false .venv-linux/bin/python ../deploy/publish_client_update.py --bundle /경로/릴리스파일
```

자동으로 새 릴리스를 게시하려면 파일 소유 계정의 `crontab -e`에 등록할 수 있습니다.
경로와 가상환경은 실제 설치에 맞추세요. 중복 실행은 `flock`으로 방지합니다.

```cron
*/10 * * * * /usr/bin/flock -n /home/leemoon/.cache/ddeck-update-sync.lock /bin/bash "/home/leemoon/바탕화면/d-ddeck_db/deploy/sync_client_updates.sh" >> /home/leemoon/ddeck-update-sync.log 2>&1
```

`gh`가 cron의 PATH에 있어야 하며, 비대화형 환경에서도 해당 계정의 GitHub 인증을
읽을 수 있어야 합니다. 로그에서 최초 동기화 성공을 확인하세요. 대용량 EXE·APK를
매번 내려받지 않도록 이미 게시된 동일 태그는 동기화 스크립트가 건너뜁니다.

## 확인과 제한

```bash
curl -fsS http://127.0.0.1:8000/api/v1/updates/latest
```

게시 전에는 404가 정상입니다. 실제 설치 성공 여부는 OS 설치 과정에서 결정됩니다.
설치 화면을 열었다는 이유로 앱이 업데이트 완료로 표시하지 않습니다. 취소 시 기존
앱을 계속 사용하고 다음 실행 또는 메뉴에서 다시 시도할 수 있습니다.
Windows 설치 동작은 Windows에서, Android 출처 허용·덮어쓰기 설치는 실제 기기에서
최종 확인해야 합니다.

구현 참고: [Ed25519 검증](https://pub.dev/documentation/cryptography/latest/cryptography/Ed25519-class.html),
[Android 설치 출처 설정](https://developer.android.com/reference/android/provider/Settings#ACTION_MANAGE_UNKNOWN_APP_SOURCES),
[Inno Setup 실행 중 앱 종료](https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm).
