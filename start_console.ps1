param(
    [string]$HostName = "127.0.0.1",
    [int]$Port = 8200
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $root "console\server.py"

if (-not (Test-Path -LiteralPath $server)) {
    throw "Console server not found: $server"
}

$url = "http://${HostName}:$Port"
Write-Host "Starting Movie Pipeline Console: $url"
Write-Host "Project root: $root"
python $server --host $HostName --port $Port
