param(
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json"
    ),
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01.json",
    [string]$QueuePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_i2v_queue_ep02_sc01.json",
    [switch]$IncludePending,
    [switch]$IncludeBlocked
)

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    throw "Decision file not found: $DecisionPath"
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-Review-Id {
    param($Review, [string]$Path)

    if ($Review.segment_id) { return [string]$Review.segment_id }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path).ToUpperInvariant()
}

function Normalize-Path {
    param([string]$Path)

    if (-not $Path) { return "" }
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd("\").ToLowerInvariant()
    } catch {
        return $Path.TrimEnd("\").ToLowerInvariant()
    }
}

$defaultReviewPaths = @("E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json")
$isDefaultReviewPaths = (@($ReviewPaths).Count -eq 1 -and (Normalize-Path -Path $ReviewPaths[0]) -eq (Normalize-Path -Path $defaultReviewPaths[0]))
if ($isDefaultReviewPaths -and $decisionData.review_index) {
    $indexedReviewPaths = @($decisionData.review_index | ForEach-Object { if ($_.review_path) { [string]$_.review_path } } | Where-Object { $_ })
    if (@($indexedReviewPaths).Count -gt 0) {
        $ReviewPaths = $indexedReviewPaths
    }
}

$reviews = @()
foreach ($path in $ReviewPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Review file not found: $path"
    }
    $review = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $reviews += [ordered]@{ path = $path; review = $review }
}

$decisionLookup = @{}
foreach ($decision in @($decisionData.decisions)) {
    $key = "$(Normalize-Path -Path ([string]$decision.review_path))|$($decision.shot_id)"
    $decisionLookup[$key] = $decision
}

$queue = @()
$summary = [ordered]@{
    pending = 0
    pass = 0
    needs_regeneration = 0
    blocked = 0
    missing_workflow = 0
    missing_storyboard = 0
}

foreach ($entry in $reviews) {
    $review = $entry.review
    $reviewId = Get-Review-Id -Review $review -Path $entry.path
    foreach ($shot in @($review.shots)) {
        $key = "$(Normalize-Path -Path $entry.path)|$($shot.shot_id)"
        $decision = if ($decisionLookup.ContainsKey($key)) { $decisionLookup[$key] } else { $null }
        $decisionValue = if ($decision -and $decision.decision) { [string]$decision.decision } else { "pending" }
        if ($summary.Contains($decisionValue)) {
            $summary[$decisionValue] += 1
        }

        $action = ""
        $selectedWorkflow = ""
        $regenerationScope = ""
        if ($decisionValue -eq "pass") {
            $action = "run_i2v"
            $selectedWorkflow = if ($shot.video_workflow) { [string]$shot.video_workflow } else { "" }
            $regenerationScope = "video"
        } elseif ($decisionValue -eq "needs_regeneration") {
            $action = "regenerate_storyboard"
            $selectedWorkflow = if ($shot.storyboard_workflow) { [string]$shot.storyboard_workflow } else { "" }
            $regenerationScope = "storyboard"
        } elseif ($decisionValue -eq "blocked" -and $IncludeBlocked) {
            $action = "manual_blocked"
            $regenerationScope = "manual"
        } elseif ($decisionValue -eq "pending" -and $IncludePending) {
            $action = "pending_review"
            $regenerationScope = "manual"
        }

        if (-not $action) {
            continue
        }

        $storyboardPath = if ($shot.storyboard_path) { [string]$shot.storyboard_path } else { "" }
        $storyboardExists = $storyboardPath -and (Test-Path -LiteralPath $storyboardPath)
        $workflowExists = $selectedWorkflow -and (Test-Path -LiteralPath $selectedWorkflow)
        if (-not $storyboardExists) { $summary.missing_storyboard += 1 }
        if ($action -in @("run_i2v", "regenerate_storyboard") -and -not $workflowExists) { $summary.missing_workflow += 1 }

        $queue += [ordered]@{
            review_id = $reviewId
            review_path = $entry.path
            shot_id = [string]$shot.shot_id
            title = if ($shot.title) { [string]$shot.title } else { "" }
            decision = $decisionValue
            action = $action
            regeneration_scope = $regenerationScope
            reason = if ($decision -and $decision.reason) { [string]$decision.reason } else { "" }
            notes = if ($decision -and $decision.notes) { [string]$decision.notes } else { "" }
            current_status = if ($shot.status) { [string]$shot.status } else { "" }
            storyboard_path = $storyboardPath
            video_path = if ($shot.video_path) { [string]$shot.video_path } else { "" }
            storyboard_workflow = if ($shot.storyboard_workflow) { [string]$shot.storyboard_workflow } else { "" }
            video_workflow = if ($shot.video_workflow) { [string]$shot.video_workflow } else { "" }
            selected_workflow = $selectedWorkflow
            can_auto_run = [bool]($workflowExists -and ($storyboardExists -or $action -eq "regenerate_storyboard"))
        }
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    review_paths = $ReviewPaths
    include_pending = [bool]$IncludePending
    include_blocked = [bool]$IncludeBlocked
    summary = $summary
    queue_count = @($queue).Count
    queue = $queue
    next_actions = @(
        "For pass decisions, run_i2v uses the approved storyboard as the single visual source through the prepared Comfy workflow.",
        "For needs_regeneration decisions, regenerate the storyboard before rebuilding this queue.",
        "Run run_storyboard_i2v_queue.ps1 with -DryRun first."
    )
    ok = ($summary.missing_workflow -eq 0 -and $summary.missing_storyboard -eq 0)
}

New-Item -ItemType Directory -Path (Split-Path $QueuePath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $QueuePath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
