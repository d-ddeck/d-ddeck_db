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
$VenvPy = Join-Path $BackendDir '.venv\Scripts\python.exe'
$SqliteHelper = Join-Path $PSScriptRoot 'sqlite_backup.py'
. (Join-Path $PSScriptRoot 'windows-service.ps1')

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

# PostgreSQL installers may not add their tools to the SYSTEM task PATH.
if ($DatabaseUrl -match '^postgres' -and -not (Get-Command pg_dump -ErrorAction SilentlyContinue)) {
  $pgTools = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\pg_dump.exe' -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $pgTools) { Die 'PostgreSQL pg_dump/pg_restore/psql 도구를 설치하세요.' }
  $env:Path = (Split-Path -Parent $pgTools.FullName) + ';' + $env:Path
}

# ------------------------------------------------------------------ 자동 백업 등록
if ($InstallTask) {
  $me = Join-Path $AppRoot 'deploy\backup-windows.ps1'
  if (-not (Test-Path $me)) { Die '설치 폴더에 백업 스크립트가 없습니다. 설치 프로그램을 갱신하세요.' }
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
    & $VenvPy (Join-Path $PSScriptRoot 'backup_bundle.py') --extract $Restore --destination $tmp
    if ($LASTEXITCODE -ne 0) { Die '백업 무결성 검사 실패' }
    if (-not (Test-Path (Join-Path $tmp 'storage'))) { Die '백업에 storage 폴더가 없습니다.' }
    if ($DatabaseUrl -notlike 'postgresql*') {
      & $VenvPy $SqliteHelper validate (Join-Path $tmp 'ddeck.db')
      if ($LASTEXITCODE -ne 0) { Die '복원본 무결성 검사 실패' }
    } elseif (-not (Test-Path (Join-Path $tmp 'db.dump'))) { Die 'DB 덤프가 없습니다.' }
    Stop-DdeckTask $TaskName $BackendDir
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Quiet
    if ($LASTEXITCODE -ne 0) {
      Start-ScheduledTask -TaskName $TaskName
      Die '복원 전 백업 실패: 현재 데이터를 변경하지 않았습니다.'
    }

    if ($DatabaseUrl -like 'postgresql*') {
      & $VenvPy (Join-Path $PSScriptRoot 'backup_bundle.py') --root $AppRoot --restore-postgres (Join-Path $tmp 'db.dump')
      if ($LASTEXITCODE -ne 0) { Die 'DB 복구 실패: 서비스를 중지 상태로 유지합니다.' }
    } else {
      $dbPath = & $VenvPy (Join-Path $PSScriptRoot 'backup_bundle.py') --root $AppRoot --database-path
      if ($LASTEXITCODE -ne 0 -or -not $dbPath) { Die 'SQLite 경로 확인 실패' }
      & $VenvPy $SqliteHelper restore (Join-Path $tmp 'ddeck.db') $dbPath
      if ($LASTEXITCODE -ne 0) { Die 'SQLite 복원 실패: 서비스를 중지 상태로 유지합니다.' }
    }

    $StorageDir = & $VenvPy (Join-Path $PSScriptRoot 'backup_bundle.py') --root $AppRoot --storage-path
    if ($LASTEXITCODE -ne 0 -or -not $StorageDir) { Die '첨부 경로 확인 실패' }
    $storageBak = Join-Path $tmp 'storage'
    if (Test-Path $storageBak) {
      if (Test-Path $StorageDir) { Remove-Item -Recurse -Force $StorageDir }
      Copy-Item $storageBak $StorageDir -Recurse -Force
    }
    Start-ScheduledTask -TaskName $TaskName
    $taskArgs = (Get-ScheduledTask -TaskName $TaskName).Actions.Arguments
    $healthPort = 8000
    if ($taskArgs -match '(?:--port|-Port)\s+(\d+)') { $healthPort = [int]$Matches[1] }
    $healthy = $false
    for ($try = 0; $try -lt 30; $try++) {
      try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$healthPort/healthz" -UseBasicParsing -TimeoutSec 2
        if ($response.StatusCode -eq 200) { $healthy = $true; break }
      } catch { }
      Start-Sleep -Seconds 1
    }
    if (-not $healthy) { Stop-DdeckTask $TaskName $BackendDir; Die '복원 후 건강 검사 실패: 서비스를 중지했습니다.' }
    Write-Host ""
    Write-Host "[OK] 복구 완료" -ForegroundColor Green
  } finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  }
  exit 0
}

# Shared portable ZIP format (also reads previous tar.gz bundles on restore).
$bundle = Join-Path $PSScriptRoot 'backup_bundle.py'
& $VenvPy $bundle --root $AppRoot
if ($LASTEXITCODE -ne 0) { Die '백업 실패. backups/status.json과 LAST_FAILED를 확인하세요.' }
