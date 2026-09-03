param(
    [string]$StrategyPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\video_reference_strategy.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\video_reference_strategy_apply_result.json"
)

$workflowByShot = @{
    "TEST_SSJ_EP01_SC01_SH01" = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh01_i2v_retry.json"
    "TEST_SSJ_EP01_SC01_SH02" = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh02_i2v_retry.json"
    "TEST_SSJ_EP01_SC01_SH03" = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh03_i2v_retry.json"
}

if (-not (Test-Path -LiteralPath $StrategyPath)) {
    throw "Strategy file not found: $StrategyPath"
}

$strategy = Get-Content -Path $StrategyPath -Raw -Encoding UTF8 | ConvertFrom-Json
$updates = @()

foreach ($shotStrategy in $strategy.shots) {
    $workflowPath = $workflowByShot[$shotStrategy.shot_id]
    if (-not $workflowPath) {
        continue
    }
    $workflow = Get-Content -Path $workflowPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $inputs = $workflow.prompt.'1'.inputs
    if ($shotStrategy.allow_extra_reference_images -eq $false) {
        if ($inputs.PSObject.Properties.Name -contains "reference_image_paths") {
            $inputs.reference_image_paths = ""
        } else {
            $inputs | Add-Member -NotePropertyName reference_image_paths -NotePropertyValue ""
        }
    }
    if ($inputs.PSObject.Properties.Name -notcontains "video_reference_mode") {
        $inputs | Add-Member -NotePropertyName video_reference_mode -NotePropertyValue "experimental_file_ids"
    }
    $workflow | ConvertTo-Json -Depth 20 | Set-Content -Path $workflowPath -Encoding UTF8
    $updates += [ordered]@{
        shot_id = $shotStrategy.shot_id
        workflow = $workflowPath
        strategy = $shotStrategy.strategy
        allow_temporal_refs = $shotStrategy.allow_temporal_refs
        allow_extra_reference_images = $shotStrategy.allow_extra_reference_images
        reference_image_paths = $inputs.reference_image_paths
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    strategy_path = $StrategyPath
    updates = $updates
}
New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12
