param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_rerun_failed_i2v_result.json",
    [string]$WorkflowCreateResultPath = "",
    [switch]$IncludeInvalid,
    [switch]$IncludePending
)

if (-not (Test-Path -LiteralPath $ReviewPath)) {
    throw "Review file not found: $ReviewPath"
}

$review = Get-Content -Path $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$workflowLookup = @{}
if ($WorkflowCreateResultPath -and (Test-Path -LiteralPath $WorkflowCreateResultPath)) {
    $workflowData = Get-Content -Path $WorkflowCreateResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in $workflowData.created) {
        if ($item.shot_id -and $item.video_workflow) {
            $workflowLookup[$item.shot_id] = $item.video_workflow
        }
    }
}

function Get-WorkflowForShot {
    param($Shot)

    if ($Shot.video_workflow) {
        return [string]$Shot.video_workflow
    }
    if ($workflowLookup.ContainsKey($Shot.shot_id)) {
        return [string]$workflowLookup[$Shot.shot_id]
    }
    return $null
}

$targetStatuses = @("needs_regeneration")
if ($IncludeInvalid) {
    $targetStatuses += "generated_invalid_file"
}
if ($IncludePending) {
    $targetStatuses += "pending"
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = $ReviewPath
    workflow_create_result_path = $WorkflowCreateResultPath
    target_statuses = $targetStatuses
    runs = @()
    ok = $true
}

foreach ($shot in $review.shots) {
    if ($shot.status -notin $targetStatuses) {
        continue
    }
    $workflow = Get-WorkflowForShot -Shot $shot
    if (-not $workflow) {
        $result.ok = $false
        $result.runs += [ordered]@{
            shot_id = $shot.shot_id
            status = "missing_workflow_mapping"
        }
        continue
    }
    $shotResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\$($shot.shot_id.ToLowerInvariant())_rerun_i2v_result.json"
    $output = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_single_i2v_workflow_and_wait.ps1" -WorkflowPath $workflow -ShotId $shot.shot_id -ResultPath $shotResultPath
    $exit = $LASTEXITCODE
    $parsed = $null
    try {
        $parsed = $output | ConvertFrom-Json
    } catch {
        $parsed = @{ raw = @($output) }
    }
    if ($exit -ne 0) {
        $result.ok = $false
    }
    $result.runs += [ordered]@{
        shot_id = $shot.shot_id
        workflow = $workflow
        exit_code = $exit
        result_path = $shotResultPath
        result = $parsed
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
