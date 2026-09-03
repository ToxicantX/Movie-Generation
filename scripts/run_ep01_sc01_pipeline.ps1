param(
    [switch]$Generate,
    [switch]$RerunFailed,
    [switch]$BuildReviewPackage = $true,
    [switch]$TechnicalCut,
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_pipeline_run.json"
)

$workflows = @(
    @{ shot_id = "TEST_SSJ_EP01_SC01_SH01"; path = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh01_i2v_retry.json"; result = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_sh01_i2v_production_result.json" },
    @{ shot_id = "TEST_SSJ_EP01_SC01_SH02"; path = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh02_i2v_retry.json"; result = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_sh02_i2v_production_result.json" },
    @{ shot_id = "TEST_SSJ_EP01_SC01_SH03"; path = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh03_i2v_retry.json"; result = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_sh03_i2v_production_result.json" }
)

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    generate = [bool]$Generate
    rerun_failed = [bool]$RerunFailed
    build_review_package = [bool]$BuildReviewPackage
    technical_cut = [bool]$TechnicalCut
    steps = @()
    ok = $true
}

function Add-StepResult {
    param(
        [string]$Name,
        [int]$ExitCode,
        [object[]]$Output
    )
    if ($ExitCode -ne 0) {
        $script:result.ok = $false
    }
    $parsed = $null
    try {
        $parsed = $Output | ConvertFrom-Json
    } catch {
        $parsed = @{ raw = @($Output) }
    }
    $script:result.steps += [ordered]@{
        name = $Name
        exit_code = $ExitCode
        output = $parsed
    }
}

if ($Generate) {
    foreach ($workflow in $workflows) {
        $output = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_single_i2v_workflow_and_wait.ps1" -WorkflowPath $workflow.path -ShotId $workflow.shot_id -ResultPath $workflow.result
        Add-StepResult -Name "generate_$($workflow.shot_id)" -ExitCode $LASTEXITCODE -Output $output
        if ($LASTEXITCODE -ne 0) {
            break
        }
    }
}

if ($RerunFailed) {
    $output = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\rerun_failed_i2v_shots.ps1"
    Add-StepResult -Name "rerun_failed" -ExitCode $LASTEXITCODE -Output $output
}

$refreshOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\refresh_consistency_review_from_outputs.ps1"
Add-StepResult -Name "refresh_consistency_review" -ExitCode $LASTEXITCODE -Output $refreshOutput

if ($BuildReviewPackage) {
    $packageOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\build_review_package.ps1"
    Add-StepResult -Name "build_review_package" -ExitCode $LASTEXITCODE -Output $packageOutput
}

if ($TechnicalCut) {
    $cutOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\postprocess_episode_after_i2v.ps1" -CutWithoutHumanApproval
    Add-StepResult -Name "technical_cut" -ExitCode $LASTEXITCODE -Output $cutOutput
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 30 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 30

if (-not $result.ok) {
    exit 1
}
