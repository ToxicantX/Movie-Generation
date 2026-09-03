param(
    [string]$StatePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\current_pipeline_state.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ai_short_drama_status_report.json",
    [string]$MarkdownPath = "G:\ComfyUI\output\AIShortDrama\review_packages\AI_SHORT_DRAMA_STATUS.md",
    [string]$ComfyUrl = "http://127.0.0.1:8188",
    [switch]$SkipComfyProbe
)

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Count-Decisions {
    param($DecisionData)

    $counts = [ordered]@{
        pending = 0
        pass = 0
        needs_regeneration = 0
        blocked = 0
        other = 0
    }
    foreach ($decision in @($DecisionData.decisions)) {
        $value = if ($decision.decision) { [string]$decision.decision } else { "pending" }
        if ($counts.Contains($value)) {
            $counts[$value] += 1
        } else {
            $counts.other += 1
        }
    }
    return $counts
}

function Count-ShotStatuses {
    param($ReviewData)

    $counts = [ordered]@{
        pending = 0
        pass = 0
        needs_regeneration = 0
        blocked = 0
        other = 0
    }
    foreach ($shot in @($ReviewData.shots)) {
        $value = if ($shot.status) { [string]$shot.status } else { "pending" }
        if ($value -in @("generated_pending_human_review", "storyboard_generated_pending_review", "pending_human_review")) {
            $value = "pending"
        }
        if ($counts.Contains($value)) {
            $counts[$value] += 1
        } else {
            $counts.other += 1
        }
    }
    return $counts
}

function Get-QueueSummary {
    param([string]$Url)

    if ($SkipComfyProbe) {
        return [ordered]@{
            ok = $true
            skipped = $true
            idle = $null
            running = 0
            pending = 0
            items = @()
            error = $null
        }
    }

    try {
        $queue = Invoke-RestMethod -Uri "$Url/queue" -TimeoutSec 10
        $items = @()
        foreach ($entry in @($queue.queue_running + $queue.queue_pending)) {
            $promptId = if (@($entry).Count -gt 1) { [string]$entry[1] } else { "" }
            $prompt = if (@($entry).Count -gt 2) { $entry[2] } else { $null }
            $meta = if (@($entry).Count -gt 3) { $entry[3] } else { $null }
            $classTypes = @()
            $prefixes = @()
            if ($prompt) {
                foreach ($property in $prompt.PSObject.Properties) {
                    $node = $property.Value
                    if ($node.class_type) {
                        $classTypes += [string]$node.class_type
                    }
                    if ($node.inputs -and $node.inputs.filename_prefix) {
                        $prefixes += [string]$node.inputs.filename_prefix
                    }
                }
            }
            $items += [ordered]@{
                prompt_id = $promptId
                client_id = if ($meta -and $meta.client_id) { [string]$meta.client_id } else { "" }
                class_types = @($classTypes | Select-Object -Unique)
                filename_prefixes = @($prefixes | Select-Object -Unique)
            }
        }

        $runningCount = @($queue.queue_running).Count
        $pendingCount = @($queue.queue_pending).Count
        return [ordered]@{
            ok = $true
            skipped = $false
            idle = [bool]($runningCount -eq 0 -and $pendingCount -eq 0)
            running = $runningCount
            pending = $pendingCount
            items = $items
            error = $null
        }
    } catch {
        return [ordered]@{
            ok = $false
            skipped = $false
            idle = $null
            running = 0
            pending = 0
            items = @()
            error = $_.Exception.Message
        }
    }
}

function Add-NextAction {
    param([string]$Text)
    $script:nextActions += $Text
}

