param(
    [string]$SubmitScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\submit_i2v_when_ready.ps1",
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [int]$PollSeconds = 10,
    [int]$MaxPolls = 120,
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_i2v_results.json"
)

$submitOutput = & powershell -ExecutionPolicy Bypass -File $SubmitScript
$submitExit = $LASTEXITCODE
if ($submitExit -ne 0) {
    $submitOutput
    exit $submitExit
}

$promptIds = @()
foreach ($line in $submitOutput) {
    if ($line -match 'prompt_id=([0-9a-fA-F-]+)') {
        $promptIds += $Matches[1]
    }
}
if ($promptIds.Count -eq 0) {
    throw "No prompt ids were returned by submit script."
}

$results = @()
foreach ($promptId in $promptIds) {
    Write-Output "Waiting for prompt_id=$promptId"
    $finished = $false
    for ($i = 0; $i -lt $MaxPolls; $i++) {
        Start-Sleep -Seconds $PollSeconds
        try {
            $history = Invoke-RestMethod -Uri "$ComfyUrl/history/$promptId" -TimeoutSec 5
            $entry = $history.PSObject.Properties[$promptId].Value
            if (-not $entry) {
                continue
            }
            $status = $entry.status
            if ($status.completed -eq $true -or ($status.status_str -and $status.status_str -ne "running")) {
                $finished = $true
                $videoPaths = @()
                foreach ($outputProp in $entry.outputs.PSObject.Properties) {
                    $outputValue = $outputProp.Value
                    foreach ($valueProp in $outputValue.PSObject.Properties) {
                        if ($valueProp.Name -eq "video_path") {
                            $videoPaths += [string]$valueProp.Value
                        }
                    }
                }
                $errorMessage = $null
                foreach ($message in $status.messages) {
                    if ($message[0] -eq "execution_error") {
                        $errorMessage = $message[1].exception_message
                    }
                }
                $results += [pscustomobject]@{
                    prompt_id = $promptId
                    status = $status.status_str
                    completed = [bool]$status.completed
                    video_paths = $videoPaths
                    error = $errorMessage
                }
                break
            }
        } catch {
            Write-Output "Poll failed for ${promptId}: $($_.Exception.Message)"
        }
    }
    if (-not $finished) {
        $results += [pscustomobject]@{
            prompt_id = $promptId
            status = "timeout"
            completed = $false
            video_paths = @()
            error = "Timed out waiting for ComfyUI history."
        }
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$results | ConvertTo-Json -Depth 8 | Set-Content -Path $ResultPath -Encoding UTF8
$results | ConvertTo-Json -Depth 8
