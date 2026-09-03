param(
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env",
    [string]$BaseUrl = "http://127.0.0.1:7860",
    [string]$OutputPath = "G:\ComfyUI\output\AIShortDrama\videos\SSJ_EP01_SC01_SH02_i2v_probe_api_latest.mp4",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\latest_gemini_video_download.json"
)

$envText = Get-Content -Path $GeminiEnvPath -Raw
$apiKey = [regex]::Match($envText, '(?m)^API_KEYS=([^\r\n,]+)').Groups[1].Value.Trim()
if (-not $apiKey) {
    throw "No API_KEYS value found in $GeminiEnvPath"
}
$headers = @{ Authorization = "Bearer $apiKey" }
$media = Invoke-RestMethod -Uri "$BaseUrl/v1/gemini/media?limit=20" -Headers $headers -TimeoutSec 20
$video = $media.media | Where-Object { $_.kind -eq "video" } | Sort-Object created_at -Descending | Select-Object -First 1
if (-not $video) {
    throw "No Gemini video media found."
}

$url = $video.content_url
if ($url -like "/*") {
    $url = $BaseUrl.TrimEnd("/") + $url
}
New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
Invoke-WebRequest -Uri $url -Headers $headers -OutFile $OutputPath -TimeoutSec 600

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    media_id = $video.id
    token = $video.token
    request_id = $video.request_id
    created_at = $video.created_at
    content_url = $video.content_url
    output_path = $OutputPath
    bytes = (Get-Item -LiteralPath $OutputPath).Length
}
New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 10
