# Windows PC 를 서버로 설정

Windows PC 한 대를 d-ddeck DB 서버로 만듭니다.
우분투 서버는 [README.md](README.md) 를 보세요.

---

## 설치

**관리자 권한 PowerShell** 에서 (시작 메뉴 → PowerShell 마우스 오른쪽 → "관리자 권한으로 실행"):

```powershell
cd C:\Users\kmean\OneDrive\Desktop\d-ddeck_db
.\deploy\install-windows.ps1
```

10~15분 후 접속 주소와 관리자 비밀번호가 출력됩니다.

```
  설치 완료

클라이언트에서 입력할 서버 주소
    http://192.168.0.20:8000

최고 관리자 계정
    이메일   admin@ddeck.local
    비밀번호 Kx7mQp3Rt9Wv2Nz5
    첫 로그인 시 비밀번호 변경 화면이 강제로 뜹니다.
    이 비밀번호는 다시 표시되지 않습니다. 지금 기록해 두세요.
```

### 옵션

```powershell
.\deploy\install-windows.ps1 -Port 8080                    # 8000 이 이미 쓰일 때
.\deploy\install-windows.ps1 -Database postgres            # PostgreSQL 사용
.\deploy\install-windows.ps1 -AdminEmail it@company.co.kr  # 관리자 이메일
.\deploy\install-windows.ps1 -Uninstall                    # 제거 (데이터 보존)
.\deploy\install-windows.ps1 -Uninstall -Purge             # 전부 삭제
```

`-Database` 기본값은 **auto** 입니다. PostgreSQL 서비스가 이미 있으면 그걸 쓰고,
없으면 SQLite 로 시작합니다.

### 설치되는 것

| | |
|---|---|
| 위치 | `C:\ProgramData\ddeck` |
| 실행 계정 | `SYSTEM` (로그인하지 않아도, 로그아웃해도 계속 실행) |
| 자동 시작 | 작업 스케줄러 `d-ddeck DB Server` — 시스템 시작 시 |
| 설정 | `C:\ProgramData\ddeck\backend\.env` (SYSTEM / Administrators 만 읽기) |
| 첨부파일 | `C:\ProgramData\ddeck\storage` |
| 방화벽 | 지정 포트 인바운드 허용 — **사내망(Private/Domain) 만**, 공용망은 열지 않음 |

> Windows 에는 systemd 가 없습니다. 대신 작업 스케줄러에 "시스템 시작 시
> SYSTEM 계정으로 실행" 작업을 등록해 서비스와 같은 동작을 얻습니다.

## 백업 등록 (꼭 하세요)

```powershell
.\deploy\backup-windows.ps1 -InstallTask
```

매일 새벽 3시에 DB + 첨부파일을 `C:\ProgramData\ddeck\backups` 에 30일치 보관합니다.

```powershell
.\deploy\backup-windows.ps1                              # 지금 한 번
.\deploy\backup-windows.ps1 -Restore "C:\...\ddeck_20260920_030000.zip"
```

> ⚠️ 백업이 이 PC 안에만 있으면 디스크 고장 시 같이 사라집니다.
> 이 폴더를 NAS 나 외장 디스크로도 복사하세요.

## 설치 후 반드시 할 것

**1. 절전 모드 해제** — 절전에 들어가면 서버가 멈춰 아무도 접속할 수 없습니다.

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 15
```

**2. 고정 IP** — 공유기에서 이 PC 에 DHCP 예약을 걸어주세요. IP 가 바뀌면
모든 클라이언트가 연결을 잃습니다.

**3. 클라이언트 설치 파일 재생성** — 나온 주소로 다시 만들어 배포합니다.

```powershell
.\installer\build.ps1 -ServerUrl "http://192.168.0.20:8000"
```

---

## 서비스 관리

```powershell
Get-ScheduledTask 'd-ddeck DB Server'                      # 상태
Stop-ScheduledTask 'd-ddeck DB Server'                     # 중지
Start-ScheduledTask 'd-ddeck DB Server'                    # 시작
(Get-ScheduledTaskInfo 'd-ddeck DB Server').LastRunTime    # 마지막 실행
```

**로그 보기** — 작업 스케줄러 실행이라 콘솔 출력이 남지 않습니다.
문제가 생기면 직접 띄워서 확인하세요.

```powershell
Stop-ScheduledTask 'd-ddeck DB Server'
cd C:\ProgramData\ddeck\backend
.\.venv\Scripts\uvicorn.exe app.main:app --host 0.0.0.0 --port 8000
```

**코드 갱신** — 새 코드를 받은 뒤 설치 스크립트를 다시 실행하면 됩니다.
`.env` 와 데이터는 그대로 두고 코드·의존성·스키마만 갱신합니다.

```powershell
.\deploy\install-windows.ps1
```

---

## 우분투 미니PC 와 비교

| | Windows PC | 우분투 미니PC |
|---|---|---|
| 설치 | `install-windows.ps1` | `install.sh` |
| 자동 시작 | 작업 스케줄러 (SYSTEM) | systemd |
| 재부팅 | **Windows Update 가 강제 재부팅** | 계획된 시점에만 |
| 전력 | 일반 PC — 절전 설정 필수 | 상시 가동 전제 |
| 로그 | 별도 확인 필요 | `journalctl -u ddeck -f` |

**서버로는 우분투 미니PC 쪽이 안정적입니다.** Windows Update 가 밤중에 재부팅하면
그 시간 동안 전사가 접속하지 못하고, 절전 설정을 놓치면 같은 일이 생깁니다.

Windows PC 서버가 맞는 경우:

- 미니PC 를 세팅하기 전에 **먼저 써보면서 검증**할 때
- 미니PC 고장 시 **임시 대체**
- 사내에 리눅스를 다룰 사람이 없을 때

> **서버는 한 대여야 합니다.** 우분투와 Windows 양쪽에 설치하면 데이터베이스가
> 둘로 갈라지고, 나중에 합칠 방법이 없습니다. 옮길 때는 반드시
> 이전 서버에서 백업 → 새 서버에서 복구 순서로 하세요.

---

## 검증 수준 (솔직하게)

이 스크립트는 **실행 검증을 하지 못했습니다.**

- 확인한 것: PowerShell 구문 검사 통과, `uvicorn.exe` 실행 경로 확인,
  Python 3.14 감지, 포트 점검 로직
- 확인하지 못한 것: 실제 설치 전 과정. 작업 스케줄러 등록과 방화벽 규칙 생성에
  **관리자 권한이 필요한데, 작업 환경이 일반 사용자 권한**이었습니다.
  임의로 이 PC 를 서버로 만드는 것은 네트워크를 여는 일이라 하지 않았습니다.

처음 실행할 때 화면을 지켜봐 주시고, 중간에 멈추면 그 메시지를 알려주세요.
스크립트는 단계마다 무엇을 하는지 출력하고, 실패하면 그 지점에서 멈춥니다.

되돌리기는 간단합니다:

```powershell
.\deploy\install-windows.ps1 -Uninstall
```
