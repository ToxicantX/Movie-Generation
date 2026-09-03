param(
    [string]$ComfyRoot = "G:\ComfyUI",
    [switch]$SkipComfyUI
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop is not running."
}

if (-not $SkipComfyUI) {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -UseBasicParsing -TimeoutSec 2 | Out-Null
    } catch {
        $python = Join-Path $ComfyRoot "venv\Scripts\python.exe"
        $main = Join-Path $ComfyRoot "main.py"
        if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath $main)) {
            throw "ComfyUI runtime not found under $ComfyRoot"
        }
        $logs = Join-Path $root "logs"
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        Start-Process -FilePath $python `
            -ArgumentList @($main, "--listen", "0.0.0.0", "--port", "8188", "--lowvram") `
            -WorkingDirectory $ComfyRoot `
            -RedirectStandardOutput (Join-Path $logs "comfyui-docker.out.log") `
            -RedirectStandardError (Join-Path $logs "comfyui-docker.err.log") `
            -WindowStyle Hidden | Out-Null
    }
}

Set-Location $root
docker compose up -d --build
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose deployment failed."
}

Write-Host "Movie Generation Docker console: http://127.0.0.1:8206/"
