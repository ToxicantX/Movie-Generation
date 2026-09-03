param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [int]$PollSeconds = 30,
    [int]$MaxPolls = 120,
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\run_when_comfy_idle_result.json"
)

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    comfy_url = $ComfyUrl
    command = $Command
    status = "waiting"
    polls = @()
    command_exit_code = $null
    command_output = @()
    error = $null
}

try {
    for ($i = 1; $i -le $MaxPolls; $i++) {
        $queue = Invoke-RestMethod -Uri "$ComfyUrl/queue" -TimeoutSec 10
        $runningCount = @($queue.queue_running).Count
        $pendingCount = @($queue.queue_pending).Count
        $result.polls += [ordered]@{
            poll = $i
            time = (Get-Date).ToString("s")
            running = $runningCount
            pending = $pendingCount
        }

        if ($runningCount -eq 0 -and $pendingCount -eq 0) {
            $result.status = "running_command"
            $output = & powershell -ExecutionPolicy Bypass -Command $Command
            $result.command_exit_code = $LASTEXITCODE
            $result.command_output = @($output)
            $result.status = if ($LASTEXITCODE -eq 0) { "success" } else { "command_failed" }
            break
        }

        Start-Sleep -Seconds $PollSeconds
    }

    if ($result.status -eq "waiting") {
        $result.status = "timeout_waiting_for_idle"
        $result.error = "ComfyUI did not become idle within $MaxPolls polls."
    }
} catch {
    $result.status = "exception"
    $result.error = $_.Exception.Message
} finally {
    New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
    $result | ConvertTo-Json -Depth 20 | Set-Content -Path $ResultPath -Encoding UTF8
    $result | ConvertTo-Json -Depth 20
}

if ($result.status -ne "success") {
    exit 1
}
