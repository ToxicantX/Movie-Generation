param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
    [string]$ComfyOutputRoot = "G:\ComfyUI\output",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review_refresh.json",
    [string]$RejectedPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\rejected_video_outputs.json",
    [string]$WorkflowCreateResultPath = ""
)

if (-not (Test-Path -LiteralPath $ReviewPath)) {
    throw "Review file not found: $ReviewPath"
}

try {
    $review = Get-Content -Path $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        review_path = $ReviewPath
        found = @()
        ready_to_review = $false
        error = "Failed to parse review JSON as UTF-8: $($_.Exception.Message)"
    }
    New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
    $result | ConvertTo-Json -Depth 20 | Set-Content -Path $ResultPath -Encoding UTF8
    $result | ConvertTo-Json -Depth 20
    exit 1
}
$workflowLookup = @{}
if ($WorkflowCreateResultPath -and (Test-Path -LiteralPath $WorkflowCreateResultPath)) {
    try {
        $workflowData = Get-Content -Path $WorkflowCreateResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in $workflowData.created) {
            if ($item.shot_id) {
                $workflowLookup[$item.shot_id] = $item
            }
        }
    } catch {
        throw "Failed to parse workflow create result: $WorkflowCreateResultPath. $($_.Exception.Message)"
    }
}