function Get-SegmentReport {
    param(
        [string]$SegmentId,
        [string]$DecisionPath,
        [string]$PrecheckPath,
        [string]$QueuePath,
        [string]$CyclePath,
        [string]$PostprocessPath,
        [string]$VideoReviewPath,
        [string]$FormalCutPath,
        [string]$NextSeedPath,
        [string]$StoryboardReviewPath = "",
        [string]$StoryboardDashboardPath = "",
        [string]$StoryboardReviewServerUrl = "",
        [string]$StoryToI2vScript = ""
    )

    $decisions = Read-JsonFile -Path $DecisionPath
    $precheck = Read-JsonFile -Path $PrecheckPath
    $queue = Read-JsonFile -Path $QueuePath
    $cycle = Read-JsonFile -Path $CyclePath
    $postprocess = Read-JsonFile -Path $PostprocessPath
    $videoReview = Read-JsonFile -Path $VideoReviewPath
    $formalCut = Read-JsonFile -Path $FormalCutPath

    $decisionCounts = if ($decisions) { Count-Decisions -DecisionData $decisions } else { $null }
    $videoReviewCounts = if ($videoReview) { Count-ShotStatuses -ReviewData $videoReview } else { $null }
    $formalCutReady = [bool]($formalCut -and $formalCut.ok -and $formalCut.output_path -and (Test-Path -LiteralPath ([string]$formalCut.output_path)))

    return [ordered]@{
        segment_id = $SegmentId
        decision_path = $DecisionPath
        decision_counts = $decisionCounts
        precheck = if ($precheck) {
            [ordered]@{
                ok = [bool]$precheck.ok
                pending = [int]$precheck.counts.pending
                pass = [int]$precheck.counts.pass
                needs_regeneration = [int]$precheck.counts.needs_regeneration
                blocked = [int]$precheck.counts.blocked
                ready_for_i2v_queue = if ($null -ne $precheck.ready_for_i2v_queue) { [bool]$precheck.ready_for_i2v_queue } else { $false }
                all_storyboards_reviewed = if ($null -ne $precheck.all_storyboards_reviewed) { [bool]$precheck.all_storyboards_reviewed } else { $false }
            }
        } else { $null }
        queue = if ($queue) {
            [ordered]@{
                ok = [bool]$queue.ok
                queue_count = if ($null -ne $queue.queue_count) { [int]$queue.queue_count } else { 0 }
                pending = if ($queue.summary -and $null -ne $queue.summary.pending) { [int]$queue.summary.pending } else { 0 }
                pass = if ($queue.summary -and $null -ne $queue.summary.pass) { [int]$queue.summary.pass } else { 0 }
                needs_regeneration = if ($queue.summary -and $null -ne $queue.summary.needs_regeneration) { [int]$queue.summary.needs_regeneration } else { 0 }
                blocked = if ($queue.summary -and $null -ne $queue.summary.blocked) { [int]$queue.summary.blocked } else { 0 }
            }
        } else { $null }
        cycle_state = if ($cycle -and $cycle.state) { [string]$cycle.state } else { "" }
        postprocess_state = if ($postprocess -and $postprocess.state) { [string]$postprocess.state } else { "" }
        postprocess_path = $PostprocessPath
        video_review_path = $VideoReviewPath
        video_review_global_decision = if ($videoReview -and $videoReview.global_decision) { [string]$videoReview.global_decision } else { "" }
        video_review_counts = $videoReviewCounts
        formal_cut = if ($formalCut) {
            [ordered]@{
                ok = [bool]$formalCut.ok
                output_path = if ($formalCut.output_path) { [string]$formalCut.output_path } else { "" }
                frame_count = if ($formalCut.frame_count) { [int]$formalCut.frame_count } else { 0 }
                fps = if ($formalCut.fps) { [double]$formalCut.fps } else { 0 }
                bytes = if ($formalCut.bytes) { [int64]$formalCut.bytes } else { 0 }
                ready = $formalCutReady
            }
        } else { $null }
        next_seed = $NextSeedPath
        storyboard_review = $StoryboardReviewPath
        storyboard_dashboard = $StoryboardDashboardPath
        storyboard_review_server = $StoryboardReviewServerUrl
        storyboard_to_i2v_script = $StoryToI2vScript
        ready = $formalCutReady
    }
}

