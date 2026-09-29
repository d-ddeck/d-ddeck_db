import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Uses the official WireGuard tunnel service. Only fixed operations are sent
/// to PowerShell; configuration travels over stdin, never command-line args.
class WindowsVpn {
  Future<String> status() async => (await _call('status'))['state'] as String;
  Future<void> connect(String config) async {
    await _call('connect', config);
  }

  Future<void> disconnect() async {
    await _call('disconnect');
  }

  Future<void> remove() async {
    await _call('remove');
  }

  Future<Map<String, dynamic>> _call(String action, [String? config]) async {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final process = await Process.start(
      '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', _script],
      runInShell: false,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    // Never display raw PowerShell/WireGuard output: it may include secrets.
    final stderr = process.stderr.drain<void>();
    process.stdin.write(jsonEncode({'action': action, 'config': config}));
    await process.stdin.close();
    try {
      final code = await process.exitCode.timeout(const Duration(minutes: 3));
      await stderr;
      final text = await stdout;
      if (code != 0) throw const WindowsVpnException('failed');
      final data = jsonDecode(text.trim()) as Map<String, dynamic>;
      if (data['error'] != null) {
        throw WindowsVpnException(data['error'] as String);
      }
      return data;
    } on TimeoutException {
      process.kill();
      throw const WindowsVpnException('timeout');
    }
  }

  static const _script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
  $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
  $hash = [System.Security.Cryptography.SHA256]::Create()
  $suffix = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid.Value)))).Replace('-','').Substring(0,12).ToLowerInvariant()
  $name = 'ddeck_' + $suffix
  $serviceName = 'WireGuardTunnel$' + $name
  $folder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'D.DDECK\vpn'
  $configPath = Join-Path $folder ($name + '.conf')
  $programs = [Environment]::GetFolderPath('ProgramFiles')
  $exe = Join-Path $programs 'WireGuard\wireguard.exe'
  function State {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) { return 'disconnected' }
    switch ($service.Status.ToString()) {
      'Running' { return 'connected' }
      'StartPending' { return 'connecting' }
      'StopPending' { return 'disconnecting' }
      default { return 'disconnected' }
    }
  }
  function Elevated([string]$arguments) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'not_installed' }
    try {
      $p = Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    } catch { throw 'permission' }
    if ($p.ExitCode -ne 0) { throw 'failed' }
  }
  switch ($request.action) {
    'status' { }
    'connect' {
      if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'not_installed' }
      if ((State) -eq 'connected') { @{state='connected'} | ConvertTo-Json -Compress; exit 0 }
      if ([string]::IsNullOrWhiteSpace($request.config)) { throw 'invalid_config' }
      if ($request.config.Length -gt 65536 -or $request.config -match '(?im)^\s*(PreUp|PostUp|PreDown|PostDown)\s*=') { throw 'invalid_config' }
      # Restrict the directory before writing any private key. No inherited ACL.
      foreach ($path in @((Split-Path $folder), $folder, $configPath)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsafe_path' }
      }
      [IO.Directory]::CreateDirectory($folder) | Out-Null
      $acl = New-Object System.Security.AccessControl.DirectorySecurity
      $acl.SetAccessRuleProtection($true, $false)
      $acl.SetOwner($sid)
      foreach ($identity in @($sid, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
      }
      Set-Acl -LiteralPath $folder -AclObject $acl
      if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
      [IO.File]::WriteAllText($configPath, $request.config, (New-Object Text.UTF8Encoding($false)))
      # A previously stopped service is removed before re-installation.
      if ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        Elevated ('/uninstalltunnelservice ' + $name)
      }
      Elevated ('/installtunnelservice "' + $configPath + '"')
      for ($i=0; $i -lt 30 -and (State) -ne 'connected'; $i++) { Start-Sleep -Milliseconds 500 }
      if ((State) -ne 'connected') { throw 'failed' }
    }
    {$_ -in 'disconnect','remove'} {
      if ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        Elevated ('/uninstalltunnelservice ' + $name)
      }
      if ((State) -ne 'disconnected') { throw 'failed' }
      if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
      }
    }
    default { throw 'invalid_action' }
  }
  @{state=(State)} | ConvertTo-Json -Compress
} catch {
  $safe = $_.Exception.Message
  if ($safe -notin @('not_installed','permission','invalid_config','unsafe_path')) { $safe = 'failed' }
  @{error=$safe} | ConvertTo-Json -Compress
}
''';
}

class WindowsVpnException implements Exception {
  const WindowsVpnException(this.code);
  final String code;
  @override
  String toString() => 'WindowsVpnException($code)';
}
