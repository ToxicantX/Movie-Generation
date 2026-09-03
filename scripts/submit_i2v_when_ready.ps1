param(
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env",
    [string]$BaseUrl = "http://127.0.0.1:7860",
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [string[]]$WorkflowPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh02_i2v_retry.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh01_i2v_retry.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh03_i2v_retry.json"
    ),
    [switch]$All
)

$envText = Get-Content -Path $GeminiEnvPath -Raw
$apiKey = [regex]::Match($envText, '(?m)^API_KEYS=([^\r\n,]+)').Groups[1].Value
if (-not $apiKey) {
    throw "No API_KEYS value found in $GeminiEnvPath"
}

$headers = @{ Authorization = "Bearer $apiKey" }
$cooldowns = Invoke-RestMethod -Uri "$BaseUrl/v1/media-cooldowns" -Headers $headers -TimeoutSec 10
$video = $cooldowns.summary | Where-Object { $_.kind -eq "video" } | Select-Object -First 1
if (-not $video -or $video.available -lt 1) {
    $next = $video.next
    if ($next) {
        Write-Output "Video generation is still blocked until $($next.blocked_until). Remaining seconds: $($next.remaining_seconds)."
    } else {
        Write-Output "Video generation is not available yet."
    }
    exit 2
}

$selectedWorkflowPaths = $WorkflowPaths
if (-not $All -and $WorkflowPaths.Count -gt 1) {
    $selectedWorkflowPaths = @($WorkflowPaths[0])
}

foreach ($workflowPath in $selectedWorkflowPaths) {
    if (-not (Test-Path -LiteralPath $workflowPath)) {
        throw "Workflow not found: $workflowPath"
    }
    $workflow = Get-Content -Path $workflowPath -Raw | ConvertFrom-Json
    foreach ($node in $workflow.prompt.PSObject.Properties.Value) {
        if ($node.class_type -eq "GeminiAPIVideoGenerate") {
            if ($node.inputs.PSObject.Properties.Name -contains "api_key") {
                $node.inputs.PSObject.Properties.Remove("api_key")
            }
            $node.inputs | Add-Member -NotePropertyName "api_key_env_path" -NotePropertyValue $GeminiEnvPath -Force
        }
    }
    $body = $workflow | ConvertTo-Json -Depth 20
    $result = Invoke-RestMethod -Uri "$ComfyUrl/prompt" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
    Write-Output "$workflowPath -> prompt_id=$($result.prompt_id)"
}
