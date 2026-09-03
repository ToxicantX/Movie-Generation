param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc10_storyboard_review.json",
    [string]$FallbackCreateResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc10_technical_still_fallback_workflow_create_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\technical_still_fallback_review_apply_result.json",
    [string]$ComfyOutputRoot = "G:\ComfyUI\output"
)

if (-not (Test-Path -LiteralPath $ReviewPath)) {
    throw "Review file not found: $ReviewPath"
}
if (-not (Test-Path -LiteralPath $FallbackCreateResultPath)) {
    throw "Fallback create result not found: $FallbackCreateResultPath"
}

function Resolve-ExistingPathText {
    param([string]$PathText)

    if (-not $PathText) { return "" }
    try {
        if ([System.IO.Path]::IsPathRooted($PathText)) {
            return [System.IO.Path]::GetFullPath($PathText)
        }
        return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $PathText))
    } catch {
        return $PathText
    }
}

function Add-Or-Set {
    param($Object, [string]$Name, $Value)

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Test-Mp4File {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 64) { return $false }
        $buffer = New-Object byte[] 256
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).ToLowerInvariant()
        return $text.Substring(0, [Math]::Min($text.Length, 64)).Contains("ftyp")
    } finally {
        $stream.Dispose()
    }
}

$review = Get-Content -LiteralPath $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fallback = Get-Content -LiteralPath $FallbackCreateResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fallbackLookup = @{}
foreach ($item in @($fallback.created)) {
    if ($item.shot_id) {
        $fallbackLookup[[string]$item.shot_id] = $item
    }
}

$applied = @()
$missing = @()
$fallbackNote = "Video note: Gemini reference-driven I2V is not used because the current contract/probe does not provide a safe supported file_ids path; Runway live I2V cannot run because RUNWAYML_API_SECRET is missing. Technical still fallback is used only for test pipeline continuity and must be replaced before production release."

foreach ($shot in @($review.shots)) {
    $shotId = [string]$shot.shot_id
    if (-not $fallbackLookup.ContainsKey($shotId)) {
        $missing += [ordered]@{
            shot_id = $shotId
            reason = "No fallback workflow entry for shot."
        }
        continue
    }

    $item = $fallbackLookup[$shotId]
    $workflowPath = Resolve-ExistingPathText -PathText ([string]$item.workflow_path)
    $videoPath = Resolve-ExistingPathText -PathText ([string]$item.expected_video_path)
    $videoExists = Test-Mp4File -Path $videoPath

    Add-Or-Set -Object $shot -Name "video_workflow" -Value $workflowPath
    Add-Or-Set -Object $shot -Name "final_i2v_workflow" -Value $workflowPath
    Add-Or-Set -Object $shot -Name "video_path" -Value $videoPath
    Add-Or-Set -Object $shot -Name "video_filename_prefix" -Value ([string]$item.filename_prefix)
    Add-Or-Set -Object $shot -Name "preferred_video_mode" -Value "technical_still_fallback"
    if ($shot.status -in @("storyboard_generated_pending_review", "pending", "pending_human_review", "needs_regeneration")) {
        $shot.status = if ($videoExists) { "generated_pending_human_review" } else { "technical_fallback_missing_output" }
    }
    if ($shot.checks -and ($shot.checks.PSObject.Properties.Name -contains "technical_output")) {
        $shot.checks.technical_output = if ($videoExists) { "pass" } else { "missing" }
    }

    $notes = if ($shot.notes) { [string]$shot.notes } else { "" }
    if ($notes -notmatch [regex]::Escape($fallbackNote)) {
        $shot.notes = (@($notes, $fallbackNote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    }

    $applied += [ordered]@{
        shot_id = $shotId
        workflow_path = $workflowPath
        video_path = $videoPath
        video_exists = $videoExists
    }
}

if ($review.global_decision -ne "approved_for_episode_cut") {
    $review.global_decision = "pending_human_consistency_review"
    $review.global_reason = "Technical still fallback videos were found or mapped for every generated storyboard. Human consistency review is required before episode cut; production release requires real I2V regeneration."
}
$review.updated = (Get-Date).ToString("yyyy-MM-dd")

$ok = (@($missing).Count -eq 0 -and @($applied | Where-Object { -not $_.video_exists }).Count -eq 0)

$review | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReviewPath -Encoding UTF8

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = $ReviewPath
    fallback_create_result_path = $FallbackCreateResultPath
    applied_count = @($applied).Count
    missing_count = @($missing).Count
    applied = $applied
    missing = $missing
    ok = [bool]$ok
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $ok) {
    exit 1
}
