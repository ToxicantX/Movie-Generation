param(
    [string[]]$ReviewPaths = @(
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc03_consistency_review.json",
        "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc04_consistency_review.json"
    ),
    [string[]]$SegmentOutputPaths = @(
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC01_formal_cut_v001.mp4",
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC02_formal_cut_v001.mp4",
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC03_formal_cut_v001.mp4",
        "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC04_formal_cut_v001.mp4"
    ),
    [string]$OutputPath = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_formal_cut_v001.mp4",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_formal_cut_build_result.json",
    [string]$GatePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep01_formal_cut_gate_check.json",
    [string]$PostBuildGatePath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep01_formal_cut_postbuild_gate_check.json",
    [string]$AssemblyReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_formal_cut_review.json",
    [string]$AssemblyManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_formal_cut_result.json",
    [string]$SegmentManifestDir = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests",
    [string]$SegmentManifestPrefix = "",
    [string]$PythonPath = "python",
    [switch]$DryRun
)

function Convert-OutputJson {
    param($Output)

    $text = ($Output | Out-String).Trim()
    if (-not $text) {
        return $null
    }
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            ok = $false
            parse_error = $_.Exception.Message
            raw = $text
        }
    }
}

function ConvertTo-PowerShellSingleQuotedString {
    param([string]$Text)

    return "'" + ($Text -replace "'", "''") + "'"
}

function ConvertTo-PowerShellArrayLiteral {
    param([string[]]$Items)

    if (-not $Items -or @($Items).Count -eq 0) {
        return "@()"
    }
    $quoted = @($Items | ForEach-Object { ConvertTo-PowerShellSingleQuotedString -Text $_ })
    return "@(" + ($quoted -join ", ") + ")"
}

function Invoke-FormalGate {
    param(
        [string[]]$GateReviewPaths,
        [string[]]$GateSegmentCutPaths,
        [string]$ManifestPath,
        [switch]$SkipSegmentCuts
    )

    $reviewLiteral = ConvertTo-PowerShellArrayLiteral -Items $GateReviewPaths
    $segmentLiteral = ConvertTo-PowerShellArrayLiteral -Items $GateSegmentCutPaths
    $scriptPath = ConvertTo-PowerShellSingleQuotedString -Text "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\test_ep01_formal_cut_gate.ps1"
    $manifestLiteral = ConvertTo-PowerShellSingleQuotedString -Text $ManifestPath
    $pythonLiteral = ConvertTo-PowerShellSingleQuotedString -Text $PythonPath
    $probeLiteral = ConvertTo-PowerShellSingleQuotedString -Text "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\probe_video_cv2.py"
    $skipArg = if ($SkipSegmentCuts) { " -SkipSegmentCutChecks" } else { "" }
    $command = @(
        "`$reviewPaths = $reviewLiteral",
        "`$segmentCutPaths = $segmentLiteral",
        "& $scriptPath -ReviewPaths `$reviewPaths -SegmentCutPaths `$segmentCutPaths -ResultPath $manifestLiteral -PythonPath $pythonLiteral -VideoProbePath $probeLiteral$skipArg",
        'exit $LASTEXITCODE'
    ) -join "; "

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command $command
    return [ordered]@{
        exit_code = $LASTEXITCODE
        output = $output
        parsed = Convert-OutputJson -Output $output
    }
}

function Write-Result {
    param($Payload, [int]$ExitCode)

    New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
    $Payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    $Payload | ConvertTo-Json -Depth 30
    exit $ExitCode
}

if (@($ReviewPaths).Count -ne @($SegmentOutputPaths).Count) {
    $payload = [ordered]@{
        updated = (Get-Date).ToString("s")
        ok = $false
        reason = "ReviewPaths and SegmentOutputPaths must have the same count."
        review_paths = $ReviewPaths
        segment_output_paths = $SegmentOutputPaths
    }
    Write-Result -Payload $payload -ExitCode 1
}

$steps = @()
$gateInvocation = Invoke-FormalGate -GateReviewPaths $ReviewPaths -GateSegmentCutPaths @() -ManifestPath $GatePath -SkipSegmentCuts
$gateExit = $gateInvocation.exit_code
$gate = $gateInvocation.parsed
$steps += [ordered]@{
    name = "initial formal gate"
    status = if ($gateExit -eq 0) { "success" } else { "failed" }
    exit_code = $gateExit
    manifest = $GatePath
}

if ($gateExit -ne 0 -or -not $gate -or -not $gate.ok) {
    $payload = [ordered]@{
        updated = (Get-Date).ToString("s")
        ok = $false
        dry_run = [bool]$DryRun
        reason = "Formal gate failed; no formal EP01 cut was built."
        output_path = $OutputPath
        gate_path = $GatePath
        gate = $gate
        steps = $steps
    }
    Write-Result -Payload $payload -ExitCode 1
}

if ($DryRun) {
    $payload = [ordered]@{
        updated = (Get-Date).ToString("s")
        ok = $true
        dry_run = $true
        reason = "Formal gate passed. Dry run stopped before writing segment and episode cuts."
        output_path = $OutputPath
        segment_output_paths = $SegmentOutputPaths
        gate_path = $GatePath
        gate = $gate
        steps = $steps
    }
    Write-Result -Payload $payload -ExitCode 0
}

