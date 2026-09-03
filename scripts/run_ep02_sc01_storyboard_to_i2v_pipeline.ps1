param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01.json",
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json"
    ),
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json",
    [string]$WorkflowCreateResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_workflow_create_result.json",
    [string]$QueuePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_i2v_queue_ep02_sc01.json",
    [string]$CycleResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_cycle_ep02_sc01_result.json",
    [string]$PrecheckResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01_precheck.json",
    [string]$QueueRunResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_i2v_queue_ep02_sc01_run_result.json",
    [string]$PostprocessResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_i2v_postprocess_result.json",
    [string]$DashboardOutputPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html",
    [string]$DashboardResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_dashboard_ep02_sc01_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep02_sc01_storyboard_to_i2v_pipeline_result.json",
    [switch]$SkipMarkdownImport,
    [switch]$LiveRun,
    [switch]$WaitForComfyIdle,
    [switch]$RunPostprocess,
    [switch]$BuildReviewPackage,
    [switch]$BuildTechnicalPreviewCut,
    [switch]$AllowMissingVideos,
    [int]$MaxItems = 0,
    [int]$IdlePollSeconds = 30,
    [int]$IdleMaxPolls = 120
)

$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root "scripts"
$steps = @()

function Invoke-Step {
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
        output_tail = @($output | Select-Object -Last 18)
        ok = ($exitCode -eq 0 -or [bool]$AllowNonZero)
    }
    $script:steps += $step
    if (-not $step.ok) {
        throw "Step failed: $Name"
    }
    return $output
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Join-QuotedCommand {
    param([string[]]$Parts)
    return ($Parts -join " ")
}

$cycleScript = Join-Path $scripts "run_storyboard_review_cycle.ps1"
$queueRunnerScript = Join-Path $scripts "run_storyboard_i2v_queue.ps1"
$idleRunnerScript = Join-Path $scripts "run_when_comfy_idle.ps1"
$postprocessScript = Join-Path $scripts "run_segment_i2v_postprocess.ps1"
$statusScript = Join-Path $scripts "build_ai_short_drama_status_report.ps1"
$dashboardScript = Join-Path $scripts "build_storyboard_review_dashboard.ps1"

