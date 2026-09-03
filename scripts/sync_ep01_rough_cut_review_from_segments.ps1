param(
    [string]$EpisodeReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_technical_rough_cut_review.json",
    [string[]]$SegmentReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_consistency_review.json"
    ),
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_technical_rough_cut_review_sync_result.json"
)

if (-not (Test-Path -LiteralPath $EpisodeReviewPath)) {
    throw "Episode review not found: $EpisodeReviewPath"
}

$episode = Get-Content -LiteralPath $EpisodeReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$segments = @()
foreach ($path in $SegmentReviewPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Segment review not found: $path"
    }
    $review = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $segmentId = if ($review.segment_id) { [string]$review.segment_id } elseif ([System.IO.Path]::GetFileNameWithoutExtension($path) -match "(ssj_ep01_sc\d+)") { $Matches[1].ToUpperInvariant() } else { [System.IO.Path]::GetFileNameWithoutExtension($path).ToUpperInvariant() }
    $hasFallback = $false
    foreach ($shot in @($review.shots)) {
        if ([string]$shot.status -match "technical_fallback" -or [string]$shot.preferred_video_mode -match "technical_fallback|technical_still_fallback" -or [string]$shot.video_path -match "technical_still_fallback") {
            $hasFallback = $true
        }
        if ($shot.checks) {
            foreach ($prop in @($shot.checks.PSObject.Properties)) {
                if ([string]$prop.Value -match "technical_fallback") {
                    $hasFallback = $true
                }
            }
        }
    }
    $segments += [ordered]@{
        segment_id = $segmentId
        review_path = $path
        global_decision = if ($review.global_decision) { [string]$review.global_decision } else { "" }
        has_technical_fallback = [bool]$hasFallback
        shot_count = @($review.shots).Count
    }
}

$updates = @()
foreach ($segment in $segments) {
    if ($segment.segment_id -notmatch "SSJ_EP01_SC(\d+)") {
        continue
    }
    $roughShotId = "SSJ_EP01_ROUGH_SC$($Matches[1])"
    $roughShot = $episode.shots | Where-Object { $_.shot_id -eq $roughShotId } | Select-Object -First 1
    if (-not $roughShot) {
        continue
    }

    $before = [ordered]@{
        status = if ($roughShot.status) { [string]$roughShot.status } else { "" }
        preferred_video_mode = if ($roughShot.preferred_video_mode) { [string]$roughShot.preferred_video_mode } else { "" }
        motion_continuity = if ($roughShot.checks) { [string]$roughShot.checks.motion_continuity } else { "" }
    }

    if ($segment.has_technical_fallback) {
        $roughShot.status = "technical_fallback_pending_human_review"
        $roughShot.preferred_video_mode = "segment_cut_with_technical_fallback"
        if ($roughShot.checks) {
            $roughShot.checks.motion_continuity = "technical_fallback_only"
        }
    } else {
        if ([string]$roughShot.status -match "technical_fallback") {
            $roughShot.status = "generated_pending_human_review"
        }
        if ([string]$roughShot.preferred_video_mode -match "technical_fallback") {
            $roughShot.preferred_video_mode = "segment_cut_for_episode_rough_cut"
        }
        if ($roughShot.checks) {
            foreach ($prop in @($roughShot.checks.PSObject.Properties)) {
                if ([string]$prop.Value -match "technical_fallback") {
                    $roughShot.checks.($prop.Name) = "pending_human_review"
                }
            }
        }
    }

    $roughShot.notes = "Uses $($segment.segment_id) segment-level cut. Source segment fallback markers: $($segment.has_technical_fallback). Segment global decision: $($segment.global_decision)."

    $updates += [ordered]@{
        segment_id = $segment.segment_id
        rough_shot_id = $roughShotId
        has_technical_fallback = [bool]$segment.has_technical_fallback
        before = $before
        after = [ordered]@{
            status = if ($roughShot.status) { [string]$roughShot.status } else { "" }
            preferred_video_mode = if ($roughShot.preferred_video_mode) { [string]$roughShot.preferred_video_mode } else { "" }
            motion_continuity = if ($roughShot.checks) { [string]$roughShot.checks.motion_continuity } else { "" }
        }
    }
}

foreach ($sourceSegment in @($episode.source_segments)) {
    $segment = $segments | Where-Object { $_.segment_id -eq $sourceSegment.segment_id } | Select-Object -First 1
    if (-not $segment) {
        continue
    }
    if ($segment.has_technical_fallback) {
        $sourceSegment.quality_status = "contains_technical_fallback_pending_human_review"
    } elseif ($segment.global_decision -eq "approved_for_episode_cut") {
        $sourceSegment.quality_status = "approved_for_episode_cut"
    } elseif ($segment.global_decision -eq "needs_regeneration") {
        $sourceSegment.quality_status = "needs_regeneration"
    } elseif ($segment.global_decision -eq "blocked") {
        $sourceSegment.quality_status = "blocked"
    } else {
        $sourceSegment.quality_status = "i2v_generated_pending_human_review"
    }
}

$episode.updated = (Get-Date).ToString("yyyy-MM-dd")
if (@($segments | Where-Object { $_.has_technical_fallback }).Count -eq 0) {
    $episode.global_reason = "SC01-SC04 are stitched as an episode-level technical rough cut to validate continuity, runtime, pacing, review package generation, and downstream handoff. Current source segments no longer contain technical fallback footage, but segment-level human consistency review is still pending."
    if ($episode.assembly_policy) {
        $episode.assembly_policy.not_formal_release = $true
        $episode.assembly_policy.requires_before_formal_cut = @(
            "Human consistency review must pass SC01-SC04.",
            "SC04 SH02 no-reference storyboard must be checked for white dragon-deer identity.",
            "Formal gate must pass with every segment shot status/check set to pass."
        )
    }
} else {
    $episode.global_reason = "SC01-SC04 are stitched as an episode-level technical rough cut. One or more source segments still contain technical fallback footage."
    if ($episode.assembly_policy) {
        $fallbackRequirements = @("Human consistency review must pass SC01-SC04.")
        foreach ($segment in @($segments | Where-Object { $_.has_technical_fallback })) {
            $fallbackRequirements += "$($segment.segment_id) technical fallback footage must be replaced with final-quality I2V."
        }
        $episode.assembly_policy.requires_before_formal_cut = $fallbackRequirements
    }
}

$episode | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $EpisodeReviewPath -Encoding UTF8

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    episode_review_path = $EpisodeReviewPath
    segment_reviews = $segments
    updates = $updates
    remaining_technical_fallback_segments = @($segments | Where-Object { $_.has_technical_fallback }).Count
    ok = $true
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20
