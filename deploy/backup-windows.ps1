<#
.SYNOPSIS
  d-ddeck DB 서버(Windows) 백업 / 복구

.DESCRIPTION
  데이터는 두 곳에 있습니다. 둘 다 받아야 복구됩니다.
    1) 데이터베이스  - 계정, AS, 자산, 게시글, 일정
    2) storage\      - 첨부파일 (DB 에는 경로만 저장됨)

.EXAMPLE
  .\deploy\backup-windows.ps1                        지금 한 번
.EXAMPLE
  .\deploy\backup-windows.ps1 -InstallTask           매일 03:00 자동 백업 등록
.EXAMPLE
  .\deploy\backup-windows.ps1 -Restore C:\...\ddeck_20260920_030000.zip
#>
[CmdletBinding()]
param(
  [switch]$InstallTask,
  [string]$Restore = '',
  [int]$KeepDays = 30,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$AppRoot    = 'C:\ProgramData\ddeck'
$BackendDir = Join-Path $AppRoot 'backend'
$StorageDir = Join-Path $AppRoot 'storage'
$BackupDir  = Join-Path $AppRoot 'backups'
$TaskName   = 'd-ddeck DB Server'
$BackupTask = 'd-ddeck 백업'

function Step($m) { if (-not $Quiet) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan } }
function Ok($m)   { if (-not $Quiet) { Write-Host "    [OK] $m" -ForegroundColor Green } }
function Die($m)  { Write-Host ""; Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Die "관리자 권한이 필요합니다. PowerShell 을 관리자로 실행해 주세요."
}

$EnvFile = Join-Path $BackendDir '.env'
if (-not (Test-Path $EnvFile)) { Die "$AppRoot 에 설치본이 없습니다." }
$DatabaseUrl = (Select-String -Path $EnvFile -Pattern '^DATABASE_URL=(.+)$' |
  Select-Object -First 1).Matches[0].Groups[1].Value.Trim()

# ------------------------------------------------------------------ 자동 백업 등록
if ($InstallTask) {
  $me = $MyInvocation.MyCommand.Path
  if (Get-ScheduledTask -TaskName $BackupTask -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $BackupTask -Confirm:$false
  }
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$me`" -Quiet"
  $trigger = New-ScheduledTaskTrigger -Daily -At 3am
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $BackupTask -Action $action -Trigger $trigger `
    -Principal $principal -Description 'd-ddeck 데이터 백업' | Out-Null
  Write-Host ""
  Write-Host "[OK] 매일 새벽 3시 자동 백업 등록" -ForegroundColor Green
  Write-Host "  보관: $BackupDir ($KeepDays 일)"
  Write-Host ""
  Write-Host "  권장: 이 폴더를 NAS 나 외장 디스크로도 복사하세요." -ForegroundColor Yellow
  Write-Host "  이 PC 의 디스크가 고장나면 백업도 같이 사라집니다." -ForegroundColor Yellow
  exit 0
}

# ------------------------------------------------------------------ 복구
if ($Restore) {
  if (-not (Test-Path $Restore)) { Die "백업 파일을 찾을 수 없습니다: $Restore" }
  Write-Host ""
  Write-Host "경고: 현재 데이터를 백업 시점으로 되돌립니다." -ForegroundColor Yellow
  Write-Host "  대상: $Restore"
  $c = Read-Host "계속하려면 yes 를 입력하세요"
  if ($c -ne 'yes') { Die "취소했습니다." }

  $tmp = Join-Path $env:TEMP ("ddeck-restore-" + (Get-Random))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    Expand-Archive -Path $Restore -DestinationPath $tmp -Force
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if ($DatabaseUrl -like 'postgresql*') {
      $pgRestore = (Get-ChildItem 'C:\Program Files\PostgreSQL' -Filter 'pg_restore.exe' -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1).FullName
      if (-not $pgRestore) { Die "pg_restore.exe 를 찾을 수 없습니다." }
      $pw = Read-Host "PostgreSQL 의 postgres 계정 비밀번호" -AsSecureString
      $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
      & $pgRestore -U postgres -h 127.0.0.1 -d ddeck --clean --if-exists (Join-Path $tmp 'db.dump')
      $env:PGPASSWORD = ''
    } else {
      Copy-Item (Join-Path $tmp 'ddeck.db') (Join-Path $BackendDir 'ddeck.db') -Force
    }

    $storageBak = Join-Path $tmp 'storage'
    if (Test-Path $storageBak) {
      if (Test-Path $StorageDir) { Remove-Item -Recurse -Force $StorageDir }
      Copy-Item $storageBak $StorageDir -Recurse -Force
    }
    Start-ScheduledTask -TaskName $TaskName
    Write-Host ""
    Write-Host "[OK] 복구 완료" -ForegroundColor Green
  } finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  }
  exit 0
}

