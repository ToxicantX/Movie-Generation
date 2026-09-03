param(
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_consistency_review.json"
    ),
    [string[]]$SegmentCutPaths = @(
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC01_test_cv2_v001.mp4",
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC02_technical_smoke_cut.mp4",
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC03_technical_smoke_cut.mp4",
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC04_technical_smoke_cut.mp4"
    ),
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep01_formal_cut_gate_check.json",
    [string]$PythonPath = "python",
    [string]$VideoProbePath = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\probe_video_cv2.py",
    [switch]$SkipSegmentCutChecks
)

function Test-VideoFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            path = ""
            exists = $false
            ok = $false
            error = "missing_path"
            fps = 0
            width = 0
            height = 0
            frame_count = 0
            bytes = 0
        }
    }

    try {
        $json = & $PythonPath $VideoProbePath $Path
        if (-not $json) {
            return [pscustomobject]@{
                path = $Path
                exists = (Test-Path -LiteralPath $Path)
                ok = $false
                error = "python_probe_failed"
                fps = 0
                width = 0
                height = 0
                frame_count = 0
                bytes = 0
            }
        }
        return ($json | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            path = $Path
            exists = (Test-Path -LiteralPath $Path)
            ok = $false
            error = $_.Exception.Message
            fps = 0
            width = 0
            height = 0
            frame_count = 0
            bytes = 0
        }
    }
}

function Add-Failure {
    param([string]$Scope, [string]$Id, [string]$Reason)

    $script:failures += [ordered]@{
        scope = $Scope
        id = $Id
        reason = $Reason
    }
}

$failures = @()
$reviewResults = @()
$segmentCutResults = @()

foreach ($reviewPath in $ReviewPaths) {
    $reviewFailures = @()
    $shotResults = @()

    if (-not (Test-Path -LiteralPath $reviewPath)) {
        Add-Failure -Scope "review" -Id $reviewPath -Reason "Review file not found."
        $reviewResults += [ordered]@{
            review_path = $reviewPath
            ok = $false
            failures = @("Review file not found.")
            shots = @()
        }
        continue
    }

    try {
        $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Add-Failure -Scope "review" -Id $reviewPath -Reason "Review JSON parse failed: $($_.Exception.Message)"
        $reviewResults += [ordered]@{
            review_path = $reviewPath
            ok = $false
            failures = @("Review JSON parse failed: $($_.Exception.Message)")
            shots = @()
        }
        continue
    }

    if ($review.segment_id) {
        $segmentId = [string]$review.segment_id
    } elseif ([System.IO.Path]::GetFileNameWithoutExtension($reviewPath) -match "(ssj_ep01_sc\d+)") {
        $segmentId = $Matches[1].ToUpperInvariant()
    } else {
        $segmentId = [System.IO.Path]::GetFileNameWithoutExtension($reviewPath).ToUpperInvariant()
    }
    if ([string]$review.global_decision -ne "approved_for_episode_cut") {
        $reason = "global_decision must be approved_for_episode_cut, found '$($review.global_decision)'."
        $reviewFailures += $reason
        Add-Failure -Scope "review" -Id $segmentId -Reason $reason
    }

    foreach ($shot in @($review.shots)) {
        $shotId = if ($shot.shot_id) { [string]$shot.shot_id } else { "unknown_shot" }
        $shotFailures = @()

        if ([string]$shot.status -ne "pass") {
            $shotFailures += "status must be pass, found '$($shot.status)'."
        }
        if ([string]$shot.status -match "technical_fallback") {
            $shotFailures += "status contains technical_fallback."
        }
        if ([string]$shot.preferred_video_mode -match "technical_still_fallback|technical_fallback") {
            $shotFailures += "preferred_video_mode contains technical fallback mode."
        }
        if ([string]$shot.video_path -match "technical_still_fallback") {
            $shotFailures += "video_path points to a technical still fallback file."
        }

        if (-not $shot.checks) {
            $shotFailures += "checks object is missing."
        } else {
            foreach ($prop in @($shot.checks.PSObject.Properties)) {
                if ([string]$prop.Value -ne "pass") {
                    $shotFailures += "check '$($prop.Name)' must be pass, found '$($prop.Value)'."
                }
            }
        }

        $videoProbe = Test-VideoFile -Path ([string]$shot.video_path)
        if (-not $videoProbe.ok) {
            $shotFailures += "video_path is missing or not decodable: $($videoProbe.error)."
        }

        foreach ($failure in $shotFailures) {
            Add-Failure -Scope "shot" -Id "$segmentId/$shotId" -Reason $failure
        }

        $shotResults += [ordered]@{
            shot_id = $shotId
            title = if ($shot.title) { [string]$shot.title } else { "" }
            status = if ($shot.status) { [string]$shot.status } else { "" }
            preferred_video_mode = if ($shot.preferred_video_mode) { [string]$shot.preferred_video_mode } else { "" }
            video_path = if ($shot.video_path) { [string]$shot.video_path } else { "" }
            video_probe = $videoProbe
            failures = $shotFailures
            ok = (@($shotFailures).Count -eq 0)
        }
    }

    $reviewResults += [ordered]@{
        review_path = $reviewPath
        segment_id = $segmentId
        global_decision = if ($review.global_decision) { [string]$review.global_decision } else { "" }
        failures = $reviewFailures
        shots = $shotResults
        ok = (@($reviewFailures).Count -eq 0 -and @($shotResults | Where-Object { -not $_.ok }).Count -eq 0)
    }
}

$segmentCutPathOutput = @()
if (-not $SkipSegmentCutChecks) {
    foreach ($segmentCutPath in $SegmentCutPaths) {
        $segmentCutPathOutput += $segmentCutPath
        $probe = Test-VideoFile -Path $segmentCutPath
        if (-not $probe.ok) {
            Add-Failure -Scope "segment_cut" -Id $segmentCutPath -Reason "Segment cut is missing or not decodable: $($probe.error)."
        }
        $segmentCutResults += [ordered]@{
            path = $segmentCutPath
            video_probe = $probe
            ok = [bool]$probe.ok
        }
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_paths = $ReviewPaths
    segment_cut_paths = @($segmentCutPathOutput)
    video_probe_path = $VideoProbePath
    skipped_segment_cut_checks = [bool]$SkipSegmentCutChecks
    reviews = $reviewResults
    segment_cuts = $segmentCutResults
    failure_count = @($failures).Count
    failures = $failures
    ok = (@($failures).Count -eq 0)
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 30

if (-not $result.ok) {
    exit 1
}
