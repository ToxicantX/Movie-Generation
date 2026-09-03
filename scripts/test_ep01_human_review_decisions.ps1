param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01.json",
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_technical_rough_cut_review.json"
    ),
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01_precheck.json",
    [switch]$AllowTechnicalFallbackPass,
    [switch]$AllowStaleCurrentStatus
)

$validDecisions = @("pending", "pass", "needs_regeneration", "blocked")
$validScopes = @("storyboard", "video", "segment", "episode")

function Normalize-Path {
    param([string]$Path)

    if (-not $Path) {
        return ""
    }
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd("\").ToLowerInvariant()
    } catch {
        return $Path.TrimEnd("\").ToLowerInvariant()
    }
}

function Get-Review-Id {
    param($Review, [string]$Path)

    if ($Review.segment_id) {
        $segmentId = [string]$Review.segment_id
        if ($segmentId -match "(SSJ_EP01_SC\d+)") {
            return $Matches[1]
        }
        return $segmentId
    }
    if ($Review.episode_id) {
        return [string]$Review.episode_id
    }
    if ([System.IO.Path]::GetFileNameWithoutExtension($Path) -match "(ssj_ep01_sc\d+)") {
        return $Matches[1].ToUpperInvariant()
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path).ToUpperInvariant()
}

function Test-TechnicalFallbackShot {
    param($Shot)

    if ([string]$Shot.status -match "technical_fallback") {
        return $true
    }
    if ([string]$Shot.preferred_video_mode -match "technical_still_fallback|technical_fallback") {
        return $true
    }
    if ([string]$Shot.video_path -match "technical_still_fallback") {
        return $true
    }
    if ($Shot.checks) {
        foreach ($prop in @($Shot.checks.PSObject.Properties)) {
            if ([string]$prop.Value -match "technical_fallback") {
                return $true
            }
        }
    }
    return $false
}

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    throw "Decision file not found: $DecisionPath"
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

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$seen = @{}
$invalid = @()
$warnings = @()
$stale = @()
$missing = @()
$unsafePasses = @()
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
    $scope = if ($decision.regeneration_scope) { [string]$decision.regeneration_scope } else { "video" }

    if ($seen.ContainsKey($key)) {
        $invalid += [ordered]@{
            review_path = $reviewPath
            shot_id = $shotId
            reason = "Duplicate decision entry."
        }
        continue
    }
    $seen[$key] = $true

    if ($decisionValue -notin $validDecisions) {
        $invalid += [ordered]@{
            review_path = $reviewPath
            shot_id = $shotId
            decision = $decisionValue
            reason = "Invalid decision. Use pending, pass, needs_regeneration, or blocked."
        }
        continue
    }
    $counts[$decisionValue] += 1

    if ($scope -notin $validScopes) {
        $invalid += [ordered]@{
            review_path = $reviewPath
            shot_id = $shotId
            regeneration_scope = $scope
            reason = "Invalid regeneration_scope. Use storyboard, video, segment, or episode."
        }
    }

    if (-not $shotLookup.ContainsKey($key)) {
        $invalid += [ordered]@{
            review_path = $reviewPath
            shot_id = $shotId
            reason = "Decision does not map to a known review shot."
        }
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
            reason = "Decision template current_status is stale. Run refresh_ep01_human_review_decisions.ps1."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$shot.video_path) -and -not (Test-Path -LiteralPath ([string]$shot.video_path))) {
        $invalid += [ordered]@{
            review_path = $reviewPath
            shot_id = $shotId
            video_path = [string]$shot.video_path
            reason = "Review video_path does not exist."
        }
    }

    $isTechnicalFallback = Test-TechnicalFallbackShot -Shot $shot
    if ($decisionValue -eq "pass" -and $isTechnicalFallback -and -not $AllowTechnicalFallbackPass) {
        $unsafePasses += [ordered]@{
            review_id = $entry.review_id
            review_path = $reviewPath
            shot_id = $shotId
            reason = "Technical fallback footage cannot be approved for formal EP01 without explicit override."
        }
    }

    if ($decisionValue -in @("needs_regeneration", "blocked") -and [string]::IsNullOrWhiteSpace([string]$decision.reason)) {
        $warnings += [ordered]@{
            review_id = $entry.review_id
            shot_id = $shotId
            decision = $decisionValue
            reason = "A reason is recommended for regeneration/block decisions."
        }
    }
}

foreach ($key in $expectedKeys.Keys) {
    if (-not $seen.ContainsKey($key)) {
        $entry = $shotLookup[$key]
        $missing += [ordered]@{
            review_id = $entry.review_id
            review_path = $entry.review_path
            shot_id = [string]$entry.shot.shot_id
            reason = "Decision file is missing a review shot."
        }
    }
}

$staleIsFailure = (@($stale).Count -gt 0 -and -not $AllowStaleCurrentStatus)
$ok = (@($invalid).Count -eq 0 -and @($missing).Count -eq 0 -and @($unsafePasses).Count -eq 0 -and -not $staleIsFailure)
$segmentDecisionCount = @($decisionData.decisions | Where-Object { [string]$_.review_id -match "^SSJ_EP01_SC\d+$" }).Count
$segmentPassCount = @($decisionData.decisions | Where-Object { [string]$_.review_id -match "^SSJ_EP01_SC\d+$" -and [string]$_.decision -eq "pass" }).Count

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    review_paths = $ReviewPaths
    allow_technical_fallback_pass = [bool]$AllowTechnicalFallbackPass
    allow_stale_current_status = [bool]$AllowStaleCurrentStatus
    counts = $counts
    review_count = @($reviewSummary).Count
    decision_count = @($decisionData.decisions).Count
    segment_decision_count = $segmentDecisionCount
    segment_pass_count = $segmentPassCount
    invalid_count = @($invalid).Count
    missing_count = @($missing).Count
    stale_count = @($stale).Count
    unsafe_pass_count = @($unsafePasses).Count
    warning_count = @($warnings).Count
    ready_for_apply = [bool]($ok -and ($counts.pass + $counts.needs_regeneration + $counts.blocked) -gt 0)
    formal_segments_all_marked_pass = [bool]($segmentDecisionCount -gt 0 -and $segmentDecisionCount -eq $segmentPassCount)
    reviews = $reviewSummary
    invalid = $invalid
    missing = $missing
    stale = $stale
    unsafe_passes = $unsafePasses
    warnings = $warnings
    ok = [bool]$ok
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
