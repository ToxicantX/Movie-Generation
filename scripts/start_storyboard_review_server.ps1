param(
    [string]$HostName = "127.0.0.1",
    [int]$Port = 8098,
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01.json",
    [string]$DashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html",
    [string]$DashboardResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_dashboard_ep02_sc01_result.json",
    [string]$SetResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decision_set_result.json",
    [string]$QueuePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_i2v_queue_ep02_sc01.json",
    [string]$CycleResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_cycle_ep02_sc01_result.json",
    [string]$PrecheckResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01_precheck.json",
    [string]$QueueRunResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_i2v_queue_ep02_sc01_run_result.json",
    [string]$DriverResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep02_sc01_storyboard_to_i2v_pipeline_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_server_start_result.json",
    [switch]$Foreground
)

$scriptPath = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\storyboard_review_server.py"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Server script not found: $scriptPath"
}

$arguments = @(
    $scriptPath,
    "--host", $HostName,
    "--port", [string]$Port,
    "--decision-path", $DecisionPath,
    "--dashboard-path", $DashboardPath,
    "--dashboard-result-path", $DashboardResultPath,
    "--set-result-path", $SetResultPath,
    "--queue-path", $QueuePath,
    "--cycle-result-path", $CycleResultPath,
    "--precheck-result-path", $PrecheckResultPath,
    "--queue-run-result-path", $QueueRunResultPath,
    "--driver-result-path", $DriverResultPath
)

if ($Foreground) {
    & python @arguments
    exit $LASTEXITCODE
}

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    $url = "http://$($HostName):$Port/SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html"
    $statusUrl = "http://$($HostName):$Port/api/status"
    try {
        $statusProbe = Invoke-RestMethod -Uri $statusUrl -TimeoutSec 5
        $isReviewServer = [bool]($statusProbe.decision_path -or $statusProbe.dashboard_path)
    } catch {
        $isReviewServer = $false
        $errorMessage = $_.Exception.Message
    }
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        url = $url
        status = if ($isReviewServer) { "already_listening" } else { "port_in_use_but_not_review_server" }
        port = $Port
        error = if ($isReviewServer) { $null } else { $errorMessage }
        ok = [bool]$isReviewServer
    }
} else {
    $process = Start-Process -FilePath python -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $url = "http://$($HostName):$Port/SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html"
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        $ok = ($response.StatusCode -eq 200)
        $status = if ($ok) { "started" } else { "started_but_probe_failed" }
    } catch {
        $ok = $false
        $status = "probe_failed"
        $errorMessage = $_.Exception.Message
    }
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        url = $url
        status = $status
        port = $Port
        process_id = $process.Id
        error = if ($errorMessage) { $errorMessage } else { $null }
        ok = [bool]$ok
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 10

if (-not $result.ok) {
    exit 1
}
