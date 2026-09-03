param(
    [Parameter(Mandatory = $true)]
    [string]$PromptId,
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [int]$PollSeconds = 10,
    [int]$MaxPolls = 120,
    [string]$ResultPath = ""
)

$result = $null
for ($i = 0; $i -lt $MaxPolls; $i++) {
    Start-Sleep -Seconds $PollSeconds
    $history = Invoke-RestMethod -Uri "$ComfyUrl/history/$PromptId" -TimeoutSec 5
    $entry = $history.PSObject.Properties[$PromptId].Value
    if (-not $entry) {
        continue
    }
    $status = $entry.status
    if ($status.completed -eq $true -or ($status.status_str -and $status.status_str -ne "running")) {
        $errorMessage = $null
        foreach ($message in $status.messages) {
            $messageType = $null
            $messagePayload = $null
            if ($message -is [array] -or $message -is [System.Collections.IList]) {
                if ($message.Count -ge 1) {
                    $messageType = $message[0]
                }
                if ($message.Count -ge 2) {
                    $messagePayload = $message[1]
                }
            } elseif ($message.PSObject.Properties.Name -contains "0") {
                $messageType = $message.PSObject.Properties["0"].Value
                $messagePayload = $message.PSObject.Properties["1"].Value
            }

            if ($messageType -eq "execution_error" -and $messagePayload) {
                $errorMessage = [string]$messagePayload.exception_message
            }
        }
        $result = [pscustomobject]@{
            prompt_id = $PromptId
            status = $status.status_str
            completed = [bool]$status.completed
            error = $errorMessage
        }
        break
    }
}

if (-not $result) {
    $result = [pscustomobject]@{
        prompt_id = $PromptId
        status = "timeout"
        completed = $false
        error = "Timed out waiting for ComfyUI history."
    }
}

if ($ResultPath) {
    New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
    $result | ConvertTo-Json -Depth 8 | Set-Content -Path $ResultPath -Encoding UTF8
}

$result | ConvertTo-Json -Depth 8
if (-not $result.completed) {
    exit 1
}
