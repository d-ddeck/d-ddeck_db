param([string]$BackendDir, [int]$Port = 8000)
$ErrorActionPreference = 'Stop'
$python = Join-Path $BackendDir '.venv\Scripts\python.exe'
$runner = Join-Path $PSScriptRoot 'server_windows.py'
Set-Location $BackendDir
& $python $runner --backend $BackendDir --port $Port
exit $LASTEXITCODE
