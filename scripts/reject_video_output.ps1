param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$ShotId,
    [string]$Reason = "",
    [string]$RejectedPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\rejected_video_outputs.json"
)

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Video file not found: $Path"
}

$data = [ordered]@{
    updated = (Get-Date).ToString("s")
    rejected = @()
}
if (Test-Path -LiteralPath $RejectedPath) {
    $existing = Get-Content -Path $RejectedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $data.rejected = @($existing.rejected)
}

$fullPath = (Resolve-Path -LiteralPath $Path).Path
$lower = $fullPath.ToLowerInvariant()
$kept = @()
foreach ($item in $data.rejected) {
    if ($item.path -and $item.path.ToLowerInvariant() -eq $lower) {
        continue
    }
    $kept += $item
}
$kept += [ordered]@{
    updated = (Get-Date).ToString("s")
    shot_id = $ShotId
    path = $fullPath
    reason = $Reason
}
$data.rejected = $kept
$data.updated = (Get-Date).ToString("s")

New-Item -ItemType Directory -Path (Split-Path $RejectedPath) -Force | Out-Null
$data | ConvertTo-Json -Depth 8 | Set-Content -Path $RejectedPath -Encoding UTF8
$data | ConvertTo-Json -Depth 8
