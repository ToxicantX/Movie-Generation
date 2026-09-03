param(
    [Parameter(Mandatory = $true)]
    [string]$ShotId,
    [Parameter(Mandatory = $true)]
    [ValidateSet("pending", "pass", "needs_regeneration", "blocked")]
    [string]$Decision,
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01.json",
    [ValidateSet("storyboard", "video", "segment", "episode")]
    [string]$RegenerationScope = "",
    [string]$Reason = "",
    [string]$Notes = "",
    [string]$Reviewer = "",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep01_human_review_decision_set_result.json"
)

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    throw "Decision file not found: $DecisionPath"
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$matches = @($decisionData.decisions | Where-Object { [string]$_.shot_id -eq $ShotId })
if (@($matches).Count -eq 0) {
    throw "Shot decision not found: $ShotId"
}
if (@($matches).Count -gt 1) {
    throw "Multiple shot decisions found for: $ShotId"
}

$entry = $matches[0]
$oldDecision = if ($entry.decision) { [string]$entry.decision } else { "pending" }
$oldScope = if ($entry.regeneration_scope) { [string]$entry.regeneration_scope } else { "video" }

$entry.decision = $Decision
if ($RegenerationScope -ne "") {
    $entry.regeneration_scope = $RegenerationScope
}
if ($Reason -ne "") {
    $entry.reason = $Reason
}
if ($Notes -ne "") {
    $entry.notes = $Notes
}
if ($Reviewer -ne "") {
    $decisionData.reviewer = $Reviewer
}
$decisionData.updated = (Get-Date).ToString("s")

$decisionData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $DecisionPath -Encoding UTF8

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    shot_id = $ShotId
    old_decision = $oldDecision
    new_decision = $Decision
    old_regeneration_scope = $oldScope
    new_regeneration_scope = if ($entry.regeneration_scope) { [string]$entry.regeneration_scope } else { "video" }
    reason = $Reason
    notes = $Notes
    reviewer = $Reviewer
    ok = $true
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 10
