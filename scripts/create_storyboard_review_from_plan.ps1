param(
    [string]$PlanPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_storyboard_plan.json",
    [string]$WorkflowCreateResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\segment_workflow_create_result.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_storyboard_review.json"
)

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Plan file not found: $PlanPath"
}
if (-not (Test-Path -LiteralPath $WorkflowCreateResultPath)) {
    throw "Workflow create result not found: $WorkflowCreateResultPath"
}

$plan = Get-Content -Path $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$workflows = Get-Content -Path $WorkflowCreateResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$shots = @()

foreach ($shot in $plan.shots) {
    $wf = $workflows.created | Where-Object { $_.shot_id -eq $shot.shot_id } | Select-Object -First 1
    $storyboardPath = $wf.expected_storyboard_path
    $exists = $storyboardPath -and (Test-Path -LiteralPath $storyboardPath)
    $shots += [ordered]@{
        shot_id = $shot.shot_id
        title = $shot.title
        beat = $shot.beat
        duration_seconds = $shot.duration_seconds
        storyboard_path = $storyboardPath
        storyboard_filename_prefix = $shot.storyboard_filename_prefix
        video_filename_prefix = $shot.video_filename_prefix
        storyboard_workflow = $wf.storyboard_workflow
        video_workflow = $wf.video_workflow
        video_path = $null
        preferred_video_mode = "image_to_video_required"
        status = if ($exists) { "storyboard_generated_pending_review" } else { "storyboard_missing" }
        checks = [ordered]@{
            character_identity = "pending_human_review"
            character_props = "pending_human_review"
            location_identity = "pending_human_review"
            storyboard_match = "pending_human_review"
            motion_continuity = "pending_human_review"
            safety_constraints = "pending_human_review"
            clean_output = "pending_human_review"
            technical_output = if ($exists) { "pass" } else { "missing" }
        }
        notes = "Storyboard stage only. Video should use this approved storyboard as the single visual source of truth."
    }
}

$ready = (($shots | Where-Object { $_.status -ne "storyboard_generated_pending_review" }).Count -eq 0)
$review = [ordered]@{
    project = if ($plan.PSObject.Properties.Name -contains "project") { $plan.project } else { "AI short-drama factory" }
    source = $plan.source
    review_schema = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\consistency_review_schema.json"
    segment_id = $plan.segment_id
    beat_id = $plan.beat_id
    title = $plan.title
    updated = (Get-Date).ToString("yyyy-MM-dd")
    global_decision = if ($ready) { "pending_storyboard_human_review" } else { "storyboard_generation_incomplete" }
    global_reason = if ($ready) { "All storyboard frames were generated and need human review before I2V." } else { "One or more storyboard frames are missing." }
    shots = $shots
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$review | ConvertTo-Json -Depth 20 | Set-Content -Path $ResultPath -Encoding UTF8
$review | ConvertTo-Json -Depth 20
if (-not $ready) {
    exit 1
}
