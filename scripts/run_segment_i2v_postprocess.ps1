param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json",
    [string]$WorkflowCreateResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_workflow_create_result.json",
    [string]$RefreshResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_i2v_refresh_result.json",
    [string]$ReviewPackageDir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01",
    [string]$ReviewPackageManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_i2v_review_package.json",
    [string]$CutOutputPath = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP02_SC01_technical_preview_cut.mp4",
    [string]$CutManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_technical_preview_cut_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_i2v_postprocess_result.json",
    [switch]$BuildReviewPackage,
    [switch]$BuildTechnicalPreviewCut,
    [switch]$AllowMissingVideos
)

$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root "scripts"
$refreshScript = Join-Path $scripts "refresh_consistency_review_from_outputs.ps1"
$packageScript = Join-Path $scripts "build_review_package.ps1"
$cutScript = Join-Path $scripts "concat_episode_from_review_cv2.ps1"

function Invoke-Step {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$AllowNonZero
    )

    $output = & powershell -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $step = [ordered]@{
        name = $Name
        script = $ScriptPath
        arguments = $Arguments
        exit_code = $exitCode
        output_tail = @($output | Select-Object -Last 18)
        ok = ($exitCode -eq 0 -or [bool]$AllowNonZero)
    }
    $script:steps += $step
    if (-not $step.ok) {
        throw "Step failed: $Name"
    }
    return $output
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $ReviewPath)) {
    throw "Review file not found: $ReviewPath"
}

$steps = @()

try {
    $refreshArgs = @("-ReviewPath", $ReviewPath, "-ResultPath", $RefreshResultPath)
    if ($WorkflowCreateResultPath) {
        $refreshArgs += @("-WorkflowCreateResultPath", $WorkflowCreateResultPath)
    }
    Invoke-Step -Name "refresh_i2v_outputs" -ScriptPath $refreshScript -Arguments $refreshArgs -AllowNonZero:$AllowMissingVideos | Out-Null
    $refresh = Read-JsonFile -Path $RefreshResultPath

    $videosReady = [bool]($refresh -and $refresh.ready_to_review)
    if ($videosReady -and $BuildReviewPackage) {
        Invoke-Step -Name "build_video_review_package" -ScriptPath $packageScript -Arguments @("-ReviewPath", $ReviewPath, "-OutputDir", $ReviewPackageDir, "-ManifestPath", $ReviewPackageManifestPath) | Out-Null
    }

    if ($videosReady -and $BuildTechnicalPreviewCut) {
        Invoke-Step -Name "build_technical_preview_cut" -ScriptPath $cutScript -Arguments @("-ReviewPath", $ReviewPath, "-OutputPath", $CutOutputPath, "-ManifestPath", $CutManifestPath) | Out-Null
    }

    $package = Read-JsonFile -Path $ReviewPackageManifestPath
    $cut = Read-JsonFile -Path $CutManifestPath
    $state = if ($videosReady) { "i2v_outputs_ready_for_human_review" } else { "awaiting_i2v_outputs" }
    if ($videosReady -and $BuildTechnicalPreviewCut -and $cut -and $cut.ok) {
        $state = "technical_preview_cut_built_pending_human_video_review"
    } elseif ($videosReady -and $BuildReviewPackage -and $package -and $package.ok) {
        $state = "video_review_package_built_pending_human_review"
    }

    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        review_path = $ReviewPath
        workflow_create_result_path = $WorkflowCreateResultPath
        state = $state
        build_review_package = [bool]$BuildReviewPackage
        build_technical_preview_cut = [bool]$BuildTechnicalPreviewCut
        allow_missing_videos = [bool]$AllowMissingVideos
        steps = $steps
        refresh = if ($refresh) {
            [ordered]@{
                ready_to_review = [bool]$refresh.ready_to_review
                found_count = @($refresh.found).Count
                invalid_count = @($refresh.invalid).Count
            }
        } else { $null }
        review_package = if ($package) {
            [ordered]@{
                ok = [bool]$package.ok
                markdown_path = if ($package.markdown_path) { [string]$package.markdown_path } else { "" }
                shot_count = @($package.shots).Count
            }
        } else { $null }
        cut = if ($cut) {
            [ordered]@{
                ok = [bool]$cut.ok
                output_path = if ($cut.output_path) { [string]$cut.output_path } else { "" }
                frame_count = if ($cut.frame_count) { [int]$cut.frame_count } else { 0 }
            }
        } else { $null }
        ok = [bool]($videosReady -or $AllowMissingVideos)
    }
} catch {
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        review_path = $ReviewPath
        workflow_create_result_path = $WorkflowCreateResultPath
        state = "postprocess_failed"
        error = $_.Exception.Message
        steps = $steps
        ok = $false
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 30

if (-not $result.ok) {
    exit 1
}
