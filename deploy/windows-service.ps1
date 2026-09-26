# Refuse to replace data/code until both the scheduled task and its worker exit.
function Stop-DdeckTask([string]$TaskName, [string]$BackendDir) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $workers = Get-CimInstance Win32_Process | Where-Object {
      $_.CommandLine -and $_.CommandLine -match [regex]::Escape($BackendDir) -and
      $_.CommandLine -match '(uvicorn|server_windows[.]py)'
    }
    if ($task.State -ne 'Running' -and -not $workers) { return }
    Start-Sleep -Seconds 1
  }
  throw '서버 프로세스가 종료되지 않았습니다. 코드/DB 교체를 중단합니다.'
}
