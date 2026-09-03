param(
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json"
    ),
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01.json",
    [string]$IndexPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD_INDEX.md",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01_refresh_result.json"
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

    if ($Review.segment_id) {
        return [string]$Review.segment_id
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path).ToUpperInvariant()
}

function Get-Storyboard-Package-Markdown {
    param([string]$ReviewId)

    if ($ReviewId -eq "SSJ_EP02_SC01") {
        return "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD\human_review.md"
    }
    $path = Join-Path "G:\ComfyUI\output\AIShortDrama\review_packages" "$($ReviewId)_STORYBOARD"
    return (Join-Path $path "human_review.md")
}

function Get-Existing-Value {
    param($Existing, [string]$Name, [string]$Default)

    if (-not $Existing) { return $Default }
    $prop = $Existing.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return $Default }
    return [string]$prop.Value
}

$existingLookup = @{}
$reviewer = ""
if (Test-Path -LiteralPath $DecisionPath) {
    $existingData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($existingData.reviewer) {
        $reviewer = [string]$existingData.reviewer
    }
    foreach ($decision in @($existingData.decisions)) {
        $key = "$(Normalize-Path -Path ([string]$decision.review_path))|$($decision.shot_id)"
        $existingLookup[$key] = $decision
    }
}

$decisions = @()
$reviewIndex = @()
$preservedDecisionCount = 0
$staleStatusRepairs = @()

foreach ($path in $ReviewPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Review file not found: $path"
    }
    $review = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $reviewId = Get-Review-Id -Review $review -Path $path
    $packageMarkdown = Get-Storyboard-Package-Markdown -ReviewId $reviewId

    $reviewIndex += [ordered]@{
        review_id = $reviewId
        review_path = $path
        review_package_markdown = $packageMarkdown
        global_decision = if ($review.global_decision) { [string]$review.global_decision } else { "" }
        shot_count = @($review.shots).Count
    }

    foreach ($shot in @($review.shots)) {
        $key = "$(Normalize-Path -Path $path)|$($shot.shot_id)"
        $existing = if ($existingLookup.ContainsKey($key)) { $existingLookup[$key] } else { $null }
        $decisionValue = Get-Existing-Value -Existing $existing -Name "decision" -Default "pending"
        if ($decisionValue -notin $validDecisions) {
            $decisionValue = "pending"
        }
        if ($existing -and $decisionValue -ne "pending") {
            $preservedDecisionCount += 1
        }

        $actualStatus = if ($shot.status) { [string]$shot.status } else { "" }
        $oldStatus = if ($existing -and $existing.current_status) { [string]$existing.current_status } else { "" }
        if ($oldStatus -and $oldStatus -ne $actualStatus) {
            $staleStatusRepairs += [ordered]@{
                review_id = $reviewId
                shot_id = [string]$shot.shot_id
                old_status = $oldStatus
                current_status = $actualStatus
            }
        }

        $decisions += [ordered]@{
            review_id = $reviewId
            review_path = $path
            review_package_markdown = $packageMarkdown
            shot_id = [string]$shot.shot_id
            title = if ($shot.title) { [string]$shot.title } else { "" }
            current_status = $actualStatus
            storyboard_path = if ($shot.storyboard_path) { [string]$shot.storyboard_path } else { "" }
            storyboard_workflow = if ($shot.storyboard_workflow) { [string]$shot.storyboard_workflow } else { "" }
            video_workflow = if ($shot.video_workflow) { [string]$shot.video_workflow } else { "" }
            decision = $decisionValue
            reason = Get-Existing-Value -Existing $existing -Name "reason" -Default ""
            notes = Get-Existing-Value -Existing $existing -Name "notes" -Default ""
        }
    }
}

$decisionData = [ordered]@{
    updated = (Get-Date).ToString("s")
    reviewer = $reviewer
    instructions = "Set decision to pass, needs_regeneration, or blocked. Leave pending if not reviewed. pass queues I2V; needs_regeneration queues storyboard regeneration."
    review_index = $reviewIndex
    decisions = $decisions
}

New-Item -ItemType Directory -Path (Split-Path $DecisionPath) -Force | Out-Null
$decisionData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $DecisionPath -Encoding UTF8

$summary = [ordered]@{
    pending = @($decisions | Where-Object { $_.decision -eq "pending" }).Count
    pass = @($decisions | Where-Object { $_.decision -eq "pass" }).Count
    needs_regeneration = @($decisions | Where-Object { $_.decision -eq "needs_regeneration" }).Count
    blocked = @($decisions | Where-Object { $_.decision -eq "blocked" }).Count
}

$indexLines = @(
    "# Storyboard Review Index",
    "",
    "- Updated: $((Get-Date).ToString("s"))",
    "- Decision file: ``$DecisionPath``",
    "- Import checked Markdown decisions: ``powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\import_storyboard_review_markdown_decisions.ps1``",
    "- Precheck: ``powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\test_storyboard_review_decisions.ps1``",
    "- Build queue: ``powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\build_storyboard_i2v_queue.ps1``",
    "",
    "## Review Packages",
    ""
)

foreach ($review in $reviewIndex) {
    $exists = Test-Path -LiteralPath $review.review_package_markdown
    $indexLines += "- $($review.review_id): ``$($review.review_package_markdown)`` (exists: $exists, global: $($review.global_decision))"
}

$indexLines += @(
    "",
    "## Decision Summary",
    "",
    "- pending: $($summary.pending)",
    "- pass: $($summary.pass)",
    "- needs_regeneration: $($summary.needs_regeneration)",
    "- blocked: $($summary.blocked)",
    "",
    "## Shot Decisions",
    "",
    "| Review | Shot | Status | Decision | Title |",
    "| --- | --- | --- | --- | --- |"
)

foreach ($decision in $decisions) {
    $title = ([string]$decision.title).Replace("|", "/")
    $indexLines += "| $($decision.review_id) | $($decision.shot_id) | $($decision.current_status) | $($decision.decision) | $title |"
}

New-Item -ItemType Directory -Path (Split-Path $IndexPath) -Force | Out-Null
$indexLines -join "`n" | Set-Content -LiteralPath $IndexPath -Encoding UTF8

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    index_path = $IndexPath
    review_count = @($reviewIndex).Count
    decision_count = @($decisions).Count
    preserved_non_pending_decision_count = $preservedDecisionCount
    stale_status_repair_count = @($staleStatusRepairs).Count
    stale_status_repairs = $staleStatusRepairs
    summary = $summary
    ok = $true
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20
