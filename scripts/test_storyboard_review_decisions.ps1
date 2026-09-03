param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01.json",
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json"
    ),
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01_precheck.json",
    [switch]$AllowStaleCurrentStatus
)

$validDecisions = @("pending", "pass", "needs_regeneration", "blocked")

function Normalize-Path {
    param([string]$Path)

    if (-not $Path) { return "" }
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd("\").ToLowerInvariant()
    } catch {
        return $Path.TrimEnd("\").ToLowerInvariant()
    }
}

function Get-Review-Id {
    param($Review, [string]$Path)

    if ($Review.segment_id) { return [string]$Review.segment_id }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path).ToUpperInvariant()
}

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    throw "Decision file not found: $DecisionPath"
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$defaultReviewPaths = @("E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json")
$isDefaultReviewPaths = (@($ReviewPaths).Count -eq 1 -and (Normalize-Path -Path $ReviewPaths[0]) -eq (Normalize-Path -Path $defaultReviewPaths[0]))
if ($isDefaultReviewPaths -and $decisionData.review_index) {
    $indexedReviewPaths = @($decisionData.review_index | ForEach-Object { if ($_.review_path) { [string]$_.review_path } } | Where-Object { $_ })
    if (@($indexedReviewPaths).Count -gt 0) {
        $ReviewPaths = $indexedReviewPaths
    }
}

$shotLookup = @{}
$expectedKeys = @{}
$reviewSummary = @()
foreach ($path in $ReviewPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Review file not found: $path"
    }
    $review = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $reviewId = Get-Review-Id -Review $review -Path $path
    foreach ($shot in @($review.shots)) {
        $key = "$(Normalize-Path -Path $path)|$($shot.shot_id)"
        $shotLookup[$key] = [ordered]@{
            review_id = $reviewId
            review_path = $path
            shot = $shot
        }
        $expectedKeys[$key] = $true
    }
    $reviewSummary += [ordered]@{
        review_id = $reviewId
        review_path = $path
        global_decision = if ($review.global_decision) { [string]$review.global_decision } else { "" }
        shot_count = @($review.shots).Count
    }
}

$seen = @{}
$invalid = @()
$warnings = @()
$missing = @()
$stale = @()
$counts = [ordered]@{
    pending = 0
    pass = 0
    needs_regeneration = 0
    blocked = 0
}

foreach ($decision in @($decisionData.decisions)) {
    $reviewPath = if ($decision.review_path) { [string]$decision.review_path } else { "" }
    $shotId = if ($decision.shot_id) { [string]$decision.shot_id } else { "" }
    $key = "$(Normalize-Path -Path $reviewPath)|$shotId"
    $decisionValue = if ($decision.decision) { [string]$decision.decision } else { "pending" }

    if ($seen.ContainsKey($key)) {
        $invalid += [ordered]@{ review_path = $reviewPath; shot_id = $shotId; reason = "Duplicate decision entry." }
        continue
    }
    $seen[$key] = $true

    if ($decisionValue -notin $validDecisions) {
        $invalid += [ordered]@{ review_path = $reviewPath; shot_id = $shotId; decision = $decisionValue; reason = "Invalid decision." }
        continue
    }
    $counts[$decisionValue] += 1

    if (-not $shotLookup.ContainsKey($key)) {
        $invalid += [ordered]@{ review_path = $reviewPath; shot_id = $shotId; reason = "Decision does not map to a known storyboard review shot." }
        continue
    }

    $entry = $shotLookup[$key]
    $shot = $entry.shot
    $actualStatus = if ($shot.status) { [string]$shot.status } else { "" }
    $recordedStatus = if ($decision.current_status) { [string]$decision.current_status } else { "" }
    if ($recordedStatus -ne $actualStatus) {
        $stale += [ordered]@{
            review_id = $entry.review_id
            shot_id = $shotId
            recorded_status = $recordedStatus
            actual_status = $actualStatus
            reason = "Decision template current_status is stale. Run refresh_storyboard_review_decisions.ps1."
        }
    }

    $storyboardPath = if ($shot.storyboard_path) { [string]$shot.storyboard_path } else { "" }
    if (-not $storyboardPath -or -not (Test-Path -LiteralPath $storyboardPath)) {
        $invalid += [ordered]@{ review_id = $entry.review_id; shot_id = $shotId; storyboard_path = $storyboardPath; reason = "Storyboard path is missing." }
    }

    if ($decisionValue -eq "pass") {
        if (-not $shot.video_workflow -or -not (Test-Path -LiteralPath ([string]$shot.video_workflow))) {
            $invalid += [ordered]@{ review_id = $entry.review_id; shot_id = $shotId; video_workflow = [string]$shot.video_workflow; reason = "Pass decision requires an existing I2V workflow." }
        }
    }

    if ($decisionValue -eq "needs_regeneration") {
        if (-not $shot.storyboard_workflow -or -not (Test-Path -LiteralPath ([string]$shot.storyboard_workflow))) {
            $invalid += [ordered]@{ review_id = $entry.review_id; shot_id = $shotId; storyboard_workflow = [string]$shot.storyboard_workflow; reason = "Regeneration decision requires an existing storyboard workflow." }
        }
        if ([string]::IsNullOrWhiteSpace([string]$decision.reason)) {
            $warnings += [ordered]@{ review_id = $entry.review_id; shot_id = $shotId; decision = $decisionValue; reason = "A reason is recommended for storyboard regeneration." }
        }
    }

    if ($decisionValue -eq "blocked" -and [string]::IsNullOrWhiteSpace([string]$decision.reason)) {
        $warnings += [ordered]@{ review_id = $entry.review_id; shot_id = $shotId; decision = $decisionValue; reason = "A reason is recommended for blocked storyboard decisions." }
    }
}

foreach ($key in $expectedKeys.Keys) {
    if (-not $seen.ContainsKey($key)) {
        $entry = $shotLookup[$key]
        $missing += [ordered]@{
            review_id = $entry.review_id
            review_path = $entry.review_path
            shot_id = [string]$entry.shot.shot_id
            reason = "Decision file is missing a storyboard review shot."
        }
    }
}

$staleIsFailure = (@($stale).Count -gt 0 -and -not $AllowStaleCurrentStatus)
$ok = (@($invalid).Count -eq 0 -and @($missing).Count -eq 0 -and -not $staleIsFailure)

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    review_paths = $ReviewPaths
    counts = $counts
    review_count = @($reviewSummary).Count
    decision_count = @($decisionData.decisions).Count
    invalid_count = @($invalid).Count
    missing_count = @($missing).Count
    stale_count = @($stale).Count
    warning_count = @($warnings).Count
    ready_for_i2v_queue = [bool]($ok -and $counts.pass -gt 0)
    all_storyboards_reviewed = [bool]($ok -and $counts.pending -eq 0)
    reviews = $reviewSummary
    invalid = $invalid
    missing = $missing
    stale = $stale
    warnings = $warnings
    ok = [bool]$ok
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
