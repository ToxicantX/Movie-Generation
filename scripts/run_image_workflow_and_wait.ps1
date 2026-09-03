param(
    [Parameter(Mandatory = $true)]
    [string]$WorkflowPath,
    [string]$ShotId = "TEST_SHOT",
    [string]$SubmitScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\submit_image_workflow.ps1",
    [string]$WaitScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\wait_comfy_prompt.ps1",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\image_workflow_result.json",
    [int]$PollSeconds = 5,
    [int]$MaxPolls = 120
)

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    shot_id = $ShotId
    workflow_path = $WorkflowPath
    prompt_id = $null
    status = "not_started"
    completed = $false
    submit_output = @()
    wait_result = $null
    error = $null
}

try {
    $submitOutput = & powershell -ExecutionPolicy Bypass -File $SubmitScript -WorkflowPath $WorkflowPath
    $result.submit_output = @($submitOutput)
    $submitExit = $LASTEXITCODE
    if ($submitExit -ne 0) {
        $result.status = "submit_failed"
        $result.error = "Submit script exited with code $submitExit."
    } else {
        foreach ($line in $submitOutput) {
            if ($line -match 'prompt_id=([0-9a-fA-F-]+)') {
                $result.prompt_id = $Matches[1]
                break
            }
        }
        if (-not $result.prompt_id) {
            $result.status = "submit_missing_prompt_id"
            $result.error = "Submit script did not return a prompt_id."
        } else {
            $waitOutput = & powershell -ExecutionPolicy Bypass -File $WaitScript -PromptId $result.prompt_id -PollSeconds $PollSeconds -MaxPolls $MaxPolls
            $result.wait_result = $waitOutput | ConvertFrom-Json
            $result.completed = [bool]$result.wait_result.completed
            $result.status = $result.wait_result.status
            $result.error = $result.wait_result.error
        }
    }
} catch {
    $result.status = "exception"
    $result.error = $_.Exception.Message
} finally {
    New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
    $result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
    $result | ConvertTo-Json -Depth 12
}

if (-not $result.completed) {
    exit 1
}
