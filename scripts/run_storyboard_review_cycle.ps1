param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01.json",
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json"
    ),
    [string]$QueuePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_i2v_queue_ep02_sc01.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_cycle_ep02_sc01_result.json",
    [string]$PrecheckResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01_precheck.json",
    [string]$QueueRunResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_i2v_queue_ep02_sc01_run_result.json",
    [switch]$SkipMarkdownImport,
    [switch]$RunQueue,
    [switch]$LiveRun,
    [int]$MaxItems = 0
)

$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root "scripts"
$steps = @()

function Invoke-PowerShellStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$AllowNonZero
    )

    $output = & powershell -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $step = [ordered]@{
        name = $Name
        script = $ScriptPath
        arguments = $Arguments
        exit_code = $exitCode
        output_tail = @($output | Select-Object -Last 16)
        ok = ($exitCode -eq 0 -or [bool]$AllowNonZero)
    }
    $script:steps += $step
    if (-not $step.ok) {
        throw "Step failed: $Name"
    }
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Review-Path-Arguments {
    param([string[]]$Paths)

    $args = @("-ReviewPaths")
    foreach ($path in $Paths) {
        $args += $path
    }
    return [string[]]$args
}

$importScript = Join-Path $scripts "import_storyboard_review_markdown_decisions.ps1"
$precheckScript = Join-Path $scripts "test_storyboard_review_decisions.ps1"
$queueScript = Join-Path $scripts "build_storyboard_i2v_queue.ps1"
$runnerScript = Join-Path $scripts "run_storyboard_i2v_queue.ps1"

try {
    if (-not $SkipMarkdownImport) {
        Invoke-PowerShellStep -Name "import_markdown_decisions" -ScriptPath $importScript -Arguments @("-DecisionPath", $DecisionPath)
    }

    $reviewArgs = Review-Path-Arguments -Paths $ReviewPaths
    $precheckArgs = @("-DecisionPath", $DecisionPath, "-ResultPath", $PrecheckResultPath) + $reviewArgs
    Invoke-PowerShellStep -Name "precheck_storyboard_decisions" -ScriptPath $precheckScript -Arguments $precheckArgs
    $precheck = Read-JsonFile -Path $PrecheckResultPath

    $queueArgs = @("-DecisionPath", $DecisionPath, "-QueuePath", $QueuePath) + $reviewArgs
    Invoke-PowerShellStep -Name "build_storyboard_i2v_queue" -ScriptPath $queueScript -Arguments $queueArgs
    $queue = Read-JsonFile -Path $QueuePath

    if ($queue -and $queue.queue_count -gt 0) {
        $runnerArgs = @("-QueuePath", $QueuePath, "-ResultPath", $QueueRunResultPath)
        if ($MaxItems -gt 0) {
            $runnerArgs += @("-MaxItems", [string]$MaxItems)
        }
        if (-not $LiveRun) {
            $runnerArgs += "-DryRun"
        }
        if ($RunQueue -or -not $LiveRun) {
            $runnerStepName = "run_storyboard_queue_dry_run"
            if ($LiveRun) {
                $runnerStepName = "run_storyboard_queue_live"
            }
            Invoke-PowerShellStep -Name $runnerStepName -ScriptPath $runnerScript -Arguments $runnerArgs
        }
    }

    $finalQueue = Read-JsonFile -Path $QueuePath
    $finalPrecheck = Read-JsonFile -Path $PrecheckResultPath

    $state = "awaiting_storyboard_review"
    if ($finalQueue -and $finalQueue.queue_count -gt 0) {
        $state = if ($LiveRun -and $RunQueue) { "storyboard_queue_live_attempted" } else { "storyboard_queue_ready_dry_run_verified" }
    } elseif ($finalPrecheck -and $finalPrecheck.counts.pending -eq 0) {
        $state = "storyboards_reviewed_no_auto_queue"
    }

    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        decision_path = $DecisionPath
        review_paths = $ReviewPaths
        queue_path = $QueuePath
        precheck_result_path = $PrecheckResultPath
        queue_run_result_path = $QueueRunResultPath
        state = $state
        skip_markdown_import = [bool]$SkipMarkdownImport
        run_queue = [bool]$RunQueue
        live_run = [bool]$LiveRun
        max_items = $MaxItems
        steps = $steps
        precheck = if ($finalPrecheck) {
            [ordered]@{
                ok = [bool]$finalPrecheck.ok
                pending = [int]$finalPrecheck.counts.pending
                pass = [int]$finalPrecheck.counts.pass
                needs_regeneration = [int]$finalPrecheck.counts.needs_regeneration
                blocked = [int]$finalPrecheck.counts.blocked
                ready_for_i2v_queue = [bool]$finalPrecheck.ready_for_i2v_queue
                all_storyboards_reviewed = [bool]$finalPrecheck.all_storyboards_reviewed
            }
        } else { $null }
        queue = if ($finalQueue) {
            [ordered]@{
                ok = [bool]$finalQueue.ok
                queue_count = [int]$finalQueue.queue_count
                pending = [int]$finalQueue.summary.pending
                pass = [int]$finalQueue.summary.pass
                needs_regeneration = [int]$finalQueue.summary.needs_regeneration
                blocked = [int]$finalQueue.summary.blocked
                missing_workflow = [int]$finalQueue.summary.missing_workflow
                missing_storyboard = [int]$finalQueue.summary.missing_storyboard
            }
        } else { $null }
        ok = $true
    }
} catch {
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        decision_path = $DecisionPath
        review_paths = $ReviewPaths
        queue_path = $QueuePath
        state = "cycle_failed"
        error = $_.Exception.Message
        steps = $steps
        ok = $false
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 30

if (-not $result.ok) {
    exit 1
}
