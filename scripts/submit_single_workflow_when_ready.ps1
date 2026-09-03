param(
    [Parameter(Mandatory = $true)]
    [string]$WorkflowPath,
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env",
    [string]$BaseUrl = "http://127.0.0.1:7860",
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [string]$VideoReferenceContractProbe = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\test_gemini_video_reference_contract.ps1"
)

if (-not (Test-Path -LiteralPath $WorkflowPath)) {
    throw "Workflow not found: $WorkflowPath"
}

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

$workflow = Get-Content -Path $WorkflowPath -Raw | ConvertFrom-Json
$usesExperimentalVideoRefs = $false
foreach ($node in $workflow.prompt.PSObject.Properties.Value) {
    if ($node.class_type -eq "GeminiAPIVideoGenerate") {
        $node.inputs | Add-Member -NotePropertyName "api_key_env_path" -NotePropertyValue $GeminiEnvPath -Force
        if ($node.inputs.video_reference_mode -eq "experimental_file_ids") {
            $usesExperimentalVideoRefs = $true
        }
    }
}

if ($usesExperimentalVideoRefs) {
    $probeOutput = & powershell -ExecutionPolicy Bypass -File $VideoReferenceContractProbe -GeminiEnvPath $GeminiEnvPath -BaseUrl $BaseUrl
    $probeExit = $LASTEXITCODE
    if ($probeExit -ne 0) {
        Write-Output "Video reference contract probe failed. Refusing to submit experimental I2V workflow."
        Write-Output $probeOutput
        exit 4
    }
    $probe = $probeOutput | ConvertFrom-Json
    if ($probe.classification -eq "official_no_video_file_refs") {
        Write-Output "Gemini-API currently follows official docs and rejects mode=video with file_ids. Refusing to submit experimental I2V workflow."
        exit 4
    }
}

$body = $workflow | ConvertTo-Json -Depth 20
$result = Invoke-RestMethod -Uri "$ComfyUrl/prompt" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
Write-Output "$WorkflowPath -> prompt_id=$($result.prompt_id)"
