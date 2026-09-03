param(
    [string]$QueuePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\regeneration_queue_ep01.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\regeneration_queue_ep01_run_result.json",
    [switch]$DryRun,
    [int]$MaxItems = 0,
    [switch]$IncludeBlocked
)

if (-not (Test-Path -LiteralPath $QueuePath)) {
    throw "Queue file not found: $QueuePath"
}

$queueData = Get-Content -LiteralPath $QueuePath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($queueData.queue)
if ($MaxItems -gt 0) {
    $items = @($items | Select-Object -First $MaxItems)
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    queue_path = $QueuePath
    dry_run = [bool]$DryRun
    max_items = $MaxItems
    runs = @()
    skipped = @()
    ok = $true
}

function New-Result-Path {
    param($Item)

    $safeReview = ([string]$Item.review_id).ToLowerInvariant() -replace "[^a-z0-9_]+", "_"
    $safeShot = ([string]$Item.shot_id).ToLowerInvariant() -replace "[^a-z0-9_]+", "_"
    return "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\regen_$($safeReview)_$($safeShot)_result.json"
}

function Get-Run-Command {
    param($Item, [string]$ItemResultPath)

    $scope = [string]$Item.regeneration_scope
    $workflow = [string]$Item.selected_workflow
    if ($scope -eq "storyboard") {
        return "powershell -ExecutionPolicy Bypass -File 'E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_image_workflow_and_wait.ps1' -WorkflowPath '$workflow' -ShotId '$($Item.shot_id)' -ResultPath '$ItemResultPath'"
    }
    if ($scope -eq "video") {
        return "powershell -ExecutionPolicy Bypass -File 'E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_single_i2v_workflow_and_wait.ps1' -WorkflowPath '$workflow' -ShotId '$($Item.shot_id)' -ResultPath '$ItemResultPath'"
    }
    return ""
}

foreach ($item in $items) {
    if ($item.decision -eq "blocked" -and -not $IncludeBlocked) {
        $result.skipped += [ordered]@{
            shot_id = $item.shot_id
            reason = "blocked_item_requires_manual_unblock"
        }
        continue
    }
    if (-not [bool]$item.can_auto_rerun) {
        $result.skipped += [ordered]@{
            shot_id = $item.shot_id
            reason = "can_auto_rerun_false"
            regeneration_scope = $item.regeneration_scope
        }
        continue
    }
    if (-not $item.selected_workflow -or -not (Test-Path -LiteralPath ([string]$item.selected_workflow))) {
        $result.ok = $false
        $result.skipped += [ordered]@{
            shot_id = $item.shot_id
            reason = "selected_workflow_missing"
            selected_workflow = $item.selected_workflow
        }
        continue
    }

    $itemResultPath = New-Result-Path -Item $item
    $command = Get-Run-Command -Item $item -ItemResultPath $itemResultPath
    if (-not $command) {
        $result.skipped += [ordered]@{
            shot_id = $item.shot_id
            reason = "unsupported_regeneration_scope"
            regeneration_scope = $item.regeneration_scope
        }
        continue
    }

    $run = [ordered]@{
        review_id = $item.review_id
        shot_id = $item.shot_id
        decision = $item.decision
        regeneration_scope = $item.regeneration_scope
        selected_workflow = $item.selected_workflow
        result_path = $itemResultPath
        command = $command
        status = if ($DryRun) { "dry_run" } else { "pending" }
        exit_code = $null
        output = @()
    }

    if (-not $DryRun) {
        $output = & powershell -ExecutionPolicy Bypass -Command $command
        $exitCode = $LASTEXITCODE
        $run.exit_code = $exitCode
        $run.output = @($output)
        $run.status = if ($exitCode -eq 0) { "success" } else { "failed" }
        if ($exitCode -ne 0) {
            $result.ok = $false
        }
    }
    $result.runs += $run
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
