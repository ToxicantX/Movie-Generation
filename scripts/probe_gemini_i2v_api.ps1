param(
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env",
    [string]$BaseUrl = "http://127.0.0.1:7860",
    [string]$ImagePath = "G:\ComfyUI\output\AIShortDrama\storyboards\SSJ_EP01_SC01_SH02_v001_00001_.png",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\gemini_i2v_probe_result.json",
    [string]$ReferenceField = "file_ids"
)

if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Image not found: $ImagePath"
}

Add-Type -AssemblyName System.Net.Http

$envText = Get-Content -Path $GeminiEnvPath -Raw
$apiKey = [regex]::Match($envText, '(?m)^API_KEYS=([^\r\n,]+)').Groups[1].Value
if (-not $apiKey) {
    throw "No API_KEYS value found in $GeminiEnvPath"
}

$headers = @{ Authorization = "Bearer $apiKey" }
$probe = [ordered]@{
    base_url = $BaseUrl
    image_path = $ImagePath
    reference_field = $ReferenceField
    upload_ok = $false
    file_id = $null
    generate_status = $null
    generate_ok = $false
    response = $null
    error = $null
}

try {
    $fileName = Split-Path -Path $ImagePath -Leaf
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(180)
    $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)
    $content = [System.Net.Http.MultipartFormDataContent]::new()
    $stream = [System.IO.File]::OpenRead($ImagePath)
    $fileContent = [System.Net.Http.StreamContent]::new($stream)
    $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("image/png")
    $content.Add($fileContent, "file", $fileName)
    try {
        $uploadResponse = $client.PostAsync("$BaseUrl/v1/gemini/files", $content).GetAwaiter().GetResult()
        $uploadText = $uploadResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $uploadResponse.IsSuccessStatusCode) {
            throw "Upload failed $([int]$uploadResponse.StatusCode): $($uploadText.Substring(0, [Math]::Min(500, $uploadText.Length)))"
        }
        $upload = $uploadText | ConvertFrom-Json
    } finally {
        $stream.Dispose()
        $content.Dispose()
        $client.Dispose()
    }

    $probe.upload_ok = $true
    $probe.file_id = $upload.file.id
    if (-not $probe.file_id) {
        throw "Upload succeeded but response did not include file.id"
    }

    $bodyObject = [ordered]@{
        model = "gemini-3.1-pro"
        mode = "video"
        aspect_ratio = "16:9"
        prompt = "Create a safe serene 8 second ancient Chinese fantasy video based on the uploaded storyboard image. Preserve the adult characters, mountain meadow, golden sunset, distant sea, and calm first encounter. No danger, no violence, no injury, no minors, no text."
    }
    $bodyObject[$ReferenceField] = @($probe.file_id)
    $body = $bodyObject | ConvertTo-Json -Depth 8

    try {
        $requestArgs = @{
            Uri = "$BaseUrl/v1/gemini/generate"
            Method = "Post"
            Headers = @{ Authorization = "Bearer $apiKey"; "Content-Type" = "application/json" }
            Body = $body
            TimeoutSec = 900
        }
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $requestArgs.SkipHttpErrorCheck = $true
        }
        $response = Invoke-WebRequest @requestArgs
        $probe.generate_status = [int]$response.StatusCode
        try {
            $probe.response = $response.Content | ConvertFrom-Json
        } catch {
            $probe.response = $response.Content
        }
        $probe.generate_ok = ($probe.generate_status -ge 200 -and $probe.generate_status -lt 300)
    } catch {
        if ($_.Exception.Response) {
            $probe.generate_status = [int]$_.Exception.Response.StatusCode
        } else {
            $probe.generate_status = 0
        }
        try {
            if ($_.ErrorDetails.Message) {
                $probe.response = $_.ErrorDetails.Message | ConvertFrom-Json
            } elseif ($_.Exception.Response) {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $probe.response = $reader.ReadToEnd() | ConvertFrom-Json
            } else {
                $probe.error = $_.Exception.Message
            }
        } catch {
            $probe.error = $_.Exception.Message
        }
    }
} catch {
    $probe.error = $_.Exception.Message
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$probe | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
$probe | ConvertTo-Json -Depth 12
if (-not $probe.generate_ok) {
    exit 1
}
