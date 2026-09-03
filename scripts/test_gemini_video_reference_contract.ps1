param(
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env",
    [string]$BaseUrl = "http://127.0.0.1:7860",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\gemini_video_reference_contract_probe.json"
)

$envText = Get-Content -Path $GeminiEnvPath -Raw
$apiKey = [regex]::Match($envText, '(?m)^API_KEYS=([^\r\n,]+)').Groups[1].Value.Trim()
if (-not $apiKey) {
    throw "No API_KEYS value found in $GeminiEnvPath"
}

$body = @{
    model = "gemini-3.1-pro"
    mode = "video"
    aspect_ratio = "16:9"
    prompt = "contract probe only; do not generate"
    file_ids = @("file-contract-probe-not-real")
} | ConvertTo-Json -Depth 8

$requestArgs = @{
    Uri = "$BaseUrl/v1/gemini/generate"
    Method = "Post"
    Headers = @{
        Authorization = "Bearer $apiKey"
        "Content-Type" = "application/json"
    }
    Body = $body
    TimeoutSec = 30
}
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $requestArgs.SkipHttpErrorCheck = $true
}

$statusCode = 0
$content = ""
try {
    $response = Invoke-WebRequest @requestArgs
    $statusCode = [int]$response.StatusCode
    $content = $response.Content
} catch {
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    $content = $_.ErrorDetails.Message
}

$classification = "unknown"
$message = $content
if ($statusCode -eq 400 -and $content -match "not supported for video reference") {
    $classification = "official_no_video_file_refs"
} elseif ($statusCode -eq 400 -and $content -match "File not found") {
    $classification = "experimental_file_ids_path_enabled"
} elseif ($statusCode -eq 409) {
    $classification = "video_request_reached_generation_layer"
} elseif ($statusCode -ge 200 -and $statusCode -lt 300) {
    $classification = "unexpected_generated_from_probe"
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    base_url = $BaseUrl
    status_code = $statusCode
    classification = $classification
    official_docs_state = "Gemini-API docs say mode=video with file_ids is not supported."
    pipeline_meaning = switch ($classification) {
        "official_no_video_file_refs" { "Use Gemini text-to-video only, or switch to a provider with official image-to-video reference support." }
        "experimental_file_ids_path_enabled" { "Current backend is locally patched/experimental and accepts file_ids far enough to validate uploaded references." }
        "video_request_reached_generation_layer" { "Backend did not reject file_ids before video generation; treat as experimental and verify with a real uploaded reference." }
        default { "Manual inspection required before using reference-driven Gemini I2V." }
    }
    response = $message
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if ($classification -eq "unknown" -or $classification -eq "unexpected_generated_from_probe") {
    exit 1
}
