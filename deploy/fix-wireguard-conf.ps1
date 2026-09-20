<#
.SYNOPSIS
  공유기에서 받은 WireGuard 설정(.conf)을 분할 터널로 바꿉니다.

.DESCRIPTION
  ipTIME 등 공유기가 만들어 주는 .conf 는 보통 AllowedIPs 가 0.0.0.0/0 입니다.
  그대로 쓰면 직원의 인터넷까지 전부 회사 회선을 경유해 느려집니다.
  이 스크립트는 회사망 트래픽만 터널을 타도록 고칩니다.

  고치는 항목
    AllowedIPs          -> 회사 LAN + VPN 대역만
    DNS                 -> 주석 처리 (IP 로 접속하므로 불필요)
    PersistentKeepalive -> 25 추가 (공유기 NAT 만료로 첫 접속이 지연되는 것 방지)
    Endpoint            -> -Endpoint 를 주면 호스트 부분만 교체 (DDNS 전환용)

  비밀키(PrivateKey / PresharedKey)는 읽지도 출력하지도 않고 그대로 보존합니다.
  원본은 .conf.bak 으로 백업합니다.

.PARAMETER Path
  .conf 파일 하나, 또는 여러 .conf 가 든 폴더 (기본: 현재 폴더)

.PARAMETER LanSubnet
  회사 사내망 대역 (기본 192.168.0.0/24)

.PARAMETER VpnSubnet
  WireGuard 대역 (기본 10.109.203.0/24)

.PARAMETER Endpoint
  Endpoint 의 호스트를 이 값으로 교체. 포트는 그대로 둡니다.
  공인 IP 는 바뀔 수 있으므로 DDNS 이름 사용을 권합니다.

.EXAMPLE
  .\deploy\fix-wireguard-conf.ps1 -Path "$env:USERPROFILE\Downloads"

.EXAMPLE
  .\deploy\fix-wireguard-conf.ps1 -Path .\peers -Endpoint ddeck.iptime.org
#>
[CmdletBinding()]
param(
  [string]$Path = '.',
  [string]$LanSubnet = '192.168.0.0/24',
  [string]$VpnSubnet = '10.109.203.0/24',
  [string]$Endpoint = '',
  [switch]$FullTunnel
)

$ErrorActionPreference = 'Stop'

function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host ""; Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Path)) { Die "경로를 찾을 수 없습니다: $Path" }

$files = @()
if ((Get-Item $Path).PSIsContainer) {
  $files = Get-ChildItem -Path $Path -Filter '*.conf' -File
} else {
  $files = @(Get-Item $Path)
}
if (-not $files -or $files.Count -eq 0) { Die "$Path 에서 .conf 파일을 찾지 못했습니다." }

$allowed = if ($FullTunnel) { '0.0.0.0/0' } else { "$LanSubnet, $VpnSubnet" }

Write-Host ""
Write-Host "대상 파일 $($files.Count) 개" -ForegroundColor Cyan
Write-Host "  AllowedIPs -> $allowed"
if ($Endpoint) { Write-Host "  Endpoint 호스트 -> $Endpoint" }
Write-Host ""

foreach ($f in $files) {
  Write-Host $f.Name -ForegroundColor White

  $raw = Get-Content -Path $f.FullName -Raw -Encoding UTF8
  if ($raw -notmatch '(?im)^\s*\[Interface\]') {
    Warn "WireGuard 설정 형식이 아닙니다. 건너뜁니다."
    continue
  }

  $bak = "$($f.FullName).bak"
  if (-not (Test-Path $bak)) {
    Copy-Item $f.FullName $bak
    Ok "백업: $(Split-Path -Leaf $bak)"
  }

  $out = New-Object System.Collections.Generic.List[string]
  $hasKeepalive = $false
  $changedAllowed = $false

  foreach ($line in ($raw -split "`r?`n")) {
    $s = $line.TrimEnd()
    $key = ($s -split '=', 2)[0].Trim().ToLower()

    switch ($key) {
      'allowedips' {
        $out.Add("AllowedIPs = $allowed")
        $changedAllowed = $true
        continue
      }
      'dns' {
        if ($FullTunnel) { $out.Add($s) }
        else { $out.Add("# $s   (분할 터널에서는 불필요)") }
        continue
      }
      'persistentkeepalive' {
        $hasKeepalive = $true
        $out.Add('PersistentKeepalive = 25')
        continue
      }
      'endpoint' {
        if ($Endpoint) {
          $val = ($s -split '=', 2)[1].Trim()
          # host:port 에서 포트만 살린다. IPv6 대괄호 표기도 고려.
          $port = if ($val -match ':(\d+)\s*$') { $Matches[1] } else { '' }
          if ($port) { $out.Add("Endpoint = ${Endpoint}:${port}") }
          else { $out.Add("Endpoint = $Endpoint"); Warn "포트를 알 수 없어 호스트만 적었습니다." }
        } else { $out.Add($s) }
        continue
      }
      default { $out.Add($s) }
    }
  }

  if (-not $changedAllowed) { Warn "AllowedIPs 항목이 없어 추가하지 못했습니다. 파일을 확인하세요." }
  if (-not $hasKeepalive -and -not $FullTunnel) {
    # 마지막 빈 줄 뒤에 붙지 않도록 정리한 뒤 추가
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) {
      $out.RemoveAt($out.Count - 1)
    }
    $out.Add('PersistentKeepalive = 25')
    Ok "PersistentKeepalive = 25 추가"
  }

  # WireGuard 는 UTF-8 BOM 을 싫어한다. BOM 없이 저장한다.
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($f.FullName, ($out -join "`r`n") + "`r`n", $enc)
  Ok "수정 완료"

  # 확인용 출력. 비밀키는 절대 보여주지 않는다.
  foreach ($line in ($out | Where-Object { $_.Trim() })) {
    $k = ($line -split '=', 2)[0].Trim().ToLower()
    if ($k -in @('privatekey','presharedkey')) {
      Write-Host ("      " + ($line -split '=')[0].Trim() + " = [숨김]") -ForegroundColor DarkGray
    } elseif ($k -in @('allowedips','endpoint','address','persistentkeepalive')) {
      Write-Host ("      $line") -ForegroundColor DarkGray
    }
  }
  Write-Host ""
}

Write-Host "완료. 수정된 .conf 를 WireGuard 에서 '터널 가져오기' 로 등록하세요." -ForegroundColor Green
Write-Host ""
Write-Host "주의: .conf 에는 개인키가 들어 있습니다. 메신저나 이메일로 보내지 말고" -ForegroundColor Yellow
Write-Host "      QR 코드나 USB 로 전달하세요. 기기마다 별도 피어를 쓰세요." -ForegroundColor Yellow
