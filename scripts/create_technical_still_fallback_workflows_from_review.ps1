param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc09_storyboard_review.json",
    [string]$WorkflowDir = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\technical_still_fallback_workflow_create_result.json",
    [double]$DurationSeconds = 10.0,
    [int]$Fps = 24,
    [int]$Width = 1280,
    [int]$Height = 720,
    [string]$Motion = "slow_push_in",
    [double]$StartZoom = 1.03,
    [double]$EndZoom = 1.10,
    [string]$Codec = "libx264"
)

if (-not (Test-Path -LiteralPath $ReviewPath)) {
    throw "Review file not found: $ReviewPath"
}

$review = Get-Content -LiteralPath $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Path $WorkflowDir -Force | Out-Null

$created = @()
foreach ($shot in @($review.shots)) {
    $storyboardPath = if ($shot.storyboard_path) { [string]$shot.storyboard_path } else { "" }
    if (-not $storyboardPath -or -not (Test-Path -LiteralPath $storyboardPath)) {
        throw "Storyboard image missing for $($shot.shot_id): $storyboardPath"
    }

    $baseShot = ([string]$shot.shot_id) -replace "^TEST_", ""
    $workflowName = "$($baseShot.ToLowerInvariant())_technical_still_fallback_v001.json"
    $workflowPath = Join-Path $WorkflowDir $workflowName
    $filenamePrefix = "AIShortDrama/videos/$($baseShot)_technical_still_fallback_v001"

    $workflow = [ordered]@{
        client_id = "codex-ai-short-drama"
        prompt = [ordered]@{
            "1" = [ordered]@{
                class_type = "StillFrameVideoFallback"
                inputs = [ordered]@{
                    image_path = $storyboardPath
                    filename_prefix = $filenamePrefix
                    duration_seconds = $DurationSeconds
                    fps = $Fps
                    width = $Width
                    height = $Height
                    motion = $Motion
                    start_zoom = $StartZoom
                    end_zoom = $EndZoom
                    codec = $Codec
                }
            }
        }
    }

    $workflow | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $workflowPath -Encoding UTF8
    $created += [ordered]@{
        shot_id = [string]$shot.shot_id
        storyboard_path = $storyboardPath
        workflow_path = $workflowPath
        filename_prefix = $filenamePrefix
        expected_video_path = "G:\ComfyUI\output\$filenamePrefix.mp4"
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = $ReviewPath
    workflow_dir = $WorkflowDir
    duration_seconds = $DurationSeconds
    fps = $Fps
    width = $Width
    height = $Height
    motion = $Motion
    created = $created
    ok = $true
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20
