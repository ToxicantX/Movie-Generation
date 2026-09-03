param(
    [string]$WorkflowCreateResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc02_workflow_create_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_generation_with_fallback_result.json",
    [string]$RunImageScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_image_workflow_and_wait.ps1",
    [int]$PollSeconds = 5,
    [int]$MaxPolls = 180,
    [int]$RateLimitRetrySeconds = 75,
    [int]$MaxRateLimitRetries = 2,
    [int]$TransientRetrySeconds = 45,
    [int]$MaxTransientRetries = 1,
    [switch]$SkipExisting,
    [switch]$ForceNoReference
)

if (-not (Test-Path -LiteralPath $WorkflowCreateResultPath)) {
    throw "Workflow create result not found: $WorkflowCreateResultPath"
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-ReferenceFailure {
    param($RunResult)
    if (-not $RunResult) { return $false }
    $errorText = if ($RunResult.error) { [string]$RunResult.error } else { "" }
    return ($errorText -match "images/edits|SSLEOFError|502|Bad Gateway|upstream|reference_image")
}

function Test-RateLimitFailure {
    param($RunResult)
    if (-not $RunResult) { return $false }
    $errorText = if ($RunResult.error) { [string]$RunResult.error } else { "" }
    return ($errorText -match "429|rate[_ -]?limit|requests-per-minute|rate limit exceeded")
}

function Test-TransientFailure {
    param($RunResult)
    if (-not $RunResult) { return $false }
    $errorText = if ($RunResult.error) { [string]$RunResult.error } else { "" }
    return ($errorText -match "RemoteDisconnected|Connection aborted|connection reset|timed out|timeout|524|retryable|SSLEOFError|EOF|502|Bad Gateway|server_error|upstream_error|upstream authentication failed")
}

function Test-WorkflowHasReference {
    param([string]$WorkflowPath)
    $workflow = Read-JsonFile -Path $WorkflowPath
    if (-not $workflow) { return $false }
    foreach ($node in @($workflow.prompt.PSObject.Properties.Value)) {
        if ($node.inputs -and $node.inputs.reference_image_paths -and [string]$node.inputs.reference_image_paths) {
            return $true
        }
    }
    return $false
}

function New-NoReferenceWorkflow {
    param([string]$WorkflowPath)

    $source = Read-JsonFile -Path $WorkflowPath
    if (-not $source) {
        throw "Workflow not found: $WorkflowPath"
    }

    foreach ($node in @($source.prompt.PSObject.Properties.Value)) {
        if ($node.class_type -eq "OpenAICompatibleImageGenerate" -and $node.inputs) {
            if ($node.inputs.PSObject.Properties.Name -contains "reference_image_paths") {
                $node.inputs.PSObject.Properties.Remove("reference_image_paths")
            }
            $prompt = if ($node.inputs.prompt) { [string]$node.inputs.prompt } else { "" }
            $node.inputs.prompt = "$prompt No input reference image is attached in this retry because the reference-image edit endpoint failed; rely on the written character, creature, costume, prop, and location continuity locks. Keep the frame coherent and production-reviewable."
        }
    }

    $pathObj = [System.IO.FileInfo]$WorkflowPath
    $fallbackPath = Join-Path $pathObj.DirectoryName ($pathObj.BaseName + "_noref_retry" + $pathObj.Extension)
    $source | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fallbackPath -Encoding UTF8
    return $fallbackPath
}

function Invoke-ImageRun {
    param(
        [string]$WorkflowPath,
        [string]$ShotId,
        [string]$RunResultPath
    )

    $attempts = @()
    $exitCode = 1
    $runResult = $null
    $output = @()
    $rateRetriesUsed = 0
    $transientRetriesUsed = 0
    $attempt = 1
    $sleepBeforeAttempt = 0

    while ($true) {
        if ($sleepBeforeAttempt -gt 0) {
            Start-Sleep -Seconds $sleepBeforeAttempt
        }
        $output = & powershell -ExecutionPolicy Bypass -File $RunImageScript `
            -WorkflowPath $WorkflowPath `
            -ShotId $ShotId `
            -ResultPath $RunResultPath `
            -PollSeconds $PollSeconds `
            -MaxPolls $MaxPolls 2>&1
        $exitCode = $LASTEXITCODE
        $runResult = Read-JsonFile -Path $RunResultPath
        $isRateLimit = Test-RateLimitFailure -RunResult $runResult
        $isTransient = Test-TransientFailure -RunResult $runResult
        $attempts += [ordered]@{
            attempt = $attempt
            exit_code = $exitCode
            output_tail = @($output | Select-Object -Last 12)
            error = if ($runResult -and $runResult.error) { [string]$runResult.error } else { $null }
            failure_type = if ($exitCode -eq 0 -and $runResult -and [bool]$runResult.completed) {
                $null
            } elseif ($isRateLimit) {
                "rate_limit"
            } elseif ($isTransient) {
                "transient"
            } else {
                "non_retryable"
            }
            ok = ($exitCode -eq 0 -and $runResult -and [bool]$runResult.completed)
        }
        if ($exitCode -eq 0 -and $runResult -and [bool]$runResult.completed) {
            break
        }

        if ($isRateLimit -and $rateRetriesUsed -lt $MaxRateLimitRetries) {
            $rateRetriesUsed += 1
            $sleepBeforeAttempt = $RateLimitRetrySeconds
            $attempt += 1
            continue
        }
        if ($isTransient -and $transientRetriesUsed -lt $MaxTransientRetries) {
            $transientRetriesUsed += 1
            $sleepBeforeAttempt = $TransientRetrySeconds
            $attempt += 1
            continue
        }
        break
    }
    return [ordered]@{
        workflow_path = $WorkflowPath
        result_path = $RunResultPath
        exit_code = $exitCode
        output_tail = @($output | Select-Object -Last 12)
        run_result = $runResult
        attempts = $attempts
        rate_retries_used = $rateRetriesUsed
        transient_retries_used = $transientRetriesUsed
        ok = ($exitCode -eq 0 -and $runResult -and [bool]$runResult.completed)
    }
}

$workflowCreate = Read-JsonFile -Path $WorkflowCreateResultPath
$runs = @()
$ok = $true

foreach ($created in @($workflowCreate.created)) {
    $shotId = [string]$created.shot_id
    $expectedPath = [string]$created.expected_storyboard_path
    $storyboardWorkflow = [string]$created.storyboard_workflow
    $safeShot = ($shotId -replace '[^A-Za-z0-9_=-]', '_').ToLowerInvariant()
    $runResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\$($safeShot)_storyboard_run_result.json"

    $entry = [ordered]@{
        shot_id = $shotId
        expected_storyboard_path = $expectedPath
        skipped_existing = $false
        primary = $null
        fallback = $null
        final_workflow = $storyboardWorkflow
        completed = $false
        fallback_used = $false
    }

    if ($SkipExisting -and $expectedPath -and (Test-Path -LiteralPath $expectedPath)) {
        $entry.skipped_existing = $true
        $entry.completed = $true
        $runs += $entry
        continue
    }

    $workflowToRun = $storyboardWorkflow
    if ($ForceNoReference -and (Test-WorkflowHasReference -WorkflowPath $storyboardWorkflow)) {
        $workflowToRun = New-NoReferenceWorkflow -WorkflowPath $storyboardWorkflow
        $entry.final_workflow = $workflowToRun
        $entry.fallback_used = $true
    }

    $entry.primary = Invoke-ImageRun -WorkflowPath $workflowToRun -ShotId $shotId -RunResultPath $runResultPath
    if ($entry.primary.ok) {
        $entry.completed = $true
        $runs += $entry
        continue
    }

    $primaryFailedOnReference = Test-ReferenceFailure -RunResult $entry.primary.run_result
    if (-not $ForceNoReference -and $primaryFailedOnReference -and (Test-WorkflowHasReference -WorkflowPath $storyboardWorkflow)) {
        $fallbackWorkflow = New-NoReferenceWorkflow -WorkflowPath $storyboardWorkflow
        $fallbackResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\$($safeShot)_storyboard_noref_retry_run_result.json"
        $entry.fallback = Invoke-ImageRun -WorkflowPath $fallbackWorkflow -ShotId $shotId -RunResultPath $fallbackResultPath
        $entry.final_workflow = $fallbackWorkflow
        $entry.fallback_used = $true
        if ($entry.fallback.ok) {
            $entry.completed = $true
        }
    }

    if (-not $entry.completed) {
        $ok = $false
    }
    $runs += $entry
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    workflow_create_result_path = $WorkflowCreateResultPath
    skip_existing = [bool]$SkipExisting
    force_no_reference = [bool]$ForceNoReference
    run_count = @($runs).Count
    completed_count = @($runs | Where-Object { $_.completed }).Count
    fallback_count = @($runs | Where-Object { $_.fallback_used }).Count
    runs = $runs
    ok = [bool]$ok
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 40

if (-not $ok) {
    exit 1
}
