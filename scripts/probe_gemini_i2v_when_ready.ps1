param(
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env",
    [string]$BaseUrl = "http://127.0.0.1:7860",
    [string]$ProbeScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\probe_gemini_i2v_api.ps1",
    [string]$StatusPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\gemini_i2v_probe_status.json",
    [string]$ReferenceField = "file_ids",
    [string]$GeminiAppPath = "E:\workspace\DockerProjects\Gemini-API\src\gemini_webapi\server\app.py"
)

function Write-ProbeStatus {
    param(
        [string]$Status,
        [string]$Message,
        [object]$Cooldown = $null,
        [int]$ExitCode = 0
    )

    $payload = [ordered]@{
        updated = (Get-Date).ToString("s")
        base_url = $BaseUrl
        status = $Status
        message = $Message
        cooldown = $Cooldown
        probe_script = $ProbeScript
        reference_field = $ReferenceField
        gemini_app_path = $GeminiAppPath
        exit_code = $ExitCode
    }
    New-Item -ItemType Directory -Path (Split-Path $StatusPath) -Force | Out-Null
    $payload | ConvertTo-Json -Depth 12 | Set-Content -Path $StatusPath -Encoding UTF8
}

$envText = Get-Content -Path $GeminiEnvPath -Raw
$apiKey = [regex]::Match($envText, '(?m)^API_KEYS=([^\r\n,]+)').Groups[1].Value.Trim()
if (-not $apiKey) {
    Write-ProbeStatus -Status "missing_api_key" -Message "No API_KEYS value found in $GeminiEnvPath" -ExitCode 1
    throw "No API_KEYS value found in $GeminiEnvPath"
}

$headers = @{ Authorization = "Bearer $apiKey" }

function Test-LocalGeminiRequestContract {
    param(
        [string]$Path,
        [string]$Field
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $text = Get-Content -Path $Path -Raw
    $classMatch = [regex]::Match($text, 'class\s+GeminiGenerateRequest\(BaseModel\):(?<body>.*?)(?:\r?\nclass\s|\z)', 'Singleline')
    if (-not $classMatch.Success) {
        return $false
    }
    return ($classMatch.Groups['body'].Value -match "(?m)^\s*$([regex]::Escape($Field))\s*:")
}

$contractVerified = $false
$contractSource = $null
if ($ReferenceField -eq "file_ids") {
    $contractVerified = $true
    $contractSource = "legacy_file_ids_allowed_by_probe_configuration"
}
try {
    if (-not $contractVerified) {
        $openapi = Invoke-RestMethod -Uri "$BaseUrl/openapi.json" -Headers $headers -TimeoutSec 10
        $schema = $openapi.components.schemas.GeminiGenerateRequest
        $properties = $schema.properties
        $hasReferenceField = $false
        if ($properties) {
            $hasReferenceField = [bool]$properties.PSObject.Properties[$ReferenceField]
        }
        if ($hasReferenceField) {
            $contractVerified = $true
            $contractSource = "openapi"
        }
    }
} catch {
    if (-not $contractVerified) {
        $contractSource = "openapi_unavailable_local_source_fallback"
    }
}

if (-not $contractVerified) {
    $contractVerified = Test-LocalGeminiRequestContract -Path $GeminiAppPath -Field $ReferenceField
    if ($contractVerified) {
        $contractSource = "local_source"
    }
}

if (-not $contractVerified) {
    $message = "Gemini-API request contract does not expose $ReferenceField on GeminiGenerateRequest. Refusing to submit a video probe because the backend may ignore the reference image and fall back to text-to-video. Contract source checked: $contractSource."
    Write-ProbeStatus -Status "backend_contract_missing" -Message $message -ExitCode 3
    Write-Output $message
    exit 3
}

$cooldowns = Invoke-RestMethod -Uri "$BaseUrl/v1/media-cooldowns" -Headers $headers -TimeoutSec 10
$video = $cooldowns.summary | Where-Object { $_.kind -eq "video" } | Select-Object -First 1
if (-not $video -or $video.available -lt 1) {
    $next = $video.next
    if ($next) {
        $message = "Video generation is still blocked until $($next.blocked_until). Remaining seconds: $($next.remaining_seconds)."
        Write-ProbeStatus -Status "cooldown_active" -Message $message -Cooldown $video -ExitCode 2
        Write-Output $message
    } else {
        $message = "Video generation is not available yet."
        Write-ProbeStatus -Status "video_unavailable" -Message $message -Cooldown $video -ExitCode 2
        Write-Output $message
    }
    exit 2
}

& powershell -ExecutionPolicy Bypass -File $ProbeScript -GeminiEnvPath $GeminiEnvPath -BaseUrl $BaseUrl -ReferenceField $ReferenceField
$probeExitCode = $LASTEXITCODE
if ($probeExitCode -eq 0) {
    Write-ProbeStatus -Status "probe_completed_success" -Message "Protected probe ran the API I2V probe successfully." -Cooldown $video -ExitCode $probeExitCode
} else {
    Write-ProbeStatus -Status "probe_completed_failure" -Message "Protected probe ran the API I2V probe but it failed." -Cooldown $video -ExitCode $probeExitCode
}
exit $probeExitCode
