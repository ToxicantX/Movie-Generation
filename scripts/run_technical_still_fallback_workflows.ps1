param(
    [Parameter(Mandatory = $true)]
    [string[]]$WorkflowPaths,
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\technical_still_fallback_run_result.json",
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [string]$WaitScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\wait_comfy_prompt.ps1",
    [int]$PollSeconds = 2,
    [int]$MaxPolls = 120
)

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    mode = "technical_still_fallback_comfy_node"
    comfy_url = $ComfyUrl
    workflow_paths = $WorkflowPaths
    runs = @()
    ok = $true
}

foreach ($workflowPath in $WorkflowPaths) {
    $run = [ordered]@{
        workflow_path = $workflowPath
        prompt_id = $null
        wait = $null
        ok = $false
        error = $null
    }

    try {
        if (-not (Test-Path -LiteralPath $workflowPath)) {
            throw "Workflow not found: $workflowPath"
        }

        $body = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
        $submit = Invoke-RestMethod -Uri "$ComfyUrl/prompt" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
        $run.prompt_id = [string]$submit.prompt_id
        if (-not $run.prompt_id) {
            throw "Comfy submission did not return prompt_id."
        }

        $waitOutput = & powershell -ExecutionPolicy Bypass -File $WaitScript -PromptId $run.prompt_id -ComfyUrl $ComfyUrl -PollSeconds $PollSeconds -MaxPolls $MaxPolls
        $run.wait = $waitOutput | ConvertFrom-Json
        $run.ok = [bool]$run.wait.completed
        if (-not $run.ok) {
            $run.error = $run.wait.error
        }
    } catch {
        $run.error = $_.Exception.Message
        $run.ok = $false
    }

    if (-not $run.ok) {
        $result.ok = $false
    }
    $result.runs += $run
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
