<#
.SYNOPSIS
  Windows PC 를 d-ddeck DB 서버로 설정합니다.

.DESCRIPTION
  의존성 설치, 데이터베이스 준비, .env 생성, 스키마 적용, 자동 시작 등록,
  방화벽 개방까지 처리하고 접속 주소와 관리자 비밀번호를 출력합니다.

  Windows 에는 systemd 가 없으므로 작업 스케줄러에 "시스템 시작 시 SYSTEM 계정으로
  실행" 작업을 등록합니다. 로그인하지 않아도, 로그아웃해도 계속 떠 있습니다.

  여러 번 실행해도 안전합니다. 기존 .env 가 있으면 그대로 두므로 데이터와
  연결이 끊기지 않습니다.

.PARAMETER Port
  서비스 포트 (기본 8000)

.PARAMETER Database
  sqlite | postgres  (기본: PostgreSQL 이 설치돼 있으면 postgres, 없으면 sqlite)

.PARAMETER AdminEmail
  최고 관리자 이메일 (기본 admin@ddeck.local)

.PARAMETER Uninstall
  제거합니다. 데이터는 남습니다(-Purge 와 함께 쓰면 전부 삭제).

.EXAMPLE
  # 관리자 PowerShell 에서
  .\deploy\install-windows.ps1

.EXAMPLE
  .\deploy\install-windows.ps1 -Port 8080 -Database postgres -AdminEmail it@mycompany.co.kr
#>
[CmdletBinding()]
param(
  [int]$Port = 8000,
  [ValidateSet('auto','sqlite','postgres')][string]$Database = 'auto',
  [string]$AdminEmail = 'admin@ddeck.local',
  [switch]$Uninstall,
  [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$AppRoot    = 'C:\ProgramData\ddeck'
$BackendDir = Join-Path $AppRoot 'backend'
$StorageDir = Join-Path $AppRoot 'storage'
$BackupDir  = Join-Path $AppRoot 'backups'
$TaskName   = 'd-ddeck DB Server'
$FwRuleName = 'd-ddeck DB Server'
$MinPyMinor = 11

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host ""; Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------ 권한
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host ""
  Write-Host "관리자 권한이 필요합니다." -ForegroundColor Red
  Write-Host ""
  Write-Host "  시작 메뉴에서 'PowerShell' 을 마우스 오른쪽 클릭 -> '관리자 권한으로 실행'"
  Write-Host "  한 뒤 다시 실행해 주세요."
  Write-Host ""
  exit 1
}

# ------------------------------------------------------------------ 제거
if ($Uninstall) {
  Step "제거"
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Ok "자동 시작 작업 제거"
  }
  Get-Process -Name uvicorn, python -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$BackendDir*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  if (Get-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $FwRuleName
    Ok "방화벽 규칙 제거"
  }
  if ($Purge) {
    Write-Host ""
    Write-Host "경고: 데이터베이스와 첨부파일을 영구 삭제합니다." -ForegroundColor Red
    Write-Host "  계정, AS 이력, 자산, 게시글, 일정이 모두 사라집니다."
    $c = Read-Host "정말 삭제하려면 DELETE 를 입력하세요"
    if ($c -ne 'DELETE') { Die "취소했습니다." }
    if (Test-Path $AppRoot) { Remove-Item -Recurse -Force $AppRoot }
    Ok "$AppRoot 삭제"
  } else {
    if (Test-Path (Join-Path $BackendDir 'app'))    { Remove-Item -Recurse -Force (Join-Path $BackendDir 'app') }
    if (Test-Path (Join-Path $BackendDir '.venv'))  { Remove-Item -Recurse -Force (Join-Path $BackendDir '.venv') }
    Ok "코드와 가상환경 제거 (데이터는 $AppRoot 에 남아 있습니다)"
  }
  Write-Host ""
  Write-Host "제거 완료" -ForegroundColor Green
  exit 0
}

# ------------------------------------------------------------------ 사전 점검
Step "사전 점검"

$ScriptDir = $PSScriptRoot
$Src = $null
foreach ($c in @((Join-Path (Split-Path -Parent $ScriptDir) 'backend'), (Join-Path $ScriptDir 'backend'))) {
  if (Test-Path (Join-Path $c 'app')) { $Src = $c; break }
}
if (-not $Src) { Die "backend 폴더를 찾을 수 없습니다. 리포지토리 안에서 실행해 주세요." }
Ok "소스: $Src"

