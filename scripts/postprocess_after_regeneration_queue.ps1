param(
    [string]$QueueRunResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\regeneration_queue_ep01_run_result.json",
    [string]$QueuePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\regeneration_queue_ep01.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\postprocess_after_regeneration_queue_result.json",
    [switch]$DryRun,
    [switch]$IncludePendingQueueItems
)

$segmentConfig = @{
    "SSJ_EP01_SC01" = @{
        review = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json"
        review_package_dir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_SC01"
        review_package_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_review_package.json"
        cut = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC01_test_cv2_v001.mp4"
        cut_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_episode_cut_result.json"
        postprocess_result = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_postprocess_result.json"
    }
    "SSJ_EP01_SC02" = @{
        review = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_consistency_review.json"
        review_package_dir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_SC02"
        review_package_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_review_package.json"
        cut = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC02_technical_smoke_cut.mp4"
        cut_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_technical_smoke_cut_result.json"
        postprocess_result = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_postprocess_smoke_result.json"
    }
    "SSJ_EP01_SC03" = @{
        review = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_consistency_review.json"
        review_package_dir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_SC03"
        review_package_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_review_package.json"
        cut = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC03_technical_smoke_cut.mp4"
        cut_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_technical_smoke_cut_result.json"
        postprocess_result = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_postprocess_smoke_result.json"
    }
    "SSJ_EP01_SC04" = @{
        review = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_consistency_review.json"
        review_package_dir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_SC04"
        review_package_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_review_package.json"
        cut = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC04_technical_smoke_cut.mp4"
        cut_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_technical_smoke_cut_result.json"
        postprocess_result = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_postprocess_smoke_result.json"
    }
}

$episodeConfig = @{
    review = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_technical_rough_cut_review.json"
    cut = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_technical_rough_cut_v001.mp4"
    cut_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_technical_rough_cut_result.json"
    review_package_dir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_TECHNICAL_ROUGH_CUT"
    review_package_manifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_technical_rough_cut_review_package.json"
}

function Add-Step {
    param([string]$Name, [string]$Command, [string]$Kind)
    $script:steps += [ordered]@{
        name = $Name
        kind = $Kind
        command = $Command
        status = if ($DryRun) { "dry_run" } else { "pending" }
        exit_code = $null
        output = @()
    }
}

function Run-Step {
    param($Step)
    if ($DryRun) {
        return
    }
    $output = & powershell -ExecutionPolicy Bypass -Command $Step.command
    $exitCode = $LASTEXITCODE
    $Step.exit_code = $exitCode
    $Step.output = @($output)
    $Step.status = if ($exitCode -eq 0) { "success" } else { "failed" }
    if ($exitCode -ne 0) {
        $script:ok = $false
    }
}

function Get-Segment-Ids {
    $ids = New-Object System.Collections.Generic.HashSet[string]
    if (Test-Path -LiteralPath $QueueRunResultPath) {
        $run = Get-Content -LiteralPath $QueueRunResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in @($run.runs)) {
            if ($item.status -in @("success", "dry_run") -and $item.review_id -match "^SSJ_EP01_SC\d+$") {
                $null = $ids.Add([string]$item.review_id)
            }
        }
    }
    if ($IncludePendingQueueItems -and (Test-Path -LiteralPath $QueuePath)) {
        $queue = Get-Content -LiteralPath $QueuePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in @($queue.queue)) {
            if ($item.can_auto_rerun -and $item.review_id -match "^SSJ_EP01_SC\d+$") {
                $null = $ids.Add([string]$item.review_id)
            }
        }
    }
    return @($ids)
}

$steps = @()
$ok = $true
$segments = Get-Segment-Ids

foreach ($segmentId in $segments | Sort-Object) {
    if (-not $segmentConfig.ContainsKey($segmentId)) {
        continue
    }
    $cfg = $segmentConfig[$segmentId]
    Add-Step -Name "$segmentId refresh review" -Kind "segment_refresh" -Command "powershell -ExecutionPolicy Bypass -File 'E:\workspace\ComfyUIProjects\Movie-Generation\scripts\refresh_consistency_review_from_outputs.ps1' -ReviewPath '$($cfg.review)' -ResultPath 'E:\workspace\ComfyUIProjects\Movie-Generation\manifests\$($segmentId.ToLowerInvariant())_refresh_after_regeneration.json'"
    Add-Step -Name "$segmentId build review package" -Kind "segment_review_package" -Command "powershell -ExecutionPolicy Bypass -File 'E:\workspace\ComfyUIProjects\Movie-Generation\scripts\build_review_package.ps1' -ReviewPath '$($cfg.review)' -OutputDir '$($cfg.review_package_dir)' -ManifestPath '$($cfg.review_package_manifest)' -PythonPath 'python'"
    Add-Step -Name "$segmentId rebuild smoke cut" -Kind "segment_cut" -Command "powershell -ExecutionPolicy Bypass -File 'E:\workspace\ComfyUIProjects\Movie-Generation\scripts\postprocess_episode_after_i2v.ps1' -ReviewPath '$($cfg.review)' -OutputPath '$($cfg.cut)' -ManifestPath '$($cfg.cut_manifest)' -ResultPath '$($cfg.postprocess_result)' -CutWithoutHumanApproval"
}

if (@($segments).Count -gt 0) {
    Add-Step -Name "EP01 rebuild technical rough cut" -Kind "episode_cut" -Command "powershell -ExecutionPolicy Bypass -File 'E:\workspace\ComfyUIProjects\Movie-Generation\scripts\concat_episode_from_review_cv2.ps1' -ReviewPath '$($episodeConfig.review)' -OutputPath '$($episodeConfig.cut)' -ManifestPath '$($episodeConfig.cut_manifest)' -PythonPath 'python'"
    Add-Step -Name "EP01 rebuild rough cut review package" -Kind "episode_review_package" -Command "powershell -ExecutionPolicy Bypass -File 'E:\workspace\ComfyUIProjects\Movie-Generation\scripts\build_review_package.ps1' -ReviewPath '$($episodeConfig.review)' -OutputDir '$($episodeConfig.review_package_dir)' -ManifestPath '$($episodeConfig.review_package_manifest)' -PythonPath 'python'"
}

foreach ($step in $steps) {
    Run-Step -Step $step
    if (-not $ok) {
        break
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    queue_run_result_path = $QueueRunResultPath
    queue_path = $QueuePath
    dry_run = [bool]$DryRun
    include_pending_queue_items = [bool]$IncludePendingQueueItems
    affected_segments = $segments
    step_count = @($steps).Count
    steps = $steps
    ok = $ok
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $ok) {
    exit 1
}
