param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_markdown_import_result.json",
    [switch]$DryRun
)

$validDecisionLabels = @("pass", "needs_regeneration", "blocked")

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    throw "Decision file not found: $DecisionPath"
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$updates = @()
$warnings = @()
$packageCache = @{}

function Read-ReviewPackage {
    param([string]$Path)

    if (-not $Path) {
        return $null
    }
    if ($script:packageCache.ContainsKey($Path)) {
        return $script:packageCache[$Path]
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $script:packageCache[$Path] = $null
        return $null
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $script:packageCache[$Path] = $text
    return $text
}

function Get-Shot-Section {
    param([string]$Markdown, [string]$ShotId)

    if ([string]::IsNullOrWhiteSpace($Markdown) -or [string]::IsNullOrWhiteSpace($ShotId)) {
        return ""
    }
    $escaped = [regex]::Escape($ShotId)
    $pattern = [string]::Format('(?ms)^##\s+{0}\s*\r?\n(.*?)(?=^##\s+|\z)', $escaped)
    $match = [regex]::Match($Markdown, $pattern)
    if (-not $match.Success) {
        return ""
    }
    return $match.Groups[1].Value
}

function Get-Checked-Decisions {
    param([string]$Section)

    $checked = @()
    foreach ($label in $validDecisionLabels) {
        $escaped = [regex]::Escape($label)
        if ($Section -match "(?im)^\s*-\s*\[[xX]\]\s+$escaped\s*$") {
            $checked += $label
        }
    }
    return $checked
}

foreach ($decision in @($decisionData.decisions)) {
    $packagePath = if ($decision.review_package_markdown) { [string]$decision.review_package_markdown } else { "" }
    $shotId = if ($decision.shot_id) { [string]$decision.shot_id } else { "" }
    $markdown = Read-ReviewPackage -Path $packagePath
    if ($null -eq $markdown) {
        $warnings += [ordered]@{
            review_id = if ($decision.review_id) { [string]$decision.review_id } else { "" }
            shot_id = $shotId
            review_package_markdown = $packagePath
            reason = "Review package markdown not found."
        }
        continue
    }

    $section = Get-Shot-Section -Markdown $markdown -ShotId $shotId
    if (-not $section) {
        $warnings += [ordered]@{
            review_id = if ($decision.review_id) { [string]$decision.review_id } else { "" }
            shot_id = $shotId
            review_package_markdown = $packagePath
            reason = "Shot section not found in review package markdown."
        }
        continue
    }

    $checked = @(Get-Checked-Decisions -Section $section)
    if (@($checked).Count -eq 0) {
        continue
    }
    if (@($checked).Count -gt 1) {
        $warnings += [ordered]@{
            review_id = if ($decision.review_id) { [string]$decision.review_id } else { "" }
            shot_id = $shotId
            review_package_markdown = $packagePath
            checked = $checked
            reason = "More than one human decision checkbox is checked; leaving decision unchanged."
        }
        continue
    }

    $oldDecision = if ($decision.decision) { [string]$decision.decision } else { "pending" }
    $newDecision = [string]$checked[0]
    if ($oldDecision -ne $newDecision) {
        $updates += [ordered]@{
            review_id = if ($decision.review_id) { [string]$decision.review_id } else { "" }
            shot_id = $shotId
            old_decision = $oldDecision
            new_decision = $newDecision
            review_package_markdown = $packagePath
        }
        $decision.decision = $newDecision
    }
}

if (-not $DryRun) {
    $decisionData.updated = (Get-Date).ToString("s")
    $decisionData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $DecisionPath -Encoding UTF8
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    dry_run = [bool]$DryRun
    decision_path = $DecisionPath
    update_count = @($updates).Count
    warning_count = @($warnings).Count
    updates = $updates
    warnings = $warnings
    ok = (@($warnings | Where-Object { $_.reason -match "More than one" }).Count -eq 0)
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ok) {
    exit 1
}