# ------------------------------------------------------------------ 백업
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$tmp = Join-Path $env:TEMP ("ddeck-backup-" + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

try {
  Step "데이터베이스"
  if ($DatabaseUrl -like 'postgresql*') {
    $pgDump = (Get-ChildItem 'C:\Program Files\PostgreSQL' -Filter 'pg_dump.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1).FullName
    if (-not $pgDump) { Die "pg_dump.exe 를 찾을 수 없습니다." }
    # .env 의 URL 에서 비밀번호를 꺼내 쓴다. 대화형 입력 없이 무인 백업이 되어야 한다.
    if ($DatabaseUrl -match '://([^:]+):([^@]+)@') {
      $env:PGUSER = $Matches[1]; $env:PGPASSWORD = $Matches[2]
    }
    & $pgDump -h 127.0.0.1 -Fc ddeck -f (Join-Path $tmp 'db.dump')
    if ($LASTEXITCODE -ne 0) { Die "pg_dump 실패" }
    $env:PGPASSWORD = ''
    Ok "PostgreSQL 덤프 ($([math]::Round((Get-Item (Join-Path $tmp 'db.dump')).Length/1MB,2)) MB)"
  } else {
    # SQLite 는 .backup 을 써야 쓰기 중에도 일관된 스냅샷이 나온다.
    $dbPath = Join-Path $BackendDir 'ddeck.db'
    $venvPy = Join-Path $BackendDir '.venv\Scripts\python.exe'
    $dst = (Join-Path $tmp 'ddeck.db') -replace '\\','/'
    $srcQ = $dbPath -replace '\\','/'
    & $venvPy -c "import sqlite3;s=sqlite3.connect(r'$srcQ');d=sqlite3.connect(r'$dst');s.backup(d);d.close();s.close()"
    if ($LASTEXITCODE -ne 0) { Copy-Item $dbPath (Join-Path $tmp 'ddeck.db') -Force }
    Ok "SQLite 스냅샷 ($([math]::Round((Get-Item (Join-Path $tmp 'ddeck.db')).Length/1MB,2)) MB)"
  }

  Step "첨부파일"
  if (Test-Path $StorageDir) {
    Copy-Item $StorageDir (Join-Path $tmp 'storage') -Recurse -Force
    Ok "storage"
  } else {
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'storage') | Out-Null
    Ok "첨부파일 없음"
  }

  Step "압축"
  $archive = Join-Path $BackupDir "ddeck_$stamp.zip"
  Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $archive -Force
  Ok "$(Split-Path -Leaf $archive) ($([math]::Round((Get-Item $archive).Length/1MB,2)) MB)"

  Step "오래된 백업 정리"
  $old = Get-ChildItem $BackupDir -Filter 'ddeck_*.zip' |
         Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) }
  $old | Remove-Item -Force
  $left = (Get-ChildItem $BackupDir -Filter 'ddeck_*.zip').Count
  Ok "$KeepDays 일 초과 $($old.Count) 건 삭제 / 보관 중 $left 건"

  if (-not $Quiet) {
    Write-Host ""
    Write-Host "백업 완료: $archive" -ForegroundColor Green
    Write-Host "복구: .\deploy\backup-windows.ps1 -Restore `"$archive`""
  }
} finally {
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
}