function Add-SegmentMarkdown {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        $Segment
    )

    $Lines.Add("## $($Segment.segment_id)")
    if ($Segment.decision_counts) {
        $Lines.Add("- Storyboard decisions: pending=$($Segment.decision_counts.pending), pass=$($Segment.decision_counts.pass), needs_regeneration=$($Segment.decision_counts.needs_regeneration), blocked=$($Segment.decision_counts.blocked)")
    }
    if ($Segment.queue) {
        $Lines.Add(('- Storyboard I2V queue: count={0}, ok=`{1}`' -f $Segment.queue.queue_count, $Segment.queue.ok))
    }
    if ($Segment.video_review_counts) {
        $Lines.Add("- Video review decisions: pending=$($Segment.video_review_counts.pending), pass=$($Segment.video_review_counts.pass), needs_regeneration=$($Segment.video_review_counts.needs_regeneration), blocked=$($Segment.video_review_counts.blocked)")
        $Lines.Add(('- Video review global decision: `{0}`' -f $Segment.video_review_global_decision))
    }
    if ($Segment.formal_cut) {
        $Lines.Add(('- Formal segment cut: ready=`{0}`, frames={1}, fps={2}, bytes={3}' -f $Segment.formal_cut.ready, $Segment.formal_cut.frame_count, $Segment.formal_cut.fps, $Segment.formal_cut.bytes))
        $Lines.Add("- Formal segment path: $($Segment.formal_cut.output_path)")
    }
    if ($Segment.storyboard_review) {
        $Lines.Add("- Storyboard review: $($Segment.storyboard_review)")
    }
    if ($Segment.storyboard_dashboard) {
        $Lines.Add("- Storyboard dashboard: $($Segment.storyboard_dashboard)")
    }
    if ($Segment.storyboard_review_server) {
        $Lines.Add("- Storyboard review server: $($Segment.storyboard_review_server)")
    }
    $Lines.Add(('- I2V postprocess state: `{0}`' -f $Segment.postprocess_state))
    if ($Segment.next_seed) {
        $Lines.Add("- Next seed: $($Segment.next_seed)")
    }
    $Lines.Add("")
}

function Get-Ep02SegmentDefinitions {
    param([string]$ManifestDir)

    if (-not (Test-Path -LiteralPath $ManifestDir)) {
        return @()
    }

    $reviewFiles = Get-ChildItem -LiteralPath $ManifestDir -Filter "ssj_ep02_sc*_storyboard_review.json" |
        Where-Object { $_.Name -match '^ssj_ep02_sc(\d+)_storyboard_review\.json$' } |
        Sort-Object { [int]([regex]::Match($_.Name, '^ssj_ep02_sc(\d+)_storyboard_review\.json$').Groups[1].Value) }

    $definitions = @()
    foreach ($file in @($reviewFiles)) {
        $match = [regex]::Match($file.Name, '^ssj_ep02_sc(\d+)_storyboard_review\.json$')
        if (-not $match.Success) {
            continue
        }

        $sc = $match.Groups[1].Value
        $nextSc = ([int]$sc) + 1
        $nextScText = $nextSc.ToString("00")
        $serverUrl = ""
        $storyToI2vScript = ""
        if ($sc -eq "01") {
            $serverUrl = "http://127.0.0.1:8098/SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html"
            $storyToI2vScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_ep02_sc01_storyboard_to_i2v_pipeline.ps1"
        }

        $definitions += [ordered]@{
            SegmentId = "EP02 SC$sc"
            DecisionPath = Join-Path $ManifestDir "storyboard_review_decisions_ep02_sc$sc.json"
            PrecheckPath = Join-Path $ManifestDir "storyboard_review_decisions_ep02_sc$sc`_precheck.json"
            QueuePath = Join-Path $ManifestDir "storyboard_i2v_queue_ep02_sc$sc.json"
            CyclePath = Join-Path $ManifestDir "storyboard_review_cycle_ep02_sc$sc`_result.json"
            PostprocessPath = Join-Path $ManifestDir "ssj_ep02_sc$sc`_i2v_postprocess_result.json"
            VideoReviewPath = Join-Path $ManifestDir "ssj_ep02_sc$sc`_storyboard_review.json"
            FormalCutPath = Join-Path $ManifestDir "ssj_ep02_sc$sc`_formal_cut_result.json"
            NextSeedPath = Join-Path $ManifestDir "ssj_ep02_sc$nextScText`_seed.json"
            StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC$sc`_STORYBOARD\human_review.md"
            StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC$sc`_STORYBOARD_DASHBOARD.html"
            StoryboardReviewServerUrl = $serverUrl
            StoryToI2vScript = $storyToI2vScript
        }
    }

    return $definitions
}

