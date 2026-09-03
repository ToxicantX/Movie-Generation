param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
    [string]$OutputPath = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC01_test_cv2_v001.mp4",
    [string]$ManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_episode_cut_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_postprocess_result.json",
    [switch]$CutWithoutHumanApproval
)

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = $ReviewPath
    output_path = $OutputPath
    refresh = $null
    cut = $null
    ok = $false
    error = $null
}

try {
    $refreshOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\refresh_consistency_review_from_outputs.ps1" -ReviewPath $ReviewPath
    $result.refresh = $refreshOutput | ConvertFrom-Json

    $review = Get-Content -Path $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($review.global_decision -eq "pending_human_consistency_review" -and -not $CutWithoutHumanApproval) {
        throw "Videos are present, but human consistency review is still required. Re-run with -CutWithoutHumanApproval only for technical smoke cuts."
    }
    if ($review.global_decision -notin @("approved_for_episode_cut", "pending_human_consistency_review")) {
        throw "Review is not ready for cut: $($review.global_decision)"
    }

    $cutOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\concat_episode_from_review_cv2.ps1" -ReviewPath $ReviewPath -OutputPath $OutputPath -ManifestPath $ManifestPath
    $result.cut = $cutOutput | ConvertFrom-Json
    $result.ok = [bool]$result.cut.ok
} catch {
    $result.error = $_.Exception.Message
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
