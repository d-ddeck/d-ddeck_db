<#
.SYNOPSIS
  d-ddeck Windows 설치 파일(setup.exe)을 만듭니다.

.DESCRIPTION
  Flutter 릴리스 빌드 → Inno Setup 컴파일 순서로 진행하고,
  결과를 dist\ 에 남깁니다.

.PARAMETER ServerUrl
  설치 마법사에 미리 채워질 서버 주소. 사용자가 설치 중 바꿀 수 있습니다.

.PARAMETER Version
  설치 파일 버전 (기본: pubspec.yaml 에서 읽음)

.PARAMETER SkipFlutterBuild
  Flutter 빌드를 건너뛰고 기존 Release 폴더로 패키징만 합니다.

.EXAMPLE
  .\installer\build.ps1 -ServerUrl "https://192.168.121.2"

.EXAMPLE
  .\installer\build.ps1 -ServerUrl "https://192.168.121.2" -Version 0.2.0
#>
[CmdletBinding()]
param(
  [string]$ServerUrl = "https://192.168.121.2",
  [string]$Version = "",
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host ""; Write-Host "!! $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------ 경로
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$AppDir     = Join-Path $RepoRoot 'app'
$IssPath    = Join-Path $PSScriptRoot 'ddeck.iss'
$ReleaseDir = Join-Path $AppDir 'build\windows\x64\runner\Release'
$DistDir    = Join-Path $RepoRoot 'dist'

Step "사전 확인"
if (-not (Test-Path $AppDir))  { Die "app 폴더가 없습니다: $AppDir" }
if (-not (Test-Path $IssPath)) { Die "ddeck.iss 가 없습니다: $IssPath" }

# Inno Setup 컴파일러
$ISCC = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ISCC) {
  Write-Host ""
  Write-Host "Inno Setup 6 이 설치되어 있지 않습니다." -ForegroundColor Red
  Write-Host ""
  Write-Host "    winget install --id JRSoftware.InnoSetup"
  Write-Host ""
  Die "설치 후 다시 실행해 주세요."
}
Ok "Inno Setup: $ISCC"

# Flutter
$Flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $Flutter) {
  $guess = "$env:USERPROFILE\flutter\bin\flutter.bat"
  if (Test-Path $guess) { $Flutter = $guess }
}
if (-not $Flutter -and -not $SkipFlutterBuild) { Die "flutter 를 찾을 수 없습니다. PATH 에 추가하거나 -SkipFlutterBuild 를 쓰세요." }
if ($Flutter) { Ok "Flutter: $Flutter" }

# 버전: 지정이 없으면 pubspec.yaml 의 version 에서 빌드번호를 뗀 값
if (-not $Version) {
  $line = Select-String -Path (Join-Path $AppDir 'pubspec.yaml') -Pattern '^version:\s*(.+)$' | Select-Object -First 1
  if ($line) { $Version = ($line.Matches[0].Groups[1].Value -split '\+')[0].Trim() }
  if (-not $Version) { $Version = '0.1.0' }
}
Ok "버전: $Version"

# 서버 주소 정규화 (앱/설치 마법사와 같은 규칙)
$ServerUrl = $ServerUrl.Trim()
if ($ServerUrl -notmatch '^https?://') { $ServerUrl = "http://$ServerUrl" }
$ServerUrl = $ServerUrl.TrimEnd('/')
Ok "기본 서버 주소: $ServerUrl"

# ------------------------------------------------------------------ Flutter 빌드
if ($SkipFlutterBuild) {
  Warn "Flutter 빌드를 건너뜁니다 (-SkipFlutterBuild)"
  if (-not (Test-Path (Join-Path $ReleaseDir 'ddeck_app.exe'))) {
    Die "기존 빌드 결과가 없습니다. -SkipFlutterBuild 없이 실행하세요."
  }
} else {
  Step "Flutter 릴리스 빌드 (수 분 소요)"
  Push-Location $AppDir
  try {
    # SERVER_URL 은 설정 파일이 없을 때의 대비책으로 함께 넣는다.
    & $Flutter build windows --release "--dart-define=SERVER_URL=$ServerUrl"
    if ($LASTEXITCODE -ne 0) { Die "flutter build windows 실패 (종료코드 $LASTEXITCODE)" }
  } finally { Pop-Location }
  Ok "빌드 완료"
}

$exe = Join-Path $ReleaseDir 'ddeck_app.exe'
if (-not (Test-Path $exe)) { Die "빌드 산출물을 찾을 수 없습니다: $exe" }
$bundleMB = [math]::Round(((Get-ChildItem $ReleaseDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Ok "번들 크기: $bundleMB MB"

# ------------------------------------------------------------------ 설치 파일 생성
Step "설치 파일 컴파일"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

& $ISCC `
  "/DAppVersion=$Version" `
  "/DSourceDir=$ReleaseDir" `
  "/DDefaultServerUrl=$ServerUrl" `
  "/O$DistDir" `
  $IssPath
if ($LASTEXITCODE -ne 0) { Die "Inno Setup 컴파일 실패 (종료코드 $LASTEXITCODE)" }

$setup = Join-Path $DistDir "ddeck-setup-$Version.exe"
if (-not (Test-Path $setup)) { Die "설치 파일이 생성되지 않았습니다: $setup" }
$setupMB = [math]::Round((Get-Item $setup).Length / 1MB, 1)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  설치 파일 생성 완료" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  $setup" -ForegroundColor White
Write-Host "  크기 $setupMB MB / 버전 $Version / 기본 서버 $ServerUrl"
Write-Host ""
Write-Host "  배포: 이 파일 하나만 사용자에게 전달하면 됩니다."
Write-Host "  관리자 권한 없이 설치되며, 설치 중 서버 주소를 물어봅니다."
Write-Host ""
Write-Host "  무인 설치 (IT 일괄 배포용):"
Write-Host "    ddeck-setup-$Version.exe /VERYSILENT /SERVERURL=`"$ServerUrl`"" -ForegroundColor DarkGray
Write-Host ""
