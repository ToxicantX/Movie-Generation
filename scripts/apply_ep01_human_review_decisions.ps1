param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01.json",
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_consistency_review.json"
    ),
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01_apply_result.json",
    [switch]$DryRun,
    [switch]$AllowTechnicalFallbackPass
)

$validDecisions = @("pending", "pass", "needs_regeneration", "blocked")

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

function Test-TechnicalFallbackShot {
    param($Shot)

    $mode = if ($Shot.preferred_video_mode) { [string]$Shot.preferred_video_mode } else { "" }
    $status = if ($Shot.status) { [string]$Shot.status } else { "" }
    $videoPath = if ($Shot.video_path) { [string]$Shot.video_path } else { "" }
    if ($mode -match "technical_still_fallback|technical_fallback") {
        return $true
    }
    if ($status -match "technical_fallback") {
        return $true
    }
    if ($videoPath -match "technical_still_fallback") {
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

function Add-Note {
    param($Shot, [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }
    $existing = if ($Shot.notes) { [string]$Shot.notes } else { "" }
    if ($existing) {
        $Shot.notes = "$existing`nHuman review: $Text"
    } else {
        $Shot.notes = "Human review: $Text"
    }
}

function Set-HumanReviewMetadata {
    param($Shot, $DecisionData, $DecisionValue, [string]$Reviewer)

    $metadata = [ordered]@{
        updated = (Get-Date).ToString("s")
        reviewer = $Reviewer
        decision = $DecisionValue
        regeneration_scope = if ($DecisionData.regeneration_scope) { [string]$DecisionData.regeneration_scope } else { "video" }
        reason = if ($DecisionData.reason) { [string]$DecisionData.reason } else { "" }
        notes = if ($DecisionData.notes) { [string]$DecisionData.notes } else { "" }
    }
    $Shot | Add-Member -NotePropertyName "human_review" -NotePropertyValue $metadata -Force
}

function Apply-ShotDecision {
    param($Shot, $DecisionData, [string]$DecisionValue, [string]$Reviewer)

    if ($DecisionValue -eq "pass") {
        $Shot.status = "pass"
        if ($Shot.checks) {
            foreach ($prop in @($Shot.checks.PSObject.Properties)) {
                if ($prop.Value -in @("pending", "pending_human_review")) {
                    $Shot.checks.($prop.Name) = "pass"
                }
            }
        }
    } elseif ($DecisionValue -eq "needs_regeneration") {
        $Shot.status = "needs_regeneration"
        if ($Shot.checks) {
            foreach ($prop in @($Shot.checks.PSObject.Properties)) {
                if ($prop.Value -in @("pending", "pending_human_review")) {
                    $Shot.checks.($prop.Name) = "needs_regeneration"
                }
            }
        }
    } elseif ($DecisionValue -eq "blocked") {
        $Shot.status = "blocked"
    }

    Add-Note -Shot $Shot -Text ([string]$DecisionData.notes)
    Set-HumanReviewMetadata -Shot $Shot -DecisionData $DecisionData -DecisionValue $DecisionValue -Reviewer $Reviewer
}

function Update-ReviewGlobalDecision {
    param($Review)

    $statuses = @($Review.shots | ForEach-Object { [string]$_.status })
    if (@($statuses).Count -eq 0) {
        $Review.global_decision = "not_ready_for_episode_cut"
        $Review.global_reason = "Review has no shots."
        return
    }
    if ($statuses -contains "needs_regeneration") {
        $Review.global_decision = "needs_regeneration"
        $Review.global_reason = "At least one shot failed human consistency review."
    } elseif ($statuses -contains "blocked") {
        $Review.global_decision = "blocked"
        $Review.global_reason = "At least one shot is blocked by human review."
    } elseif (($statuses | Where-Object { $_ -ne "pass" }).Count -eq 0) {
        $Review.global_decision = "approved_for_episode_cut"
        $Review.global_reason = "All shots passed human consistency review."
    } else {
        $Review.global_decision = "pending_human_consistency_review"
        $Review.global_reason = "One or more shots still require human consistency review."
    }
    $Review.updated = (Get-Date).ToString("yyyy-MM-dd")
}

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    throw "Decision file not found: $DecisionPath"
}

$reviewLookup = @{}
$reviewEntries = @()
foreach ($path in $ReviewPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Review file not found: $path"
    }
    $review = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = [ordered]@{
        path = $path
        key = Normalize-Path -Path $path
        review = $review
        changed = $false
    }
    $reviewEntries += $entry
    $reviewLookup[$entry.key] = $entry
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$reviewer = if ($decisionData.reviewer) { [string]$decisionData.reviewer } else { "" }
$applied = @()
$skipped = @()
$invalid = @()
$unsafePasses = @()

foreach ($decision in @($decisionData.decisions)) {
    $decisionValue = if ($decision.decision) { [string]$decision.decision } else { "pending" }
    if ($decisionValue -notin $validDecisions) {
        $invalid += [ordered]@{
            review_path = if ($decision.review_path) { [string]$decision.review_path } else { "" }
            shot_id = if ($decision.shot_id) { [string]$decision.shot_id } else { "" }
            decision = $decisionValue
            reason = "Invalid decision. Use pending, pass, needs_regeneration, or blocked."
        }
        continue
    }
    if ($decisionValue -eq "pending") {
        $skipped += [ordered]@{
            review_path = if ($decision.review_path) { [string]$decision.review_path } else { "" }
            shot_id = if ($decision.shot_id) { [string]$decision.shot_id } else { "" }
            decision = $decisionValue
            reason = "Pending decisions do not mutate review files."
        }
        continue
    }

    $key = Normalize-Path -Path ([string]$decision.review_path)
    if (-not $reviewLookup.ContainsKey($key)) {
        $skipped += [ordered]@{
            review_path = if ($decision.review_path) { [string]$decision.review_path } else { "" }
            shot_id = if ($decision.shot_id) { [string]$decision.shot_id } else { "" }
            decision = $decisionValue
            reason = "Decision is outside the configured SC01-SC04 segment reviews."
        }
        continue
    }

    $entry = $reviewLookup[$key]
    $shot = $entry.review.shots | Where-Object { $_.shot_id -eq $decision.shot_id } | Select-Object -First 1
    if (-not $shot) {
        $invalid += [ordered]@{
            review_path = [string]$decision.review_path
            shot_id = [string]$decision.shot_id
            decision = $decisionValue
            reason = "Unknown shot_id for the target review."
        }
        continue
    }

    $isTechnicalFallback = Test-TechnicalFallbackShot -Shot $shot
    if ($decisionValue -eq "pass" -and $isTechnicalFallback -and -not $AllowTechnicalFallbackPass) {
        $unsafePasses += [ordered]@{
            review_path = [string]$decision.review_path
            shot_id = [string]$decision.shot_id
            decision = $decisionValue
            reason = "Technical fallback footage cannot be passed by the EP01 batch formal-review apply script. Replace it with final-quality I2V first, or use -AllowTechnicalFallbackPass only for non-formal review experiments."
        }
        continue
    }

    Apply-ShotDecision -Shot $shot -DecisionData $decision -DecisionValue $decisionValue -Reviewer $reviewer
    $entry.changed = $true
    $applied += [ordered]@{
        review_path = [string]$decision.review_path
        shot_id = [string]$decision.shot_id
        decision = $decisionValue
        status = [string]$shot.status
        technical_fallback = [bool]$isTechnicalFallback
    }
}

$reviewSummaries = @()
foreach ($entry in $reviewEntries) {
    if ($entry.changed) {
        Update-ReviewGlobalDecision -Review $entry.review
        if (-not $DryRun) {
            $entry.review | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $entry.path -Encoding UTF8
        }
    }
    $reviewSummaries += [ordered]@{
        review_path = $entry.path
        changed = [bool]$entry.changed
        global_decision = if ($entry.review.global_decision) { [string]$entry.review.global_decision } else { "" }
        shot_statuses = @($entry.review.shots | ForEach-Object {
            [ordered]@{
                shot_id = [string]$_.shot_id
                status = if ($_.status) { [string]$_.status } else { "" }
            }
        })
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    review_paths = $ReviewPaths
    dry_run = [bool]$DryRun
    allow_technical_fallback_pass = [bool]$AllowTechnicalFallbackPass
    applied_count = @($applied).Count
    skipped_count = @($skipped).Count
    invalid_count = @($invalid).Count
    unsafe_pass_count = @($unsafePasses).Count
    applied = $applied
    skipped = $skipped
    invalid = $invalid
    unsafe_passes = $unsafePasses
    reviews = $reviewSummaries
    ok = (@($invalid).Count -eq 0 -and @($unsafePasses).Count -eq 0)
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
