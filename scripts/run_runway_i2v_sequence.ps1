param(
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [switch]$Live,
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\runway_i2v_sequence_result.json",
    [int]$PollSeconds = 10,
    [int]$MaxPolls = 180
)

$mode = if ($Live) { "live" } else { "dryrun" }
$workflowDir = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows"
$workflows = @(
    "ssj_ep01_sc01_sh01_runway_i2v_$mode.json",
    "ssj_ep01_sc01_sh02_runway_i2v_$mode.json",
    "ssj_ep01_sc01_sh03_runway_i2v_$mode.json"
)

if ($Live -and -not $env:RUNWAYML_API_SECRET) {
    throw "RUNWAYML_API_SECRET is required for live Runway I2V generation."
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    mode = $mode
    comfy_url = $ComfyUrl
    workflows = @()
    ok = $true
}

foreach ($name in $workflows) {
    $path = Join-Path $workflowDir $name
    $item = [ordered]@{
        workflow = $path
        prompt_id = $null
        submit = $null
        wait = $null
        ok = $false
        error = $null
    }
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Workflow not found: $path"
        }
        $body = Get-Content -Path $path -Raw
        $submit = Invoke-RestMethod -Uri "$ComfyUrl/prompt" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
        $item.submit = $submit
        $item.prompt_id = $submit.prompt_id
        if (-not $item.prompt_id) {
            throw "Comfy submission did not return prompt_id."
        }

        $waitOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\wait_comfy_prompt.ps1" -PromptId $item.prompt_id -ComfyUrl $ComfyUrl -PollSeconds $PollSeconds -MaxPolls $MaxPolls
        $item.wait = $waitOutput | ConvertFrom-Json
        $item.ok = [bool]$item.wait.completed
        if (-not $item.ok) {
            $item.error = $item.wait.error
        }
    } catch {
        $item.error = $_.Exception.Message
        $result.ok = $false
    }
    if (-not $item.ok) {
        $result.ok = $false
    }
    $result.workflows += $item
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
