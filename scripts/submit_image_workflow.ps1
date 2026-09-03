param(
    [Parameter(Mandatory = $true)]
    [string]$WorkflowPath,
    [string]$KeyPath = "",
    [string]$ComfyUrl = "http://127.0.0.1:8188"
)

if (-not (Test-Path -LiteralPath $WorkflowPath)) {
    throw "Workflow not found: $WorkflowPath"
}
if (-not $KeyPath) {
    $found = Get-ChildItem -Path "E:\WuShengXi-Obsidian\Projects" -Recurse -Filter "KEY.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*AI*KEY.md" -or $_.FullName -like "*短剧*KEY.md" } |
        Select-Object -First 1
    if ($found) {
        $KeyPath = $found.FullName
    }
}
if (-not (Test-Path -LiteralPath $KeyPath)) {
    throw "Key file not found: $KeyPath"
}

$keyText = Get-Content -LiteralPath $KeyPath -Raw -Encoding UTF8
$baseUrl = [regex]::Match($keyText, '"baseURL"\s*:\s*"([^"]+)"').Groups[1].Value
if (-not $baseUrl) {
    $baseUrl = [regex]::Match($keyText, '"base_url"\s*:\s*"([^"]+)"').Groups[1].Value
}
if (-not $baseUrl) {
    $baseUrl = [regex]::Match($keyText, "'baseURL'\s*:\s*'([^']+)'").Groups[1].Value
}
if (-not $baseUrl) {
    $baseUrl = [regex]::Match($keyText, "(?m)^\s*(?:OPENAI_BASE_URL|BASE_URL)\s*=\s*([^\r\n]+)").Groups[1].Value
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($node in $workflow.prompt.PSObject.Properties.Value) {
    if ($node.class_type -eq "OpenAICompatibleImageGenerate") {
        if ($baseUrl) {
            $node.inputs | Add-Member -NotePropertyName "base_url" -NotePropertyValue $baseUrl.Trim() -Force
        }
        if ($node.inputs.PSObject.Properties.Name -contains "api_key") {
            $node.inputs.PSObject.Properties.Remove("api_key")
        }
        $node.inputs | Add-Member -NotePropertyName "api_key_env_path" -NotePropertyValue $KeyPath -Force
    }
}

$body = $workflow | ConvertTo-Json -Depth 20
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$result = Invoke-RestMethod -Uri "$ComfyUrl/prompt" -Method Post -Body $bodyBytes -ContentType "application/json; charset=utf-8" -TimeoutSec 30
Write-Output "$WorkflowPath -> prompt_id=$($result.prompt_id)"
