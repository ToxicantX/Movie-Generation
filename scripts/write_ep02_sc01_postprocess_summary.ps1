param(
    [string]$RefreshResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_i2v_refresh_result.json",
    [string]$ReviewPackageManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_i2v_review_package.json",
    [string]$CutManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_technical_preview_cut_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_i2v_postprocess_result.json"
)

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

$refresh = Read-JsonFile -Path $RefreshResultPath
$package = Read-JsonFile -Path $ReviewPackageManifestPath
$cut = Read-JsonFile -Path $CutManifestPath

$videosReady = [bool]($refresh -and $refresh.ready_to_review)
$packageReady = [bool]($package -and $package.ok)
$cutReady = [bool]($cut -and $cut.ok)

$state = "awaiting_i2v_outputs"
if ($videosReady -and $packageReady -and $cutReady) {
    $state = "technical_preview_cut_built_pending_human_video_review"
} elseif ($videosReady -and $packageReady) {
    $state = "video_review_package_built_pending_human_review"
} elseif ($videosReady) {
    $state = "i2v_outputs_ready_for_human_review"
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = if ($refresh) { [string]$refresh.review_path } else { "" }
    workflow_create_result_path = if ($refresh) { [string]$refresh.workflow_create_result_path } else { "" }
    state = $state
    build_review_package = $packageReady
    build_technical_preview_cut = $cutReady
    allow_missing_videos = $false
    steps = @(
        [ordered]@{ name = "refresh_i2v_outputs"; ok = $videosReady; result_path = $RefreshResultPath },
        [ordered]@{ name = "build_video_review_package"; ok = $packageReady; result_path = $ReviewPackageManifestPath },
        [ordered]@{ name = "build_technical_preview_cut"; ok = $cutReady; result_path = $CutManifestPath }
    )
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
            fps = if ($cut.fps) { [double]$cut.fps } else { 0 }
            bytes = if ($cut.bytes) { [int64]$cut.bytes } else { 0 }
        }
    } else { $null }
    ok = [bool]($videosReady -and $packageReady -and $cutReady)
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