$segmentSteps = @()
for ($i = 0; $i -lt @($ReviewPaths).Count; $i++) {
    $reviewPath = $ReviewPaths[$i]
    $segmentOutputPath = $SegmentOutputPaths[$i]
    $segmentId = "SC{0:D2}" -f ($i + 1)
    try {
        $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($review.segment_id) {
            $segmentId = [string]$review.segment_id
        }
    } catch {
        $segmentId = "SC{0:D2}" -f ($i + 1)
    }
    $segmentManifestName = "$SegmentManifestPrefix$($segmentId.ToLowerInvariant())_formal_cut_result.json"
    $segmentManifest = Join-Path $SegmentManifestDir $segmentManifestName
    $cutOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\concat_episode_from_review_cv2.ps1" -ReviewPath $reviewPath -OutputPath $segmentOutputPath -ManifestPath $segmentManifest -PythonPath $PythonPath
    $cutExit = $LASTEXITCODE
    $cut = Convert-OutputJson -Output $cutOutput
    $segmentSteps += [ordered]@{
        segment_id = $segmentId
        review_path = $reviewPath
        output_path = $segmentOutputPath
        manifest = $segmentManifest
        status = if ($cutExit -eq 0) { "success" } else { "failed" }
        exit_code = $cutExit
        cut = $cut
    }
    if ($cutExit -ne 0 -or -not $cut -or -not $cut.ok) {
        $payload = [ordered]@{
            updated = (Get-Date).ToString("s")
            ok = $false
            dry_run = $false
            reason = "Formal segment cut build failed."
            output_path = $OutputPath
            gate_path = $GatePath
            steps = $steps
            segment_steps = $segmentSteps
        }
        Write-Result -Payload $payload -ExitCode 1
    }
}
$steps += [ordered]@{
    name = "build formal segment cuts"
    status = "success"
    segment_steps = $segmentSteps
}

$postGateInvocation = Invoke-FormalGate -GateReviewPaths $ReviewPaths -GateSegmentCutPaths $SegmentOutputPaths -ManifestPath $PostBuildGatePath
$postGateExit = $postGateInvocation.exit_code
$postGate = $postGateInvocation.parsed
$steps += [ordered]@{
    name = "postbuild formal gate"
    status = if ($postGateExit -eq 0) { "success" } else { "failed" }
    exit_code = $postGateExit
    manifest = $PostBuildGatePath
}
if ($postGateExit -ne 0 -or -not $postGate -or -not $postGate.ok) {
    $payload = [ordered]@{
        updated = (Get-Date).ToString("s")
        ok = $false
        dry_run = $false
        reason = "Postbuild formal gate failed; episode cut was not assembled."
        output_path = $OutputPath
        gate_path = $GatePath
        postbuild_gate_path = $PostBuildGatePath
        postbuild_gate = $postGate
        steps = $steps
    }
    Write-Result -Payload $payload -ExitCode 1
}

$assemblyShots = @()
for ($i = 0; $i -lt @($SegmentOutputPaths).Count; $i++) {
    $segmentName = "SC{0:D2}" -f ($i + 1)
    $assemblyShots += [ordered]@{
        shot_id = "SSJ_EP01_FORMAL_$segmentName"
        title = "EP01 formal segment $segmentName"
        video_path = $SegmentOutputPaths[$i]
        preferred_video_mode = "approved_segment_formal_cut"
        status = "pass"
        checks = [ordered]@{
            character_identity = "pass"
            character_props = "pass"
            location_identity = "pass"
            storyboard_match = "pass"
            motion_continuity = "pass"
            safety_constraints = "pass"
            clean_output = "pass"
            technical_output = "pass"
        }
        notes = "Built from an approved segment review and rechecked by the EP01 formal gate."
    }
}

$assemblyReview = [ordered]@{
    "project" = "AI Short Drama Factory";
    "source" = "Sou Shen Ji volume 01 chapter 01";
    "episode_id" = "SSJ_EP01";
    "segment_id" = "SSJ_EP01_FORMAL_CUT";
    "title" = "Episode 01 formal cut from approved SC01-SC04 segment cuts";
    "updated" = (Get-Date).ToString("yyyy-MM-dd");
    "global_decision" = "approved_for_episode_cut";
    "global_reason" = "All segment reviews passed the formal gate and segment cuts were rebuilt for formal assembly.";
    "source_reviews" = $ReviewPaths;
    "source_segment_cuts" = $SegmentOutputPaths;
    "shots" = $assemblyShots;
}
New-Item -ItemType Directory -Path (Split-Path $AssemblyReviewPath) -Force | Out-Null
$assemblyReview | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $AssemblyReviewPath -Encoding UTF8
$steps += [ordered]@{
    name = "write formal assembly review"
    status = "success"
    path = $AssemblyReviewPath
}

$episodeOutput = & powershell -ExecutionPolicy Bypass -File "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\concat_episode_from_review_cv2.ps1" -ReviewPath $AssemblyReviewPath -OutputPath $OutputPath -ManifestPath $AssemblyManifestPath -PythonPath $PythonPath
$episodeExit = $LASTEXITCODE
$episodeCut = Convert-OutputJson -Output $episodeOutput
$steps += [ordered]@{
    name = "build EP01 formal cut"
    status = if ($episodeExit -eq 0) { "success" } else { "failed" }
    exit_code = $episodeExit
    output_path = $OutputPath
    manifest = $AssemblyManifestPath
}

$ok = ($episodeExit -eq 0 -and $episodeCut -and $episodeCut.ok)
$payload = [ordered]@{
    updated = (Get-Date).ToString("s")
    ok = [bool]$ok
    dry_run = $false
    output_path = $OutputPath
    assembly_review_path = $AssemblyReviewPath
    assembly_manifest_path = $AssemblyManifestPath
    gate_path = $GatePath
    postbuild_gate_path = $PostBuildGatePath
    episode_cut = $episodeCut
    steps = $steps
}

Write-Result -Payload $payload -ExitCode $(if ($ok) { 0 } else { 1 })