# 포트 충돌 - 이 PC 가 이미 다른 용도로 쓰이고 있을 수 있다.
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) {
  $owner = (Get-Process -Id $busy[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName
  Die "포트 $Port 이(가) 이미 사용 중입니다 (프로세스: $owner). -Port 로 다른 포트를 지정하세요."
}
Ok "포트 $Port 사용 가능"

# ------------------------------------------------------------------ Python
Step "Python 확보 (3.$MinPyMinor+ 필요)"
$Py = $null
foreach ($cand in @('python','python3','py')) {
  $cmd = Get-Command $cand -ErrorAction SilentlyContinue
  if (-not $cmd) { continue }
  try {
    $v = & $cmd.Source -c "import sys;print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
    if ($v -match '^3\.(\d+)$' -and [int]$Matches[1] -ge $MinPyMinor) { $Py = $cmd.Source; break }
  } catch { }
}
if (-not $Py) {
  Warn "Python 3.$MinPyMinor+ 이 없습니다. winget 으로 설치를 시도합니다."
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Die "Python 3.$MinPyMinor+ 을 python.org 에서 설치한 뒤 다시 실행해 주세요."
  }
  winget install --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
  $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('PATH','User')
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { $Py = $cmd.Source }
  if (-not $Py) { Die "설치 후에도 python 을 찾지 못했습니다. PowerShell 을 다시 열고 재실행해 주세요." }
}
Ok "Python: $(& $Py --version) ($Py)"

# ------------------------------------------------------------------ 디렉터리 / 코드
Step "설치 폴더 준비"
foreach ($d in @($AppRoot, $BackendDir, $StorageDir, $BackupDir)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# 기존 설정과 데이터는 보존하고 코드만 갱신한다.
$exclude = @('.venv','__pycache__','.env','storage','ddeck.db','ddeck.db-wal','ddeck.db-shm')
robocopy $Src $BackendDir /MIR /NFL /NDL /NJH /NJS /NP `
  /XD ".venv" "__pycache__" "storage" /XF ".env" "*.db" "*.db-wal" "*.db-shm" | Out-Null
if ($LASTEXITCODE -ge 8) { Die "코드 복사 실패 (robocopy 종료코드 $LASTEXITCODE)" }
$global:LASTEXITCODE = 0
Ok "코드 배치: $BackendDir"

# ------------------------------------------------------------------ 가상환경
Step "가상환경 구성 (몇 분 걸릴 수 있습니다)"
$VenvPy = Join-Path $BackendDir '.venv\Scripts\python.exe'
if (-not (Test-Path $VenvPy)) { & $Py -m venv (Join-Path $BackendDir '.venv') }
& $VenvPy -m pip install --quiet --upgrade pip wheel
& $VenvPy -m pip install --quiet -r (Join-Path $BackendDir 'requirements.txt')
if ($LASTEXITCODE -ne 0) { Die "의존성 설치 실패" }
Ok "의존성 설치 완료"

# ------------------------------------------------------------------ 데이터베이스
$EnvFile = Join-Path $BackendDir '.env'
$DatabaseUrl = $null
$AdminPass = $null

if (Test-Path $EnvFile) {
  Step "데이터베이스: 기존 설정 재사용"
  $line = Select-String -Path $EnvFile -Pattern '^DATABASE_URL=(.+)$' | Select-Object -First 1
  if ($line) { $DatabaseUrl = $line.Matches[0].Groups[1].Value.Trim() }
  if (-not $DatabaseUrl) { Die ".env 에 DATABASE_URL 이 없습니다. 파일을 확인해 주세요." }
  Ok "$($DatabaseUrl.Split(':')[0]) (기존 .env 에서 읽음)"
}
else {
  # 자동 판정: PostgreSQL 서비스가 있으면 postgres, 없으면 sqlite
  $pgSvc = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
  $choice = $Database
  if ($choice -eq 'auto') { $choice = if ($pgSvc) { 'postgres' } else { 'sqlite' } }

  if ($choice -eq 'postgres') {
    Step "데이터베이스: PostgreSQL"
    $psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
    if (-not $psql) {
      $found = Get-ChildItem 'C:\Program Files\PostgreSQL' -Filter 'psql.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1
      if ($found) { $psql = $found.FullName }
    }
    if (-not $psql) {
      Write-Host ""
      Write-Host "PostgreSQL 이 설치되어 있지 않습니다." -ForegroundColor Red
      Write-Host ""
      Write-Host "  winget install --id PostgreSQL.PostgreSQL.17"
      Write-Host ""
      Write-Host "  설치 중 지정한 postgres 비밀번호를 기억해 두고, 설치가 끝나면"
      Write-Host "  이 스크립트를 다시 실행해 주세요."
      Write-Host ""
      Write-Host "  지금 바로 쓰려면 SQLite 로 시작할 수도 있습니다:" -ForegroundColor Yellow
      Write-Host "    .\deploy\install-windows.ps1 -Database sqlite" -ForegroundColor Yellow
      Die "PostgreSQL 설치 후 다시 실행해 주세요."
    }
    Ok "psql: $psql"

    $pgPass = Read-Host "PostgreSQL 의 postgres 계정 비밀번호" -AsSecureString
    $pgPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pgPass))
    $env:PGPASSWORD = $pgPlain

    $dbPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    $exists = & $psql -U postgres -h 127.0.0.1 -tAc "SELECT 1 FROM pg_roles WHERE rolname='ddeck'" 2>$null
    if ($exists -eq '1') {
      & $psql -U postgres -h 127.0.0.1 -q -c "ALTER USER ddeck WITH PASSWORD '$dbPass';" | Out-Null
      Ok "기존 DB 계정 비밀번호 갱신"
    } else {
      & $psql -U postgres -h 127.0.0.1 -q -c "CREATE USER ddeck WITH PASSWORD '$dbPass';" | Out-Null
      Ok "DB 계정 'ddeck' 생성"
    }
    $dbExists = & $psql -U postgres -h 127.0.0.1 -tAc "SELECT 1 FROM pg_database WHERE datname='ddeck'" 2>$null
    if ($dbExists -ne '1') {
      # 애플리케이션은 모든 시각을 UTC 로 저장하므로 로캘은 C 로 고정한다.
      & $psql -U postgres -h 127.0.0.1 -q -c "CREATE DATABASE ddeck OWNER ddeck ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;" | Out-Null
      Ok "데이터베이스 'ddeck' 생성"
    } else { Ok "데이터베이스 'ddeck' 이미 존재" }
    # PostgreSQL 15부터 public 스키마 CREATE 권한이 기본 회수되어,
    # 이 두 줄이 없으면 마이그레이션이 permission denied 로 실패한다.
    & $psql -U postgres -h 127.0.0.1 -d ddeck -q -c "ALTER SCHEMA public OWNER TO ddeck;" | Out-Null
    & $psql -U postgres -h 127.0.0.1 -d ddeck -q -c "GRANT ALL ON SCHEMA public TO ddeck;" | Out-Null
    Ok "public 스키마 권한 부여"

    $env:PGPASSWORD = ''
    $DatabaseUrl = "postgresql+psycopg://ddeck:$dbPass@127.0.0.1:5432/ddeck"
  }
  else {
    Step "데이터베이스: SQLite"
    $sqlitePath = (Join-Path $BackendDir 'ddeck.db') -replace '\\','/'
    $DatabaseUrl = "sqlite+pysqlite:///$sqlitePath"
    Ok "경로: $sqlitePath"
    Warn "동시 사용자가 늘어나면 PostgreSQL 로 전환을 권합니다 (-Database postgres)"
  }
}

# ------------------------------------------------------------------ .env
Step "환경 설정"
if (Test-Path $EnvFile) {
  Ok ".env 가 이미 있어 유지합니다 ($EnvFile)"
  $AdminPass = '(기존 설정 유지)'
} else {
  $secret = & $VenvPy -c "import secrets;print(secrets.token_urlsafe(64))"
  $AdminPass = -join ((50..57) + (65..78) + (80..90) + (97..107) + (109..122) |
    Get-Random -Count 16 | ForEach-Object { [char]$_ })
  $lines = @(
    "# d-ddeck DB Server - install-windows.ps1 이 생성함 ($(Get-Date -Format s))",
    'APP_NAME="d-ddeck DB Server"',
    'ENVIRONMENT=production',
    'DEBUG=false',
    'API_V1_PREFIX=/api/v1',
    '',
    "DATABASE_URL=$DatabaseUrl",
    '',
    "SECRET_KEY=$secret",
    'ACCESS_TOKEN_EXPIRE_MINUTES=60',
    'REFRESH_TOKEN_EXPIRE_DAYS=14',
    'PASSWORD_MIN_LENGTH=8',
    '',
    '# 데스크톱/모바일 앱은 Bearer 토큰을 쓰므로 브라우저 CORS 가 필요 없다.',
    'CORS_ORIGINS=',
    '',
    "FIRST_SUPERADMIN_EMAIL=$AdminEmail",
    "FIRST_SUPERADMIN_PASSWORD=$AdminPass",
    'FIRST_SUPERADMIN_NAME=최고관리자',
    '',
    "STORAGE_DIR=$StorageDir",
    'MAX_UPLOAD_MB=25',
    '',
    'SCHEDULER_ENABLED=true',
    'REMINDER_SCAN_SECONDS=60',
    'FCM_SERVER_KEY='
  )
  Set-Content -Path $EnvFile -Value $lines -Encoding utf8
  Ok ".env 생성 (SECRET_KEY / 관리자 비밀번호 난수 생성)"
}

# .env 는 DB 비밀번호와 서명 키를 담는다. 일반 사용자 읽기를 막는다.
icacls $EnvFile /inheritance:r /grant:r "SYSTEM:(R)" "Administrators:(F)" | Out-Null
Ok "설정 파일 권한 제한 (SYSTEM / Administrators 만)"

# ------------------------------------------------------------------ 스키마
Step "데이터베이스 스키마 적용"
Push-Location $BackendDir
try {
  & $VenvPy -m alembic upgrade head
  if ($LASTEXITCODE -ne 0) { Die "Alembic 마이그레이션 실패" }
} finally { Pop-Location }
Ok "마이그레이션 완료"

# ------------------------------------------------------------------ 자동 시작
Step "자동 시작 등록"
# Windows 에는 systemd 가 없다. 작업 스케줄러에 "시스템 시작 시 SYSTEM 으로 실행"
# 을 걸면 로그인 없이도 떠 있고 로그아웃해도 유지된다.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$uvicorn = Join-Path $BackendDir '.venv\Scripts\uvicorn.exe'
# 워커는 1개여야 한다. 일정 알림 스케줄러가 프로세스 안에서 돌기 때문에
# 여러 개로 늘리면 같은 알림이 중복 발송된다.
$action  = New-ScheduledTaskAction -Execute $uvicorn `
  -Argument "app.main:app --host 0.0.0.0 --port $Port" -WorkingDirectory $BackendDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Description 'd-ddeck 사내 통합 DB 서버' | Out-Null
Start-ScheduledTask -TaskName $TaskName
Ok "작업 스케줄러 등록 및 시작 (부팅 시 자동 실행)"

# ------------------------------------------------------------------ 방화벽
Step "방화벽"
if (Get-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue) {
  Remove-NetFirewallRule -DisplayName $FwRuleName
}
# 사내망(Private/Domain)만 허용. 공용 네트워크에는 열지 않는다.
New-NetFirewallRule -DisplayName $FwRuleName -Direction Inbound -Protocol TCP `
  -LocalPort $Port -Action Allow -Profile Private,Domain | Out-Null
Ok "$Port/tcp 인바운드 허용 (사내망만)"

# ------------------------------------------------------------------ 동작 확인
Step "동작 확인"
$health = $null
for ($i = 0; $i -lt 40; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2
    if ($r.StatusCode -eq 200) { $health = $r.Content; break }
  } catch { Start-Sleep -Seconds 1 }
}
if (-not $health) {
  Write-Host ""
  Write-Host "서버가 응답하지 않습니다. 직접 실행해 원인을 확인해 보세요:" -ForegroundColor Red
  Write-Host "  cd `"$BackendDir`""
  Write-Host "  .\.venv\Scripts\uvicorn.exe app.main:app --host 0.0.0.0 --port $Port"
  Die "설치는 되었으나 기동에 실패했습니다."
}
Ok "healthz 응답: $health"

# ------------------------------------------------------------------ 요약
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and
                 $_.InterfaceAlias -notmatch 'Loopback|vEthernet|VirtualBox|VMware' } |
  Select-Object -First 1).IPAddress