$root = Split-Path -Parent $PSScriptRoot
$manifests = Join-Path $root "manifests"
$scripts = Join-Path $root "scripts"
$state = Read-JsonFile -Path $StatePath
$ep01DecisionPath = Join-Path $manifests "human_review_decisions_ep01.json"
$ep01PrecheckPath = Join-Path $manifests "human_review_decisions_ep01_precheck.json"
$ep01CyclePath = Join-Path $manifests "ep01_human_review_cycle_result.json"
$ep01GatePath = Join-Path $manifests "ep01_formal_cut_gate_check.json"
$hygienePath = Join-Path $manifests "prompt_secret_hygiene_check.json"
$ep01HumanReviewDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_HUMAN_REVIEW_DASHBOARD.html"
$ep01HumanReviewServerUrl = "http://127.0.0.1:8097/SSJ_EP01_HUMAN_REVIEW_DASHBOARD.html"
$segments = @(
    [ordered]@{
        SegmentId = "EP02 SC01"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc01.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc01_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc01.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc01_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc01_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc01_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc01_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc02_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = "http://127.0.0.1:8098/SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html"
        StoryToI2vScript = "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_ep02_sc01_storyboard_to_i2v_pipeline.ps1"
    }
    [ordered]@{
        SegmentId = "EP02 SC02"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc02.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc02_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc02.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc02_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc02_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc02_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc02_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc03_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC02_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC02_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC03"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc03.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc03_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc03.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc03_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc03_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc03_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc03_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc04_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC03_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC03_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC04"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc04.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc04_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc04.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc04_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc04_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc04_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc04_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc05_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC04_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC04_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC05"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc05.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc05_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc05.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc05_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc05_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc05_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc05_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc06_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC05_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC05_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC06"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc06.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc06_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc06.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc06_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc06_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc06_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc06_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc07_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC06_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC06_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC07"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc07.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc07_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc07.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc07_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc07_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc07_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc07_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc08_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC07_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC07_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC08"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc08.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc08_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc08.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc08_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc08_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc08_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc08_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc09_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC08_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC08_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC09"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc09.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc09_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc09.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc09_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc09_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc09_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc09_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc10_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC09_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC09_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC10"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc10.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc10_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc10.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc10_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc10_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc10_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc10_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc11_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC10_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC10_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
    [ordered]@{
        SegmentId = "EP02 SC11"
        DecisionPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc11.json"
        PrecheckPath = Join-Path $manifests "storyboard_review_decisions_ep02_sc11_precheck.json"
        QueuePath = Join-Path $manifests "storyboard_i2v_queue_ep02_sc11.json"
        CyclePath = Join-Path $manifests "storyboard_review_cycle_ep02_sc11_result.json"
        PostprocessPath = Join-Path $manifests "ssj_ep02_sc11_i2v_postprocess_result.json"
        VideoReviewPath = Join-Path $manifests "ssj_ep02_sc11_storyboard_review.json"
        FormalCutPath = Join-Path $manifests "ssj_ep02_sc11_formal_cut_result.json"
        NextSeedPath = Join-Path $manifests "ssj_ep02_sc12_seed.json"
        StoryboardReviewPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC11_STORYBOARD\human_review.md"
        StoryboardDashboardPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC11_STORYBOARD_DASHBOARD.html"
        StoryboardReviewServerUrl = ""
        StoryToI2vScript = ""
    }
)

$discoveredSegments = Get-Ep02SegmentDefinitions -ManifestDir $manifests
if (@($discoveredSegments).Count -gt 0) {
    $segments = $discoveredSegments
}

$ep01Decisions = Read-JsonFile -Path $ep01DecisionPath
$ep01Precheck = Read-JsonFile -Path $ep01PrecheckPath
$ep01Cycle = Read-JsonFile -Path $ep01CyclePath
$ep01Gate = Read-JsonFile -Path $ep01GatePath
$hygiene = Read-JsonFile -Path $hygienePath
$queueSummary = Get-QueueSummary -Url $ComfyUrl

$ep01Counts = if ($ep01Decisions) { Count-Decisions -DecisionData $ep01Decisions } else { $null }
$segmentReports = @()
foreach ($segment in $segments) {
    $segmentReports += Get-SegmentReport @segment
}
$ep02Sc01Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC01" } | Select-Object -First 1
$ep02Sc02Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC02" } | Select-Object -First 1
$ep02Sc03Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC03" } | Select-Object -First 1
$ep02Sc04Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC04" } | Select-Object -First 1
$ep02Sc05Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC05" } | Select-Object -First 1
$ep02Sc06Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC06" } | Select-Object -First 1
$ep02Sc07Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC07" } | Select-Object -First 1
$ep02Sc08Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC08" } | Select-Object -First 1
$ep02Sc09Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC09" } | Select-Object -First 1
$ep02Sc10Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC10" } | Select-Object -First 1
$ep02Sc11Report = $segmentReports | Where-Object { $_.segment_id -eq "EP02 SC11" } | Select-Object -First 1

$nextActions = @()
if ($queueSummary.ok -and -not $queueSummary.idle) {
    Add-NextAction "ComfyUI is busy. Wait for idle before unattended live generation; do not clear unrelated queue items without approval."
}
if ($ep01Counts -and $ep01Counts.pending -gt 0) {
    Add-NextAction "EP01 still needs human video review in $ep01HumanReviewServerUrl or $ep01HumanReviewDashboardPath. The local server writes decisions and runs dry-run checks only."
}
foreach ($segment in @($segmentReports)) {
    if ($segment.decision_counts -and $segment.decision_counts.pending -gt 0) {
        Add-NextAction "$($segment.segment_id) storyboards still need review in $($segment.storyboard_review_server), $($segment.storyboard_dashboard), or $($segment.storyboard_review)."
        if ($segment.storyboard_to_i2v_script) {
            Add-NextAction "After $($segment.segment_id) storyboard decisions, run the dry-run driver: powershell -ExecutionPolicy Bypass -File $($segment.storyboard_to_i2v_script)"
        }
    }
    if (-not $segment.ready -and $segment.queue -and $segment.queue.queue_count -gt 0) {
        Add-NextAction "$($segment.segment_id) storyboard queue has items. Dry-run the queue before spending video quota."
    }
    if ($segment.postprocess_state -eq "awaiting_i2v_outputs") {
        Add-NextAction "After real $($segment.segment_id) I2V outputs exist, run: powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_segment_i2v_postprocess.ps1 -BuildReviewPackage"
    }
}
$latestReadySegment = @($segmentReports | Where-Object { $_.ready } | Select-Object -Last 1)
if ($latestReadySegment -and $latestReadySegment.next_seed) {
    Add-NextAction "$($latestReadySegment.segment_id) formal segment is built in test mode. Next: use $($latestReadySegment.next_seed) for the next segment, keep I2V silent/no-caption, and add Chinese dialogue in editing."
}
if (@($nextActions).Count -eq 0) {
    Add-NextAction "No immediate manual gate detected; run the relevant queue/cut gate before declaring the episode ready."
}

$report = [ordered]@{
    updated = (Get-Date).ToString("s")
    state_path = $StatePath
    current_stage = if ($state -and $state.current_stage) { [string]$state.current_stage } else { "" }
    comfy = $queueSummary
    secret_hygiene = if ($hygiene) {
        [ordered]@{
            ok = [bool]$hygiene.ok
            secret_ok = if ($null -ne $hygiene.secret_ok) { [bool]$hygiene.secret_ok } else { $null }
            queue_idle = if ($null -ne $hygiene.queue_idle) { [bool]$hygiene.queue_idle } else { $null }
            allow_busy_queue = if ($null -ne $hygiene.allow_busy_queue) { [bool]$hygiene.allow_busy_queue } else { $false }
        }
    } else { $null }
    ep01 = [ordered]@{
        decision_path = $ep01DecisionPath
        decision_counts = $ep01Counts
        precheck = if ($ep01Precheck) {
            [ordered]@{
                ok = [bool]$ep01Precheck.ok
                pending = [int]$ep01Precheck.counts.pending
                pass = [int]$ep01Precheck.counts.pass
                needs_regeneration = [int]$ep01Precheck.counts.needs_regeneration
                blocked = [int]$ep01Precheck.counts.blocked
            }
        } else { $null }
        cycle_state = if ($ep01Cycle -and $ep01Cycle.state) { [string]$ep01Cycle.state } else { "" }
        formal_gate = if ($ep01Gate) {
            [ordered]@{
                ok = [bool]$ep01Gate.ok
                failure_count = if ($ep01Gate.failure_count) { [int]$ep01Gate.failure_count } else { 0 }
            }
        } else { $null }
        review_dashboard = $ep01HumanReviewDashboardPath
        review_server = $ep01HumanReviewServerUrl
    }
    segments = $segmentReports
    ep02_sc01 = $ep02Sc01Report
    ep02_sc02 = $ep02Sc02Report
    ep02_sc03 = $ep02Sc03Report
    ep02_sc04 = $ep02Sc04Report
    ep02_sc05 = $ep02Sc05Report
    ep02_sc06 = $ep02Sc06Report
    ep02_sc07 = $ep02Sc07Report
    ep02_sc08 = $ep02Sc08Report
    ep02_sc09 = $ep02Sc09Report
    ep02_sc10 = $ep02Sc10Report
    ep02_sc11 = $ep02Sc11Report
    next_actions = $nextActions
    ok = $true
}

foreach ($segment in @($segmentReports)) {
    if ($segment.segment_id -match '^EP02 SC(\d+)$') {
        $report["ep02_sc$($Matches[1])"] = $segment
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# AI Short Drama Pipeline Status")
$lines.Add("")
$lines.Add("- Updated: $($report.updated)")
$lines.Add(('- Current stage: `{0}`' -f $report.current_stage))
$lines.Add(('- Comfy idle: `{0}` running={1} pending={2}' -f $report.comfy.idle, $report.comfy.running, $report.comfy.pending))
if ($report.secret_hygiene) {
    $lines.Add(('- Secret hygiene: ok=`{0}` secret_ok=`{1}` queue_idle=`{2}`' -f $report.secret_hygiene.ok, $report.secret_hygiene.secret_ok, $report.secret_hygiene.queue_idle))
}
$lines.Add("")
$lines.Add("## EP01")
if ($ep01Counts) {
    $lines.Add("- Human video decisions: pending=$($ep01Counts.pending), pass=$($ep01Counts.pass), needs_regeneration=$($ep01Counts.needs_regeneration), blocked=$($ep01Counts.blocked)")
}
if ($report.ep01.formal_gate) {
    $lines.Add(('- Formal gate: ok=`{0}`, failures={1}' -f $report.ep01.formal_gate.ok, $report.ep01.formal_gate.failure_count))
}
$lines.Add("- Review dashboard: $ep01HumanReviewDashboardPath")
$lines.Add("- Review server: $ep01HumanReviewServerUrl")
$lines.Add("")
foreach ($segment in @($report.segments)) {
    Add-SegmentMarkdown -Lines $lines -Segment $segment
}
$lines.Add("## Comfy Queue")
if ($report.comfy.items.Count -eq 0) {
    $lines.Add("- No active queue items.")
} else {
    foreach ($item in @($report.comfy.items)) {
        $classes = (@($item.class_types) -join ", ")
        $prefixes = (@($item.filename_prefixes) -join ", ")
        $lines.Add(('- client=`{0}` prompt=`{1}` classes=`{2}` prefixes=`{3}`' -f $item.client_id, $item.prompt_id, $classes, $prefixes))
    }
}
$lines.Add("")
$lines.Add("## Next Actions")
foreach ($action in @($nextActions)) {
    $lines.Add("- $action")
}
$lines.Add("")
$lines.Add("## Useful Commands")
$lines.Add('```powershell')
$lines.Add("powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\test_prompt_secret_hygiene.ps1 -AllowBusyQueue")
$lines.Add("powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_segment_i2v_postprocess.ps1 -BuildReviewPackage")
$lines.Add('```')

New-Item -ItemType Directory -Path (Split-Path $MarkdownPath) -Force | Out-Null
$lines | Set-Content -LiteralPath $MarkdownPath -Encoding UTF8
$report | ConvertTo-Json -Depth 30