try {
    $reviewArgs = @("-ReviewPaths")
    foreach ($path in $ReviewPaths) {
        $reviewArgs += $path
    }

    $cycleArgs = @(
        "-DecisionPath", $DecisionPath,
        "-QueuePath", $QueuePath,
        "-ResultPath", $CycleResultPath,
        "-PrecheckResultPath", $PrecheckResultPath,
        "-QueueRunResultPath", $QueueRunResultPath
    ) + $reviewArgs
    if ($SkipMarkdownImport) {
        $cycleArgs += "-SkipMarkdownImport"
    }
    if ($MaxItems -gt 0) {
        $cycleArgs += @("-MaxItems", [string]$MaxItems)
    }

    Invoke-Step -Name "storyboard_review_cycle_dry_run_gate" -ScriptPath $cycleScript -Arguments $cycleArgs | Out-Null
    $cycle = Read-JsonFile -Path $CycleResultPath
    $queue = Read-JsonFile -Path $QueuePath
    $precheck = Read-JsonFile -Path $PrecheckResultPath

    $state = "awaiting_storyboard_review"
    if ($queue -and $queue.queue_count -gt 0) {
        $state = "i2v_queue_ready_dry_run_verified"
    } elseif ($precheck -and $precheck.counts.pending -eq 0) {
        $state = "storyboards_reviewed_no_i2v_queue"
    }

    $queueRun = $null
    if ($queue -and $queue.queue_count -gt 0) {
        $queueArgs = @("-QueuePath", $QueuePath, "-ResultPath", $QueueRunResultPath)
        if ($MaxItems -gt 0) {
            $queueArgs += @("-MaxItems", [string]$MaxItems)
        }

        if (-not $LiveRun) {
            $dryRunArgs = $queueArgs + "-DryRun"
            Invoke-Step -Name "run_i2v_queue_dry_run" -ScriptPath $queueRunnerScript -Arguments $dryRunArgs | Out-Null
            $queueRun = Read-JsonFile -Path $QueueRunResultPath
            $state = "i2v_queue_ready_dry_run_verified"
        } elseif ($WaitForComfyIdle) {
            $commandParts = @(
                "powershell", "-ExecutionPolicy", "Bypass", "-File", "'$queueRunnerScript'",
                "-QueuePath", "'$QueuePath'",
                "-ResultPath", "'$QueueRunResultPath'"
            )
            if ($MaxItems -gt 0) {
                $commandParts += @("-MaxItems", [string]$MaxItems)
            }
            $idleArgs = @(
                "-Command", (Join-QuotedCommand -Parts $commandParts),
                "-PollSeconds", [string]$IdlePollSeconds,
                "-MaxPolls", [string]$IdleMaxPolls,
                "-ResultPath", "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep02_sc01_wait_idle_then_i2v_result.json"
            )
            Invoke-Step -Name "wait_idle_then_run_i2v_queue_live" -ScriptPath $idleRunnerScript -Arguments $idleArgs | Out-Null
        } else {
            Invoke-Step -Name "run_i2v_queue_live" -ScriptPath $queueRunnerScript -Arguments $queueArgs | Out-Null
            $queueRun = Read-JsonFile -Path $QueueRunResultPath
            $state = "i2v_queue_live_attempted"
        }
    }

    $postprocess = $null
    if ($RunPostprocess -or $BuildReviewPackage -or $BuildTechnicalPreviewCut) {
        $postArgs = @(
            "-ReviewPath", $ReviewPath,
            "-WorkflowCreateResultPath", $WorkflowCreateResultPath,
            "-ResultPath", $PostprocessResultPath
        )
        if ($BuildReviewPackage) {
            $postArgs += "-BuildReviewPackage"
        }
        if ($BuildTechnicalPreviewCut) {
            $postArgs += "-BuildTechnicalPreviewCut"
        }
        if ($AllowMissingVideos) {
            $postArgs += "-AllowMissingVideos"
        }
        Invoke-Step -Name "postprocess_i2v_outputs" -ScriptPath $postprocessScript -Arguments $postArgs | Out-Null
        $postprocess = Read-JsonFile -Path $PostprocessResultPath
        if ($postprocess -and $postprocess.state) {
            $state = [string]$postprocess.state
        }
    }

    Invoke-Step -Name "refresh_storyboard_dashboard" -ScriptPath $dashboardScript -Arguments @(
        "-DecisionPath", $DecisionPath,
        "-OutputPath", $DashboardOutputPath,
        "-ResultPath", $DashboardResultPath
    ) | Out-Null
    Invoke-Step -Name "refresh_pipeline_status_report" -ScriptPath $statusScript | Out-Null

    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        state = $state
        decision_path = $DecisionPath
        review_paths = $ReviewPaths
        queue_path = $QueuePath
        cycle_result_path = $CycleResultPath
        precheck_result_path = $PrecheckResultPath
        queue_run_result_path = $QueueRunResultPath
        postprocess_result_path = $PostprocessResultPath
        dashboard_output_path = $DashboardOutputPath
        dashboard_result_path = $DashboardResultPath
        live_run = [bool]$LiveRun
        wait_for_comfy_idle = [bool]$WaitForComfyIdle
        run_postprocess = [bool]$RunPostprocess
        build_review_package = [bool]$BuildReviewPackage
        build_technical_preview_cut = [bool]$BuildTechnicalPreviewCut
        allow_missing_videos = [bool]$AllowMissingVideos
        max_items = $MaxItems
        steps = $steps
        precheck = if ($precheck) {
            [ordered]@{
                ok = [bool]$precheck.ok
                pending = [int]$precheck.counts.pending
                pass = [int]$precheck.counts.pass
                needs_regeneration = [int]$precheck.counts.needs_regeneration
                blocked = [int]$precheck.counts.blocked
                ready_for_i2v_queue = [bool]$precheck.ready_for_i2v_queue
                all_storyboards_reviewed = [bool]$precheck.all_storyboards_reviewed
            }
        } else { $null }
        queue = if ($queue) {
            [ordered]@{
                ok = [bool]$queue.ok
                queue_count = [int]$queue.queue_count
                pending = [int]$queue.summary.pending
                pass = [int]$queue.summary.pass
                needs_regeneration = [int]$queue.summary.needs_regeneration
                blocked = [int]$queue.summary.blocked
            }
        } else { $null }
        queue_run = if ($queueRun) {
            [ordered]@{
                ok = [bool]$queueRun.ok
                dry_run = [bool]$queueRun.dry_run
                runs = @($queueRun.runs).Count
                skipped = @($queueRun.skipped).Count
            }
        } else { $null }
        postprocess = if ($postprocess) {
            [ordered]@{
                ok = [bool]$postprocess.ok
                state = if ($postprocess.state) { [string]$postprocess.state } else { "" }
                found_count = if ($postprocess.refresh) { [int]$postprocess.refresh.found_count } else { 0 }
            }
        } else { $null }
        ok = $true
    }
} catch {
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        state = "ep02_sc01_storyboard_to_i2v_pipeline_failed"
        decision_path = $DecisionPath
        review_paths = $ReviewPaths
        queue_path = $QueuePath
        error = $_.Exception.Message
        steps = $steps
        ok = $false
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 40

if (-not $result.ok) {
    exit 1
}
