# DB 백업 후 서버 재시작

현재 Linux 설치본에서는 터미널에서 다음 명령을 실행합니다.

```bash
ddeck-restart
```

처음 관리자 비밀번호를 요청할 수 있습니다. 비밀번호는 터미널의 sudo 프롬프트에 입력합니다.

1. 서비스 설치 경로를 확인하고 관리자 인증을 받습니다.
2. SQLite 온라인 백업으로 DB를 복사하며 페이지 수 기준 진행률 게이지를 표시합니다.
3. 백업 무결성을 검사하고 `.env` 설정과 DB SHA-256을 함께 보관합니다.
4. 현재 코드와 DB 구조가 맞는지 검사합니다.
5. 앞 단계가 모두 성공한 경우에만 `sudo systemctl restart ddeck`을 실행합니다.
6. 최대 30초 동안 서비스 활성 상태와 `127.0.0.1:8000/healthz` 응답을 확인합니다.

`100%`는 DB 복사 완료를 뜻합니다. 뒤이어 무결성 검사와 재시작이 진행됩니다. DB가 작으면 게이지가 빠르게 완료됩니다. DB 변경(마이그레이션)은 자동 실행하지 않습니다. 구조가 맞지 않으면 백업 후 중단하고, 기존 서버는 재시작하지 않습니다.

## 백업 위치 및 범위

`~/.local/share/ddeck-backups/restarts/restart-날짜-시각/`

- `ddeck.db`: SQLite 스냅샷. 계정, 대응 기록, 견적 PDF 등 DB에 저장된 내용
- `backend.env`: 서버 설정
- `manifest.json`: 원본 DB 경로, 백업 시각, SHA-256

백업 폴더는 0700, DB와 설정은 0600 권한입니다. 실행할 때마다 새 폴더를 만들며 자동 삭제하지 않습니다. 업로드 첨부파일 디렉터리는 이 명령의 백업 범위에 포함되지 않습니다. DB 스냅샷 이후 재시작 전까지 발생한 변경은 다음 백업 대상입니다.

## 백업만 확인

```bash
ddeck-restart --backup-only
```

서버를 재시작하지 않으며 sudo 인증도 요청하지 않습니다.

현재 등록된 `ddeck.service`, 프로젝트의 `backend/.env`, 파일 기반 SQLite 및 8000 포트 환경용 명령입니다. `sudo systemctl restart ddeck` 자체의 동작은 변경하지 않았으므로 백업하려면 위 명령을 사용하세요.

다른 체크아웃에서는 저장소 루트에서 직접 실행할 수 있습니다.

```bash
./deploy/restart-with-backup.sh
```

`ddeck-restart` 단축 명령은 현재 사용자 `~/.local/bin/ddeck-restart`에 등록했습니다. PATH에서 찾지 못하면 `~/.local/bin/ddeck-restart`로 실행합니다.
