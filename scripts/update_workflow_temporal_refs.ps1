param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
    [string]$ReviewPackageManifest = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_review_package.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_temporal_ref_update.json",
    [string]$StrategyPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\video_reference_strategy.json"
)

$workflowByShot = @{
    "TEST_SSJ_EP01_SC01_SH01" = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh01_i2v_retry.json"
    "TEST_SSJ_EP01_SC01_SH02" = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh02_i2v_retry.json"
    "TEST_SSJ_EP01_SC01_SH03" = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh03_i2v_retry.json"
}

if (-not (Test-Path -LiteralPath $ReviewPath)) {
    throw "Review file not found: $ReviewPath"
}
if (-not (Test-Path -LiteralPath $ReviewPackageManifest)) {
    throw "Review package manifest not found: $ReviewPackageManifest"
}

$review = Get-Content -Path $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$package = Get-Content -Path $ReviewPackageManifest -Raw -Encoding UTF8 | ConvertFrom-Json
$strategy = $null
if (Test-Path -LiteralPath $StrategyPath) {
    $strategy = Get-Content -Path $StrategyPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$updates = @()

for ($i = 0; $i -lt $review.shots.Count; $i++) {
    $shot = $review.shots[$i]
    $workflowPath = $workflowByShot[$shot.shot_id]
    if (-not $workflowPath) {
        continue
    }

    $workflow = Get-Content -Path $workflowPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $inputs = $workflow.prompt.'1'.inputs
    $shotStrategy = $null
    if ($strategy -and $strategy.shots) {
        $shotStrategy = $strategy.shots | Where-Object { $_.shot_id -eq $shot.shot_id } | Select-Object -First 1
    }
    $allowTemporalRefs = -not ($shotStrategy -and $shotStrategy.allow_temporal_refs -eq $false)
    $allowExtraReferenceImages = -not ($shotStrategy -and $shotStrategy.allow_extra_reference_images -eq $false)
    $existing = @()
    if ($allowExtraReferenceImages -and $inputs.reference_image_paths) {
        $existing = @($inputs.reference_image_paths -split "`n" | Where-Object { $_.Trim() })
    }

    $temporalRefs = @()
    if ($allowTemporalRefs -and $i -gt 0) {
        $prevShot = $review.shots[$i - 1]
        $prevPackage = $package.shots | Where-Object { $_.shot_id -eq $prevShot.shot_id } | Select-Object -First 1
        if ($prevPackage -and $prevPackage.frames.last.path) {
            $temporalRefs += $prevPackage.frames.last.path
        }
    }

    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($path in ($existing + $temporalRefs)) {
        $trimmed = $path.Trim()
        if (-not $trimmed) {
            continue
        }
        if (-not ($merged -contains $trimmed)) {
            $merged.Add($trimmed)
        }
    }

    $value = ($merged -join "`n")
    if ($inputs.PSObject.Properties.Name -contains "reference_image_paths") {
        $inputs.reference_image_paths = $value
    } else {
        $inputs | Add-Member -NotePropertyName reference_image_paths -NotePropertyValue $value
    }
    $workflow | ConvertTo-Json -Depth 20 | Set-Content -Path $workflowPath -Encoding UTF8

    $updates += [ordered]@{
        shot_id = $shot.shot_id
        workflow = $workflowPath
        temporal_refs = $temporalRefs
        allow_temporal_refs = $allowTemporalRefs
        allow_extra_reference_images = $allowExtraReferenceImages
        total_reference_count = $merged.Count
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = $ReviewPath
    review_package_manifest = $ReviewPackageManifest
    updates = $updates
}
New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12