$hostLocal = "$env:COMPUTERNAME.local"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  설치 완료" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "클라이언트에서 입력할 서버 주소" -ForegroundColor White
Write-Host "    http://${ip}:$Port"
Write-Host "    http://${hostLocal}:$Port      (mDNS 지원 기기에서)"
Write-Host ""
Write-Host "최고 관리자 계정" -ForegroundColor White
Write-Host "    이메일   $AdminEmail"
Write-Host "    비밀번호 $AdminPass"
Write-Host "    첫 로그인 시 비밀번호 변경 화면이 강제로 뜹니다." -ForegroundColor Yellow
Write-Host "    이 비밀번호는 다시 표시되지 않습니다. 지금 기록해 두세요." -ForegroundColor Yellow
Write-Host ""
Write-Host "API 문서" -ForegroundColor White
Write-Host "    http://${ip}:$Port/docs"
Write-Host ""
Write-Host "서비스 관리" -ForegroundColor White
Write-Host "    Get-ScheduledTask '$TaskName'          상태"
Write-Host "    Stop-ScheduledTask '$TaskName'         중지"
Write-Host "    Start-ScheduledTask '$TaskName'        시작"
Write-Host "    제거:  .\deploy\install-windows.ps1 -Uninstall"
Write-Host ""
Write-Host "다음에 할 일" -ForegroundColor White
Write-Host "    1. 이 PC 에 고정 IP 설정 (공유기 DHCP 예약 권장)"
Write-Host "    2. 절전 모드 해제 - 절전에 들어가면 서버가 멈춥니다"
Write-Host "         powercfg /change standby-timeout-ac 0"
Write-Host "    3. 백업 등록:  .\deploy\backup-windows.ps1 -InstallTask"
Write-Host "    4. 클라이언트 설치 파일 재생성:"
Write-Host "         .\installer\build.ps1 -ServerUrl `"http://${ip}:$Port`""
Write-Host ""
