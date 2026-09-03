param(
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_technical_rough_cut_review.json"
    ),
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01.json",
    [string]$QueuePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\regeneration_queue_ep01.json",
    [switch]$CreateTemplateOnly,
    [switch]$IncludePending,
    [switch]$IncludeTechnicalFallback
)

$validDecisions = @("pending", "pass", "needs_regeneration", "blocked")
$reviews = @()

foreach ($path in $ReviewPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Review file not found: $path"
    }
    $review = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $reviews += [ordered]@{
        path = $path
        review = $review
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
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    return $name.ToUpperInvariant()
}

function Get-Video-Workflow {
    param($Shot, [string]$ReviewPath)

    if ($Shot.final_i2v_workflow) {
        return [string]$Shot.final_i2v_workflow
    }
    if ($Shot.video_workflow -and ([string]$Shot.preferred_video_mode) -notmatch "technical_still_fallback") {
        return [string]$Shot.video_workflow
    }
    if ($Shot.video_workflow -and ([string]$Shot.preferred_video_mode) -match "technical_still_fallback") {
        $candidate = Find-I2V-Workflow -Shot $Shot -ReviewPath $ReviewPath
        if ($candidate) {
            return $candidate
        }
    }
    if ($Shot.video_workflow) {
        return [string]$Shot.video_workflow
    }
    return ""
}

function Find-I2V-Workflow {
    param($Shot, [string]$ReviewPath)

    $workflowDir = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows"
    $reviewName = [System.IO.Path]::GetFileNameWithoutExtension($ReviewPath)
    $segment = ""
    if ($reviewName -match "(ssj_ep01_sc\d+)") {
        $segment = $Matches[1]
    }
    $shotSuffix = ""
    if ([string]$Shot.shot_id -match "SH(\d+)") {
        $shotSuffix = "sh$($Matches[1])"
    }
    if (-not $segment -or -not $shotSuffix -or -not (Test-Path -LiteralPath $workflowDir)) {
        return ""
    }
    $matches = Get-ChildItem -LiteralPath $workflowDir -File -Filter "$($segment)_$($shotSuffix)_i2v*.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "technical|fallback|runway" } |
        Sort-Object LastWriteTime -Descending
    if (@($matches).Count -gt 0) {
        return $matches[0].FullName
    }
    return ""
}

function Get-Storyboard-Workflow {
    param($Shot)

    if ($Shot.storyboard_workflow) {
        return [string]$Shot.storyboard_workflow
    }
    return ""
}

function New-Decision-Template {
    param($Reviews)

    $items = @()
    foreach ($entry in $Reviews) {
        $review = $entry.review
        $reviewId = Get-Review-Id -Review $review -Path $entry.path
        foreach ($shot in $review.shots) {
            $items += [ordered]@{
                review_id = $reviewId
                review_path = $entry.path
                shot_id = $shot.shot_id
                title = if ($shot.title) { [string]$shot.title } else { "" }
                current_status = if ($shot.status) { [string]$shot.status } else { "" }
                decision = "pending"
                regeneration_scope = "video"
                reason = ""
                notes = ""
            }
        }
    }

    return [ordered]@{
        updated = (Get-Date).ToString("s")
        reviewer = ""
        instructions = "Set decision to pass, needs_regeneration, or blocked. regeneration_scope supports storyboard, video, segment, or episode. Leave pending if not reviewed."
        decisions = $items
    }
}

if ((-not (Test-Path -LiteralPath $DecisionPath)) -or $CreateTemplateOnly) {
    $template = New-Decision-Template -Reviews $reviews
    New-Item -ItemType Directory -Path (Split-Path $DecisionPath) -Force | Out-Null
    $template | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $DecisionPath -Encoding UTF8
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        created_template = $DecisionPath
        queue_path = $QueuePath
        template_only = $true
        decisions = @($template.decisions).Count
        ok = $true
    }
    New-Item -ItemType Directory -Path (Split-Path $QueuePath) -Force | Out-Null
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $QueuePath -Encoding UTF8
    $result | ConvertTo-Json -Depth 8
    exit 0
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$decisionLookup = @{}
foreach ($decision in $decisionData.decisions) {
    if ($decision.decision -notin $validDecisions) {
        throw "Invalid decision for $($decision.shot_id): $($decision.decision)"
    }
    $key = "$($decision.review_path)|$($decision.shot_id)"
    $decisionLookup[$key] = $decision
}

