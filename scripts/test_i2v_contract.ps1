param(
    [string]$ComfyNodePath = "G:\ComfyUI\custom_nodes\gemini_api_video_node.py",
    [string]$WorkflowDir = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows",
    [string[]]$WorkflowNames = @(
        "ssj_ep01_sc01_sh01_i2v_retry.json",
        "ssj_ep01_sc01_sh02_i2v_retry.json",
        "ssj_ep01_sc01_sh03_i2v_retry.json"
    ),
    [string]$RequiredReferenceField = "file_ids",
    [string]$RequiredVideoReferenceMode = "experimental_file_ids",
    [string]$RequiredAspectRatio = "16:9",
    [string]$StrategyPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\video_reference_strategy.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\i2v_contract_check.json"
)

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    comfy_node_path = $ComfyNodePath
    required_reference_field = $RequiredReferenceField
    required_video_reference_mode = $RequiredVideoReferenceMode
    required_aspect_ratio = $RequiredAspectRatio
    strategy_path = $StrategyPath
    checks = @()
    ok = $true
}

function Add-Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Message
    )
    $script:result.checks += [ordered]@{
        name = $Name
        ok = $Ok
        message = $Message
    }
    if (-not $Ok) {
        $script:result.ok = $false
    }
}

if (-not (Test-Path -LiteralPath $ComfyNodePath)) {
    Add-Check -Name "comfy_node_exists" -Ok $false -Message "Missing Comfy node: $ComfyNodePath"
} else {
    $nodeText = Get-Content -Path $ComfyNodePath -Raw
    Add-Check -Name "comfy_node_reference_field_input" -Ok ($nodeText -like "*reference_field*") -Message "Comfy node exposes reference_field input."
    Add-Check -Name "comfy_node_video_reference_mode_input" -Ok ($nodeText -like "*video_reference_mode*") -Message "Comfy node exposes explicit official/experimental video reference mode."
    Add-Check -Name "comfy_node_aspect_ratio_input" -Ok ($nodeText -like "*aspect_ratio*") -Message "Comfy node exposes aspect_ratio input."
    Add-Check -Name "comfy_node_api_key_env_path_input" -Ok ($nodeText -like "*api_key_env_path*") -Message "Comfy node can read API key from a local env file without storing the key in prompt history."
    Add-Check -Name "comfy_node_request_timeout_input" -Ok ($nodeText -like "*request_timeout_seconds*") -Message "Comfy node exposes configurable long video request timeout."
    Add-Check -Name "comfy_node_default_reference_contract" -Ok ($nodeText -like "*$RequiredReferenceField*") -Message "Comfy node knows the required I2V reference field."
}

$strategy = $null
if (Test-Path -LiteralPath $StrategyPath) {
    $strategy = Get-Content -Path $StrategyPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

foreach ($name in $WorkflowNames) {
    $path = Join-Path $WorkflowDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Check -Name "workflow_exists:$name" -Ok $false -Message "Missing workflow: $path"
        continue
    }

    try {
        $workflow = Get-Content -Path $path -Raw | ConvertFrom-Json
    } catch {
        Add-Check -Name "workflow_json:$name" -Ok $false -Message $_.Exception.Message
        continue
    }

    $node = $workflow.prompt.PSObject.Properties.Value | Where-Object { $_.class_type -eq "GeminiAPIVideoGenerate" } | Select-Object -First 1
    if (-not $node) {
        Add-Check -Name "workflow_video_node:$name" -Ok $false -Message "No GeminiAPIVideoGenerate node found."
        continue
    }

    $inputs = $node.inputs
    $shotId = $null
    if ($name -match 'sh(\d+)_') {
        $shotId = "TEST_SSJ_EP01_SC01_SH$($Matches[1])"
    }
    $shotStrategy = $null
    if ($strategy -and $shotId) {
        $shotStrategy = $strategy.shots | Where-Object { $_.shot_id -eq $shotId } | Select-Object -First 1
    }
    Add-Check -Name "workflow_reference_field:$name" -Ok ($inputs.reference_field -eq $RequiredReferenceField) -Message "reference_field=$($inputs.reference_field)"
    Add-Check -Name "workflow_video_reference_mode:$name" -Ok ($inputs.video_reference_mode -eq $RequiredVideoReferenceMode) -Message "video_reference_mode=$($inputs.video_reference_mode)"
    Add-Check -Name "workflow_aspect_ratio:$name" -Ok ($inputs.aspect_ratio -eq $RequiredAspectRatio) -Message "aspect_ratio=$($inputs.aspect_ratio)"
    Add-Check -Name "workflow_no_inline_api_key:$name" -Ok (-not $inputs.PSObject.Properties.Name.Contains("api_key") -or [string]::IsNullOrWhiteSpace($inputs.api_key)) -Message "Workflow must not persist a plaintext API key in Comfy prompt inputs."
    Add-Check -Name "workflow_request_timeout:$name" -Ok (($inputs.request_timeout_seconds -as [int]) -ge 1200) -Message "request_timeout_seconds=$($inputs.request_timeout_seconds)"
    Add-Check -Name "workflow_image_exists:$name" -Ok (Test-Path -LiteralPath $inputs.image_path) -Message "image_path=$($inputs.image_path)"
    $extraRefs = @()
    if ($inputs.reference_image_paths) {
        $extraRefs = @($inputs.reference_image_paths -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($shotStrategy -and $shotStrategy.allow_extra_reference_images -eq $false -and $shotStrategy.allow_temporal_refs -eq $false) {
        Add-Check -Name "workflow_extra_reference_count:$name" -Ok ($extraRefs.Count -eq 0) -Message "extra_reference_count=$($extraRefs.Count); strategy expects single storyboard only."
    } elseif ($shotStrategy -and $shotStrategy.allow_temporal_refs -eq $true) {
        Add-Check -Name "workflow_extra_reference_count:$name" -Ok ($extraRefs.Count -ge 0) -Message "extra_reference_count=$($extraRefs.Count); temporal refs optional by strategy."
    } else {
        Add-Check -Name "workflow_extra_reference_count:$name" -Ok ($extraRefs.Count -ge 0) -Message "extra_reference_count=$($extraRefs.Count)"
    }
    Add-Check -Name "workflow_prompt_nonempty:$name" -Ok (-not [string]::IsNullOrWhiteSpace($inputs.prompt)) -Message "Prompt is present."
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12

if (-not $result.ok) {
    exit 1
}
