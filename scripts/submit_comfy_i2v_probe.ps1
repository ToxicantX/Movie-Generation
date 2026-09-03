param(
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [string]$WorkflowPath = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows\ssj_ep01_sc01_sh02_i2v_probe.json",
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env"
)

if (-not (Test-Path -LiteralPath $WorkflowPath)) {
    $workflow = @{
        prompt = @{
            "1" = @{
                class_type = "GeminiAPIVideoGenerate"
                inputs = @{
                    prompt = "Animate this uploaded storyboard frame as a safe serene 8 second ancient Chinese fantasy shot. Preserve adult characters, rugged robes, green bamboo flute, ancient white-haired sage, high mountain meadow, golden sunset, distant sea, and soft waterfall mist. Gentle wind, slow camera push in, no danger, no violence, no injury, no minors, no text."
                    model = "gemini-3.1-pro"
                    base_url = "http://127.0.0.1:7860"
                    filename_prefix = "AIShortDrama/videos/SSJ_EP01_SC01_SH02_i2v_probe"
                    image_path = "G:\ComfyUI\output\AIShortDrama\storyboards\SSJ_EP01_SC01_SH02_v001_00001_.png"
                    reference_field = "file_ids"
                    aspect_ratio = "16:9"
                }
            }
        }
        client_id = "codex-ai-short-drama"
    }
    New-Item -ItemType Directory -Path (Split-Path $WorkflowPath) -Force | Out-Null
    $workflow | ConvertTo-Json -Depth 20 | Set-Content -Path $WorkflowPath -Encoding UTF8
}

$workflow = Get-Content -Path $WorkflowPath -Raw | ConvertFrom-Json
if (Test-Path -LiteralPath $GeminiEnvPath) {
    foreach ($node in $workflow.prompt.PSObject.Properties.Value) {
        if ($node.class_type -eq "GeminiAPIVideoGenerate") {
            if ($node.inputs.PSObject.Properties.Name -contains "api_key") {
                $node.inputs.PSObject.Properties.Remove("api_key")
            }
            $node.inputs | Add-Member -NotePropertyName "api_key_env_path" -NotePropertyValue $GeminiEnvPath -Force
        }
    }
}
$body = $workflow | ConvertTo-Json -Depth 20
$result = Invoke-RestMethod -Uri "$ComfyUrl/prompt" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
$result | ConvertTo-Json -Depth 8
