param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_human_decision.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_human_decision_result.json"
)

if (-not (Test-Path -LiteralPath $ReviewPath)) {
    throw "Review file not found: $ReviewPath"
}
if (-not (Test-Path -LiteralPath $DecisionPath)) {
    $reviewForTemplate = Get-Content -Path $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $templateShots = @()
    foreach ($shot in $reviewForTemplate.shots) {
        $templateShots += [ordered]@{ shot_id = $shot.shot_id; decision = "pending"; notes = "" }
    }
    $template = [ordered]@{
        updated = (Get-Date).ToString("s")
        reviewer = ""
        global_decision = "pending"
        shots = $templateShots
    }
    New-Item -ItemType Directory -Path (Split-Path $DecisionPath) -Force | Out-Null
    $template | ConvertTo-Json -Depth 10 | Set-Content -Path $DecisionPath -Encoding UTF8
    throw "Decision file did not exist, so a template was created: $DecisionPath"
}

$review = Get-Content -Path $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$decision = Get-Content -Path $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$valid = @("pending", "pass", "needs_regeneration", "blocked")
$shotResults = @()

foreach ($shotDecision in $decision.shots) {
    if ($shotDecision.decision -notin $valid) {
        throw "Invalid decision for $($shotDecision.shot_id): $($shotDecision.decision)"
    }
    $shot = $review.shots | Where-Object { $_.shot_id -eq $shotDecision.shot_id } | Select-Object -First 1
    if (-not $shot) {
        throw "Unknown shot_id in decision file: $($shotDecision.shot_id)"
    }
    if ($shotDecision.decision -eq "pass") {
        $shot.status = "pass"
        foreach ($prop in $shot.checks.PSObject.Properties) {
            if ($prop.Value -eq "pending_human_review" -or $prop.Value -eq "pending") {
                $shot.checks.($prop.Name) = "pass"
            }
        }
    } elseif ($shotDecision.decision -eq "needs_regeneration") {
        $shot.status = "needs_regeneration"
        foreach ($prop in $shot.checks.PSObject.Properties) {
            if ($prop.Value -eq "pending_human_review" -or $prop.Value -eq "pending") {
                $shot.checks.($prop.Name) = "needs_regeneration"
            }
        }
    } elseif ($shotDecision.decision -eq "blocked") {
        $shot.status = "blocked"
    }
    if ($shotDecision.notes) {
        $shot.notes = "$($shot.notes)`nHuman review: $($shotDecision.notes)"
    }
    $shotResults += [ordered]@{
        shot_id = $shot.shot_id
        decision = $shotDecision.decision
        status = $shot.status
    }
}

$statuses = @($review.shots | ForEach-Object { $_.status })
if ($statuses -contains "needs_regeneration") {
    $review.global_decision = "needs_regeneration"
    $review.global_reason = "At least one shot failed human consistency review."
} elseif ($statuses -contains "blocked") {
    $review.global_decision = "blocked"
    $review.global_reason = "At least one shot is blocked by human review."
} elseif (($statuses | Where-Object { $_ -ne "pass" }).Count -eq 0) {
    $review.global_decision = "approved_for_episode_cut"
    $review.global_reason = "All shots passed human consistency review."
} else {
    $review.global_decision = "pending_human_consistency_review"
    $review.global_reason = "One or more shots still require human consistency review."
}
$review.updated = (Get-Date).ToString("yyyy-MM-dd")

$review | ConvertTo-Json -Depth 20 | Set-Content -Path $ReviewPath -Encoding UTF8
$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = $ReviewPath
    decision_path = $DecisionPath
    global_decision = $review.global_decision
    shots = $shotResults
}
New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12

if ($review.global_decision -in @("needs_regeneration", "blocked", "pending_human_consistency_review")) {
    exit 1
}
