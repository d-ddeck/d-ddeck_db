# Google Drive 자동 백업

관리자/최고관리자는 **관리 → 기능 설정 → Google Drive 자동 백업**에서 설정합니다.

1. Google Cloud 프로젝트에서 **Google Drive API**를 사용 설정합니다.
2. OAuth 동의 화면을 설정하고 **웹 애플리케이션** 유형의 OAuth 클라이언트를 생성합니다.
3. 승인된 리디렉션 URI에 `https://서버주소/api/v1/admin/drive-backup/callback`을 등록합니다. 이 주소는 Google 로그인을 진행하는 PC/휴대폰의 브라우저에서 접근 가능해야 합니다. 로컬 PC 테스트만 `http://localhost:8000/api/v1/admin/drive-backup/callback`을 사용할 수 있습니다. 휴대폰의 localhost는 서버 PC가 아닙니다.
4. 앱의 **OAuth 앱 설정**에 클라이언트 ID, 보안 비밀번호, 동일한 콜백 주소를 입력합니다. 보안 비밀번호는 저장 후 화면/API에 다시 반환되지 않습니다.
5. **Google 계정 연결**에서 로그인하고 Drive 파일 권한을 허용합니다. 앱으로 돌아오면 10초 이내 상태가 갱신됩니다.
6. **지금 백업**으로 최초 백업 성공을 확인한 뒤 **매일 자동 백업**을 켜고 시간을 선택합니다. 시간은 한국 표준시(Asia/Seoul), 기본 선택값은 03:00입니다. 최초에는 자동 백업이 꺼져 있습니다.

서버의 `SCHEDULER_ENABLED=true`가 필요합니다. 앱을 종료해도 서버가 실행 중이면 예약 백업을 수행합니다. 서버가 꺼져 실행 시각을 놓친 경우 다음 기동 시 한 번 실행합니다. 실패 내용과 마지막 성공 시각을 화면에 표시하며, 실패 후 다음 일일 예약 또는 **지금 백업**으로 재시도합니다. 여러 서버 프로세스가 같은 백업 폴더를 사용하면 하나의 작업만 실행됩니다.

## 계정 변경 / 연결 해제

**연동 계정 변경**을 누르고 새 Google 계정을 선택합니다. 새 연결이 성공하기 전에는 기존 연결을 유지합니다. 취소/인증 실패 시 기존 계정이 유지됩니다. 백업 실행 중에는 계정 변경을 막습니다. 변경 후 다음 백업부터 새 계정의 새 폴더에 저장되며 기존 파일은 이전 계정에 그대로 남습니다.

**연결 해제**는 서버에 저장된 계정 토큰을 제거하고 자동 백업을 중지합니다. 드라이브의 파일을 삭제하지 않습니다. Google 측 앱 권한도 철회하려면 Google 계정의 서드 파티 연결 관리에서 제거할 수 있습니다. OAuth 앱 자격 증명을 교체하려면 연결 해제 후 **OAuth 앱 설정**을 이용합니다.

## 저장 내용과 복구

- 위치: 연결 계정의 **내 드라이브 → D.DDECK 자동 백업** 폴더.
- 내용: SQLite 온라인 백업 또는 PostgreSQL dump, 첨부파일 저장소, 파일 체크섬 manifest.
- 서버 `.env`, 운영 설정 파일, Google 인증정보는 클라우드 ZIP에 포함하지 않습니다. 재설치/복구 시 서버 환경설정은 별도로 준비해야 합니다.
- DB/압축 파일을 검사한 뒤 분할 업로드하며 Drive의 파일 크기와 MD5 체크섬을 확인한 경우에만 성공으로 기록합니다.
- Drive의 파일은 자동 삭제하지 않습니다. 저장 용량이 부족하면 용량을 확보한 뒤 재시도합니다. 서버의 `drive_*.zip`은 최근 7개를 유지하며 기존 `ddeck_*.zip` 로컬 백업과 별도로 관리합니다.
- 복구는 기존 `deploy/backup_bundle.py --extract 백업.zip --destination 복구폴더`로 체크섬을 검증하고 추출한 뒤 기존 서버 복구 절차를 따릅니다. 복구 중 서버는 중지해야 합니다.
- Google 자격 증명/예약 상태는 `backups/.drive-private/state.db`에 서버 전용 권한으로 저장됩니다. Windows에서는 서버 계정만 해당 디렉터리에 접근하도록 NTFS 권한을 설정하세요. 이 파일은 코드 저장소와 클라우드 ZIP에서 제외됩니다.
- 서버가 백업 생성 중 비정상 종료되어 기존 `.backup.lock`이 남으면 백업 프로세스가 없는지 확인 후 잠금을 제거해야 합니다. 업로드 작업 잠금은 최대 3시간 후 만료됩니다.

Google OAuth 앱을 외부 사용자 **테스트** 상태로 유지하면 Drive 권한의 refresh token은 일반적으로 7일 후 만료됩니다. 지속적인 운영은 조직 내부 앱 또는 적절히 게시한 OAuth 앱으로 설정해야 합니다.

공식 문서: [Google 서버 OAuth](https://developers.google.com/identity/protocols/oauth2/web-server), [Drive 파일별 권한](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [분할 업로드](https://developers.google.com/workspace/drive/api/guides/manage-uploads).
