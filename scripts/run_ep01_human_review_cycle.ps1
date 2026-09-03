param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01.json",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep01_human_review_cycle_result.json",
    [switch]$SkipMarkdownImport,
    [switch]$SkipApply,
    [switch]$RunRegeneration,
    [switch]$BuildFormalCut
)

$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root "scripts"
$manifests = Join-Path $root "manifests"

function Invoke-PowerShellStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$AllowNonZero
    )

    $output = & powershell -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $step = [ordered]@{
        name = $Name
        script = $ScriptPath
        arguments = $Arguments
        exit_code = $exitCode
        output_tail = @($output | Select-Object -Last 12)
        ok = ($exitCode -eq 0 -or [bool]$AllowNonZero)
    }
    if (-not $step.ok) {
        $script:steps += $step
        throw "Step failed: $Name"
    }
    $script:steps += $step
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

$steps = @()
$importPath = Join-Path $scripts "import_ep01_human_review_markdown_decisions.ps1"
$precheckPath = Join-Path $scripts "test_ep01_human_review_decisions.ps1"
$applyPath = Join-Path $scripts "apply_ep01_human_review_decisions.ps1"
$queuePath = Join-Path $scripts "build_human_review_regeneration_queue.ps1"
$runnerPath = Join-Path $scripts "run_regeneration_queue.ps1"
$formalGatePath = Join-Path $scripts "test_ep01_formal_cut_gate.ps1"
$formalCutPath = Join-Path $scripts "build_ep01_formal_cut.ps1"
$dashboardPath = Join-Path $scripts "build_ep01_human_review_dashboard.ps1"

try {
    if (-not $SkipMarkdownImport) {
        Invoke-PowerShellStep -Name "import_markdown_decisions" -ScriptPath $importPath -Arguments @("-DecisionPath", $DecisionPath)
    }

    Invoke-PowerShellStep -Name "precheck_decisions" -ScriptPath $precheckPath -Arguments @("-DecisionPath", $DecisionPath)
    $precheck = Read-JsonFile -Path (Join-Path $manifests "human_review_decisions_ep01_precheck.json")
    $hasHumanDecision = $false
    if ($precheck -and ($precheck.counts.pass + $precheck.counts.needs_regeneration + $precheck.counts.blocked) -gt 0) {
        $hasHumanDecision = $true
    }

    if ($hasHumanDecision -and -not $SkipApply) {
        Invoke-PowerShellStep -Name "apply_decisions" -ScriptPath $applyPath -Arguments @("-DecisionPath", $DecisionPath)
    }

    Invoke-PowerShellStep -Name "build_regeneration_queue" -ScriptPath $queuePath -Arguments @("-DecisionPath", $DecisionPath, "-IncludeTechnicalFallback")
    $queue = Read-JsonFile -Path (Join-Path $manifests "regeneration_queue_ep01.json")

    if ($queue -and $queue.queue_count -gt 0) {
        if ($RunRegeneration) {
            Invoke-PowerShellStep -Name "run_regeneration_queue_live" -ScriptPath $runnerPath
        } else {
            Invoke-PowerShellStep -Name "run_regeneration_queue_dry_run" -ScriptPath $runnerPath -Arguments @("-DryRun")
        }
    }

    Invoke-PowerShellStep -Name "formal_cut_gate" -ScriptPath $formalGatePath -Arguments @("-SkipSegmentCutChecks") -AllowNonZero
    $gate = Read-JsonFile -Path (Join-Path $manifests "ep01_formal_cut_gate_check.json")

    if ($gate -and $gate.ok -and $BuildFormalCut) {
        Invoke-PowerShellStep -Name "build_formal_cut" -ScriptPath $formalCutPath
    }

    Invoke-PowerShellStep -Name "build_review_dashboard" -ScriptPath $dashboardPath -Arguments @("-DecisionPath", $DecisionPath)

    $finalQueue = Read-JsonFile -Path (Join-Path $manifests "regeneration_queue_ep01.json")
    $finalGate = Read-JsonFile -Path (Join-Path $manifests "ep01_formal_cut_gate_check.json")
    $finalPrecheck = Read-JsonFile -Path (Join-Path $manifests "human_review_decisions_ep01_precheck.json")

    $state = "awaiting_human_review"
    if ($finalQueue -and $finalQueue.queue_count -gt 0) {
        $state = if ($RunRegeneration) { "regeneration_attempted" } else { "regeneration_queue_ready" }
    } elseif ($finalGate -and $finalGate.ok) {
        $state = if ($BuildFormalCut) { "formal_cut_build_attempted" } else { "formal_cut_ready_to_build" }
    } elseif ($finalPrecheck -and ($finalPrecheck.counts.pass + $finalPrecheck.counts.needs_regeneration + $finalPrecheck.counts.blocked) -eq 0) {
        $state = "awaiting_human_review"
    } else {
        $state = "human_decisions_applied_pending_gate"
    }

    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        decision_path = $DecisionPath
        state = $state
        skip_markdown_import = [bool]$SkipMarkdownImport
        skip_apply = [bool]$SkipApply
        run_regeneration = [bool]$RunRegeneration
        build_formal_cut = [bool]$BuildFormalCut
        steps = $steps
        precheck = if ($finalPrecheck) {
            [ordered]@{
                ok = [bool]$finalPrecheck.ok
                pending = [int]$finalPrecheck.counts.pending
                pass = [int]$finalPrecheck.counts.pass
                needs_regeneration = [int]$finalPrecheck.counts.needs_regeneration
                blocked = [int]$finalPrecheck.counts.blocked
                invalid_count = [int]$finalPrecheck.invalid_count
                stale_count = [int]$finalPrecheck.stale_count
                unsafe_pass_count = [int]$finalPrecheck.unsafe_pass_count
            }
        } else { $null }
        regeneration_queue = if ($finalQueue) {
            [ordered]@{
                ok = [bool]$finalQueue.ok
                queue_count = [int]$finalQueue.queue_count
                technical_fallback = [int]$finalQueue.summary.technical_fallback
                missing_workflow = [int]$finalQueue.summary.missing_workflow
            }
        } else { $null }
        formal_gate = if ($finalGate) {
            [ordered]@{
                ok = [bool]$finalGate.ok
                failure_count = [int]$finalGate.failure_count
            }
        } else { $null }
        ok = $true
    }
} catch {
    $result = [ordered]@{
        updated = (Get-Date).ToString("s")
        decision_path = $DecisionPath
        state = "cycle_failed"
        error = $_.Exception.Message
        steps = $steps
        ok = $false
    }
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 30

if (-not $result.ok) {
    exit 1
}