function Get-VideoPrefixFromWorkflow {
    param([string]$WorkflowPath)

    if (-not $WorkflowPath -or -not (Test-Path -LiteralPath $WorkflowPath)) {
        return $null
    }
    try {
        $workflow = Get-Content -Path $WorkflowPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($node in $workflow.prompt.PSObject.Properties.Value) {
            if ($node.class_type -eq "GeminiAPIVideoGenerate" -and $node.inputs.filename_prefix) {
                return [string]$node.inputs.filename_prefix
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Get-WorkflowVideoPrefix {
    param([string]$WorkflowPath)

    $prefix = Get-VideoPrefixFromWorkflow -WorkflowPath $WorkflowPath
    if ($prefix) {
        return (($prefix -replace '/', '\') + "*.mp4")
    }
    return $null
}

function Test-TechnicalFallbackShot {
    param($Shot)

    if ([string]$Shot.preferred_video_mode -match "technical_still_fallback|technical_fallback") {
        return $true
    }
    if ([string]$Shot.status -match "technical_fallback") {
        return $true
    }
    if ([string]$Shot.video_path -match "technical_still_fallback") {
        return $true
    }
    return $false
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)

    if (-not $Object) {
        return
    }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Remove-StaleFallbackNotes {
    param([string]$Notes, [string]$VideoPath)

    $replacement = "Non-fallback I2V candidate found during output refresh: $VideoPath. Human consistency review is required before formal release."
    if ([string]::IsNullOrWhiteSpace($Notes)) {
        return $replacement
    }

    $cleanLines = @()
    foreach ($line in ($Notes -split "`r?`n")) {
        if ($line -match "StillFrameVideoFallback|technical placeholder|technical fallback|fallback videos|still-frame fallback|Do not approve.*fallback") {
            continue
        }
        $cleanLines += $line
    }
    $clean = ($cleanLines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $replacement
    }
    if ($clean -match [regex]::Escape($replacement)) {
        return $clean
    }
    return "$clean`n$replacement"
}

function Find-I2V-Workflow {
    param($Shot, [string]$ReviewPath)

    $workflowDir = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows"
    $reviewName = [System.IO.Path]::GetFileNameWithoutExtension($ReviewPath)
    $segment = ""
    if ($reviewName -match "(ssj_ep01_sc\d+)") {
        $segment = $Matches[1]
    }
    $shotSuffix = ""
    if ([string]$Shot.shot_id -match "SH(\d+)") {
        $shotSuffix = "sh$($Matches[1])"
    }
    if (-not $segment -or -not $shotSuffix -or -not (Test-Path -LiteralPath $workflowDir)) {
        return ""
    }
    $matches = Get-ChildItem -LiteralPath $workflowDir -File -Filter "$($segment)_$($shotSuffix)_i2v*.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "technical|fallback|runway" } |
        Sort-Object LastWriteTime -Descending
    if (@($matches).Count -gt 0) {
        return $matches[0].FullName
    }
    return ""
}

function Get-VideoSearchPatterns {
    param($Shot)

    $patterns = @()
    if ((Test-TechnicalFallbackShot -Shot $Shot) -and $Shot.final_i2v_workflow) {
        $finalPattern = Get-WorkflowVideoPrefix -WorkflowPath ([string]$Shot.final_i2v_workflow)
        if ($finalPattern) {
            $patterns += $finalPattern
        }
    }
    if ((Test-TechnicalFallbackShot -Shot $Shot) -and $Shot.video_workflow -and ([string]$Shot.video_workflow) -notmatch "technical|fallback") {
        $workflowPattern = Get-WorkflowVideoPrefix -WorkflowPath ([string]$Shot.video_workflow)
        if ($workflowPattern) {
            $patterns += $workflowPattern
        }
    }
    if ($Shot.video_workflow) {
        $workflowPattern = Get-WorkflowVideoPrefix -WorkflowPath ([string]$Shot.video_workflow)
        if ($workflowPattern) {
            $patterns += $workflowPattern
        }
    }
    if ($workflowLookup.ContainsKey($Shot.shot_id)) {
        $prefix = Get-VideoPrefixFromWorkflow -WorkflowPath ([string]$workflowLookup[$Shot.shot_id].video_workflow)
        if ($prefix) {
            $patterns += (($prefix -replace '/', '\') + "*.mp4")
        }
    }

    $baseShot = ([string]$Shot.shot_id) -replace '^TEST_', ''
    $patterns += "AIShortDrama\videos\$($baseShot)_*i2v*.mp4"
    if ($Shot.video_filename_prefix) {
        $patterns += ((([string]$Shot.video_filename_prefix) -replace '/', '\') + "*.mp4")
    }
    return @($patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

$rejected = @{}
if (Test-Path -LiteralPath $RejectedPath) {
    try {
        $rejectedData = Get-Content -Path $RejectedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in $rejectedData.rejected) {
            if ($item.path) {
                $rejected[$item.path.ToLowerInvariant()] = $item
            }
        }
    } catch {
        throw "Failed to parse rejected output list: $RejectedPath. $($_.Exception.Message)"
    }
}

function Test-Mp4File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 64) {
            return $false
        }
        $buffer = New-Object byte[] 256
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).ToLowerInvariant()
        if ($text.StartsWith("<!doctype html") -or $text.StartsWith("<html")) {
            return $false
        }
        return $text.Substring(0, [Math]::Min($text.Length, 64)).Contains("ftyp")
    } finally {
        $stream.Dispose()
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    review_path = $ReviewPath
    workflow_create_result_path = $WorkflowCreateResultPath
    found = @()
    invalid = @()
    ready_to_review = $true
}

$expectedShotCount = 0
foreach ($shot in $review.shots) {
    $patterns = @(Get-VideoSearchPatterns -Shot $shot)
    $existingVideoPath = if ($shot.video_path) { [string]$shot.video_path } else { "" }
    if ($existingVideoPath -and -not $rejected.ContainsKey($existingVideoPath.ToLowerInvariant()) -and (Test-Mp4File -Path $existingVideoPath)) {
        $patterns = @($existingVideoPath) + $patterns
    }
    if (@($patterns).Count -eq 0) {
        continue
    }
    $expectedShotCount += 1
    $candidate = $null
    $candidatePattern = $null
    $invalidCandidates = @()
    foreach ($pattern in $patterns) {
        if ([System.IO.Path]::IsPathRooted($pattern) -and (Test-Path -LiteralPath $pattern)) {
            $candidates = @(Get-Item -LiteralPath $pattern)
        } else {
            $candidates = Get-ChildItem -Path (Join-Path $ComfyOutputRoot "AIShortDrama\videos") -Filter (Split-Path $pattern -Leaf) -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
        }
        foreach ($item in $candidates) {
            if ($rejected.ContainsKey($item.FullName.ToLowerInvariant())) {
                $invalidCandidates += $item
                continue
            }
            if (Test-Mp4File -Path $item.FullName) {
                $candidate = $item
                $candidatePattern = $pattern
                break
            }
            $invalidCandidates += $item
        }
        if ($candidate) {
            break
        }
    }
    if ($candidate) {
        $shot.video_path = $candidate.FullName
        $isNonFallbackI2V = ([string]$candidate.FullName -match "_i2v_") -and ([string]$candidate.FullName -notmatch "technical_still_fallback|fallback")
        if ($isNonFallbackI2V) {
            $resolvedWorkflow = ""
            if ($shot.final_i2v_workflow) {
                $resolvedWorkflow = [string]$shot.final_i2v_workflow
            } elseif ([string]$shot.video_workflow -and ([string]$shot.video_workflow) -notmatch "technical|fallback") {
                $resolvedWorkflow = [string]$shot.video_workflow
            } else {
                $resolvedWorkflow = Find-I2V-Workflow -Shot $shot -ReviewPath $ReviewPath
            }
            if ($resolvedWorkflow) {
                $shot.video_workflow = $resolvedWorkflow
                $shot | Add-Member -NotePropertyName "final_i2v_workflow" -NotePropertyValue $resolvedWorkflow -Force
                $prefix = Get-VideoPrefixFromWorkflow -WorkflowPath $resolvedWorkflow
                if ($prefix) {
                    $shot.video_filename_prefix = $prefix
                }
            } else {
                $relative = [string]$candidate.FullName
                $outputRoot = (Join-Path $ComfyOutputRoot "")
                if ($relative.StartsWith($outputRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $relative.Substring($outputRoot.Length)
                }
                $relative = [System.IO.Path]::ChangeExtension($relative, $null).TrimEnd(".")
                $shot.video_filename_prefix = ($relative -replace '\\', '/')
            }
            $shot.preferred_video_mode = "image_to_video_required"
            $shot.status = "generated_pending_human_review"
            $shot.notes = Remove-StaleFallbackNotes -Notes ([string]$shot.notes) -VideoPath $candidate.FullName
            foreach ($prop in $shot.checks.PSObject.Properties) {
                if ([string]$prop.Value -match "technical_fallback") {
                    $shot.checks.($prop.Name) = "pending_human_review"
                }
            }
        }
        if ($shot.status -in @("pending", "pending_human_review", "storyboard_generated_pending_review", "smoke_test_only", "generated_invalid_file", "needs_regeneration")) {
            $shot.status = "generated_pending_human_review"
        }
        foreach ($prop in $shot.checks.PSObject.Properties) {
            if ($prop.Value -eq "pending" -or $prop.Value -eq "needs_regeneration") {
                $shot.checks.($prop.Name) = "pending_human_review"
            }
        }
        if ($shot.checks.PSObject.Properties.Name -contains "technical_output") {
            $shot.checks.technical_output = "pass"
        }
        $result.found += [ordered]@{
            shot_id = $shot.shot_id
            video_path = $candidate.FullName
            pattern = $candidatePattern
            searched_patterns = $patterns
            last_write_time = $candidate.LastWriteTime.ToString("s")
        }
    } else {
        if ($invalidCandidates.Count -gt 0) {
            $shot.status = "generated_invalid_file"
            $result.invalid += [ordered]@{
                shot_id = $shot.shot_id
                patterns = $patterns
                paths = @($invalidCandidates | Select-Object -ExpandProperty FullName)
            }
        }
        $result.ready_to_review = $false
    }
}

if ($expectedShotCount -ne @($review.shots).Count) {
    $result.ready_to_review = $false
    $result.expected_shot_count = $expectedShotCount
    $result.review_shot_count = @($review.shots).Count
}

if ($result.ready_to_review) {
    if ($review.global_decision -ne "approved_for_episode_cut") {
        $review.global_decision = "pending_human_consistency_review"
        $review.global_reason = "Reference-driven videos were found for all three test shots. Human consistency review is required before episode cut."
    }
} else {
    $review.global_decision = "not_ready_for_episode_cut"
    $review.global_reason = "One or more reference-driven videos are missing or invalid."
}

if ($review.provider_status) {
    $fallbackShots = @($review.shots | Where-Object { Test-TechnicalFallbackShot -Shot $_ })
    if (@($fallbackShots).Count -eq 0 -and $result.ready_to_review) {
        Set-JsonProperty -Object $review.provider_status -Name "current_video_mode" -Value "i2v_generated_pending_human_review"
        Set-JsonProperty -Object $review.provider_status -Name "fallback_note" -Value "Final non-fallback I2V candidates are present for every shot. Human consistency review is required before formal release."
    } elseif (@($fallbackShots).Count -gt 0) {
        Set-JsonProperty -Object $review.provider_status -Name "current_video_mode" -Value "mixed_i2v_and_technical_fallback"
        Set-JsonProperty -Object $review.provider_status -Name "fallback_note" -Value "One or more shots still contain technical fallback markers and must be replaced before formal release."
    }
}
$review.updated = (Get-Date).ToString("yyyy-MM-dd")

$review | ConvertTo-Json -Depth 20 | Set-Content -Path $ReviewPath -Encoding UTF8
New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 20 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20

if (-not $result.ready_to_review) {
    exit 1
}