$queue = @()
$summary = [ordered]@{
    pass = 0
    pending = 0
    needs_regeneration = 0
    blocked = 0
    technical_fallback = 0
    missing_workflow = 0
}

foreach ($entry in $reviews) {
    $review = $entry.review
    $reviewId = Get-Review-Id -Review $review -Path $entry.path
    foreach ($shot in $review.shots) {
        $key = "$($entry.path)|$($shot.shot_id)"
        $decision = if ($decisionLookup.ContainsKey($key)) { $decisionLookup[$key] } else { $null }
        $decisionValue = if ($decision) { [string]$decision.decision } else { "pending" }
        if (-not $summary.Contains($decisionValue)) {
            $summary[$decisionValue] = 0
        }
        $summary[$decisionValue] += 1

        $isTechnicalFallback = ([string]$shot.preferred_video_mode -match "technical_still_fallback") -or ([string]$shot.status -match "technical_fallback")
        if ($isTechnicalFallback) {
            $summary.technical_fallback += 1
        }

        $shouldQueue = $decisionValue -eq "needs_regeneration" -or $decisionValue -eq "blocked"
        if ($IncludePending -and $decisionValue -eq "pending") {
            $shouldQueue = $true
        }
        if ($IncludeTechnicalFallback -and $isTechnicalFallback -and $decisionValue -ne "pass") {
            $shouldQueue = $true
        }
        if (-not $shouldQueue) {
            continue
        }

        $scope = if ($decision -and $decision.regeneration_scope) { [string]$decision.regeneration_scope } else { "video" }
        $storyboardWorkflow = Get-Storyboard-Workflow -Shot $shot
        $videoWorkflow = Get-Video-Workflow -Shot $shot -ReviewPath $entry.path
        $workflow = ""
        if ($scope -eq "storyboard") {
            $workflow = $storyboardWorkflow
        } elseif ($scope -eq "video") {
            $workflow = $videoWorkflow
        } elseif ($scope -eq "segment" -or $scope -eq "episode") {
            $workflow = ""
        } else {
            $workflow = $videoWorkflow
        }
        if (-not $workflow -and $scope -in @("storyboard", "video")) {
            $summary.missing_workflow += 1
        }

        $queue += [ordered]@{
            review_id = $reviewId
            review_path = $entry.path
            shot_id = $shot.shot_id
            title = if ($shot.title) { [string]$shot.title } else { "" }
            decision = $decisionValue
            regeneration_scope = $scope
            reason = if ($decision -and $decision.reason) { [string]$decision.reason } else { "" }
            notes = if ($decision -and $decision.notes) { [string]$decision.notes } else { "" }
            current_status = if ($shot.status) { [string]$shot.status } else { "" }
            preferred_video_mode = if ($shot.preferred_video_mode) { [string]$shot.preferred_video_mode } else { "" }
            storyboard_path = if ($shot.storyboard_path) { [string]$shot.storyboard_path } else { "" }
            video_path = if ($shot.video_path) { [string]$shot.video_path } else { "" }
            storyboard_workflow = $storyboardWorkflow
            video_workflow = $videoWorkflow
            selected_workflow = $workflow
            can_auto_rerun = [bool]($workflow -and (Test-Path -LiteralPath $workflow))
            is_technical_fallback = [bool]$isTechnicalFallback
        }
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    review_paths = $ReviewPaths
    include_pending = [bool]$IncludePending
    include_technical_fallback = [bool]$IncludeTechnicalFallback
    summary = $summary
    queue_count = @($queue).Count
    queue = $queue
    next_actions = @(
        "Fill human_review_decisions_ep01.json after reviewing the packages.",
        "Run this script again to refresh regeneration_queue_ep01.json.",
        "Auto-rerun only queue items where can_auto_rerun is true and regeneration_scope is storyboard or video."
    )
    ok = $true
}

New-Item -ItemType Directory -Path (Split-Path $QueuePath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $QueuePath -Encoding UTF8
$result | ConvertTo-Json -Depth 20
