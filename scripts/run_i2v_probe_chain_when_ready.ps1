param(
    [string]$ProtectedApiProbeScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\probe_gemini_i2v_when_ready.ps1",
    [string]$ComfyProbeScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\submit_comfy_i2v_probe.ps1",
    [string]$WaitScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\wait_comfy_prompt.ps1",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\gemini_i2v_probe_chain_result.json",
    [int]$PollSeconds = 10,
    [int]$MaxPolls = 120
)

$chain = [ordered]@{
    updated = (Get-Date).ToString("s")
    protected_api_probe_script = $ProtectedApiProbeScript
    comfy_probe_script = $ComfyProbeScript
    api_probe_exit_code = $null
    api_probe_output = @()
    comfy_prompt_id = $null
    comfy_submit_output = $null
    comfy_wait_result = $null
    status = "not_started"
}

try {
    $apiOutput = & powershell -ExecutionPolicy Bypass -File $ProtectedApiProbeScript
    $chain.api_probe_exit_code = $LASTEXITCODE
    $chain.api_probe_output = @($apiOutput)
    if ($LASTEXITCODE -ne 0) {
        $chain.status = "api_probe_not_ready_or_failed"
        $chain.error = "Protected API probe did not complete successfully. Exit code: $($chain.api_probe_exit_code)"
    } else {
        $submitOutput = & powershell -ExecutionPolicy Bypass -File $ComfyProbeScript
        $chain.comfy_submit_output = $submitOutput | ConvertFrom-Json
        $chain.comfy_prompt_id = $chain.comfy_submit_output.prompt_id
        if (-not $chain.comfy_prompt_id) {
            $chain.status = "comfy_probe_submit_missing_prompt_id"
            $chain.error = "Comfy probe submission did not return a prompt_id."
        } else {
            $waitOutput = & powershell -ExecutionPolicy Bypass -File $WaitScript -PromptId $chain.comfy_prompt_id -PollSeconds $PollSeconds -MaxPolls $MaxPolls
            $chain.comfy_wait_result = $waitOutput | ConvertFrom-Json
            if ($LASTEXITCODE -eq 0 -and $chain.comfy_wait_result.completed) {
                $chain.status = "comfy_probe_completed"
            } else {
                $chain.status = "comfy_probe_failed_or_timeout"
            }
        }
    }
} catch {
    $chain.status = "exception"
    $chain.error = $_.Exception.Message
} finally {
    New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
    $chain | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
    $chain | ConvertTo-Json -Depth 12
}

if ($chain.status -ne "comfy_probe_completed") {
    exit 1
}
