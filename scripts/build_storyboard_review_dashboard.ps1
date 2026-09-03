param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_decisions_ep02_sc01.json",
    [string]$OutputPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\storyboard_review_dashboard_ep02_sc01_result.json",
    [string]$ApiBaseUrl = ""
)

if (-not (Test-Path -LiteralPath $DecisionPath)) {
    throw "Decision file not found: $DecisionPath"
}

function Html {
    param($Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function To-FileUri {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    try {
        return ([System.Uri]([System.IO.Path]::GetFullPath($Path))).AbsoluteUri
    } catch {
        return ""
    }
}

function To-RelativeUri {
    param(
        [string]$FromDirectory,
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($FromDirectory) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
        return ""
    }
    try {
        $fromFull = [System.IO.Path]::GetFullPath($FromDirectory).TrimEnd("\") + "\"
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
        $fromUri = [System.Uri]$fromFull
        $targetUri = [System.Uri]$targetFull
        return $fromUri.MakeRelativeUri($targetUri).ToString()
    } catch {
        return To-FileUri -Path $TargetPath
    }
}

function Get-PackagedStoryboard {
    param($Decision)

    $package = if ($Decision.review_package_markdown) { [string]$Decision.review_package_markdown } else { "" }
    if (-not $package) {
        return ""
    }
    $dir = Split-Path $package
    $candidate = Join-Path (Join-Path $dir ([string]$Decision.shot_id)) "$($Decision.shot_id)_storyboard.png"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return ""
}

function Format-SetDecisionCommand {
    param([string]$ShotId, [string]$Decision)

    return "powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\set_storyboard_review_decision.ps1 -ShotId '$ShotId' -Decision $Decision"
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$decisions = @($decisionData.decisions)
$outputDir = Split-Path $OutputPath
$scriptBlock = @'
  <script>
    const apiBaseUrl = "__API_BASE_URL__";
    const statusEl = document.getElementById("status");
    async function setDecision(button) {
      if (!apiBaseUrl) return;
      const shotId = button.dataset.shot;
      const decision = button.dataset.decision;
      button.disabled = true;
      statusEl.textContent = "Saving " + shotId + " -> " + decision + "...";
      try {
        const response = await fetch(apiBaseUrl + "/api/decision", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({shot_id: shotId, decision: decision})
        });
        const payload = await response.json();
        if (!response.ok || !payload.ok) {
          throw new Error(payload.error || ("HTTP " + response.status));
        }
        statusEl.textContent = "Saved " + shotId + " -> " + decision + ". Refreshing...";
        window.location.reload();
      } catch (error) {
        statusEl.textContent = "Save failed: " + error.message;
        button.disabled = false;
      }
    }
    document.querySelectorAll("button[data-shot]").forEach((button) => {
      button.addEventListener("click", () => setDecision(button));
    });
  </script>
'@
$scriptBlock = $scriptBlock.Replace("__API_BASE_URL__", (Html $ApiBaseUrl))
$summary = [ordered]@{
    pending = @($decisions | Where-Object { $_.decision -eq "pending" }).Count
    pass = @($decisions | Where-Object { $_.decision -eq "pass" }).Count
    needs_regeneration = @($decisions | Where-Object { $_.decision -eq "needs_regeneration" }).Count
    blocked = @($decisions | Where-Object { $_.decision -eq "blocked" }).Count
}

$cards = New-Object System.Collections.Generic.List[string]
foreach ($decision in $decisions) {
    $storyboardPath = Get-PackagedStoryboard -Decision $decision
    if (-not $storyboardPath) {
        $storyboardPath = if ($decision.storyboard_path) { [string]$decision.storyboard_path } else { "" }
    }
    $storyboardUri = To-RelativeUri -FromDirectory $outputDir -TargetPath $storyboardPath
    $packageUri = To-RelativeUri -FromDirectory $outputDir -TargetPath ([string]$decision.review_package_markdown)
    $decisionClass = ([string]$decision.decision) -replace "[^a-z_]+", "_"
    $passCommand = Format-SetDecisionCommand -ShotId ([string]$decision.shot_id) -Decision "pass"
    $regenCommand = Format-SetDecisionCommand -ShotId ([string]$decision.shot_id) -Decision "needs_regeneration"
    $blockedCommand = Format-SetDecisionCommand -ShotId ([string]$decision.shot_id) -Decision "blocked"
    $pendingCommand = Format-SetDecisionCommand -ShotId ([string]$decision.shot_id) -Decision "pending"
    $shotIdHtml = Html $decision.shot_id

    $buttonHtml = ""
    if ($ApiBaseUrl) {
        $buttonHtml = @"
  <div class="actions">
    <button type="button" data-shot="$shotIdHtml" data-decision="pass">Pass</button>
    <button type="button" data-shot="$shotIdHtml" data-decision="needs_regeneration">Regenerate</button>
    <button type="button" data-shot="$shotIdHtml" data-decision="blocked">Block</button>
    <button type="button" data-shot="$shotIdHtml" data-decision="pending">Pending</button>
  </div>
"@
    }

    $imageHtml = if ($storyboardUri) {
        "<img src=`"$storyboardUri`" alt=`"storyboard`">"
    } else {
        "<div class=`"missing`">Storyboard image missing</div>"
    }

    $cards.Add(@"
<article class="card decision-$decisionClass">
  <header>
    <div>
      <p class="review">$(Html $decision.review_id)</p>
      <h2>$(Html $decision.shot_id)</h2>
      <p class="title">$(Html $decision.title)</p>
    </div>
    <span class="pill">$(Html $decision.decision)</span>
  </header>
  <div class="media">$imageHtml</div>
  <dl>
    <div><dt>Status</dt><dd>$(Html $decision.current_status)</dd></div>
    <div><dt>Workflow</dt><dd>$(Html $decision.video_workflow)</dd></div>
  </dl>
  $buttonHtml
  <div class="commands">
    <code>$(Html $passCommand)</code>
    <code>$(Html $regenCommand)</code>
    <code>$(Html $blockedCommand)</code>
    <code>$(Html $pendingCommand)</code>
  </div>
  <p class="path">Storyboard: $(Html $storyboardPath)</p>
  <p class="path">Markdown: <a href="$packageUri">$(Html $decision.review_package_markdown)</a></p>
</article>
"@)
}

$html = @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SSJ EP02 SC01 Storyboard Review</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #141b22;
      --muted: #60707f;
      --line: #d9e1e8;
      --panel: #ffffff;
      --bg: #f4f7f8;
      --accent: #0f766e;
      --warn: #a65f00;
      --bad: #b42318;
      --code: #edf2f7;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Arial, "Microsoft YaHei", sans-serif;
      background: var(--bg);
      color: var(--ink);
    }
    main {
      width: min(1500px, calc(100% - 32px));
      margin: 0 auto;
      padding: 24px 0 48px;
    }
    .topbar {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 24px;
      border-bottom: 1px solid var(--line);
      padding-bottom: 18px;
    }
    h1 { margin: 0 0 8px; font-size: 28px; letter-spacing: 0; }
    p { margin: 0; }
    .summary {
      display: grid;
      grid-template-columns: repeat(4, minmax(104px, 1fr));
      gap: 8px;
      min-width: 460px;
    }
    .summary div {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px 12px;
    }
    .summary strong { display: block; font-size: 24px; }
    .summary span { color: var(--muted); font-size: 12px; }
    .runbook {
      display: grid;
      gap: 8px;
      margin: 18px 0;
      color: var(--muted);
    }
    .runbook code, .commands code {
      display: block;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      background: var(--code);
      color: #1f2937;
      border: 1px solid #d7e0ea;
      border-radius: 6px;
      padding: 8px;
      font-size: 12px;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(420px, 1fr));
      gap: 16px;
    }
    .card {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
      min-width: 0;
    }
    .card header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 12px;
      margin-bottom: 12px;
    }
    .review { color: var(--muted); font-size: 12px; margin-bottom: 4px; }
    h2 { margin: 0; font-size: 18px; letter-spacing: 0; }
    .title { color: var(--muted); font-size: 13px; margin-top: 4px; }
    .pill {
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 4px 8px;
      font-size: 12px;
      white-space: nowrap;
      background: #f8fafc;
    }
    .decision-pass .pill { color: var(--accent); border-color: #9bd7ce; background: #ecfdf5; }
    .decision-needs_regeneration .pill { color: var(--warn); border-color: #f4c27a; background: #fff7ed; }
    .decision-blocked .pill { color: var(--bad); border-color: #f3aaa4; background: #fef3f2; }
    img, .missing {
      display: block;
      width: 100%;
      aspect-ratio: 3 / 2;
      object-fit: contain;
      border-radius: 6px;
      border: 1px solid var(--line);
      background: #0c1116;
    }
    .missing {
      color: #ffffff;
      display: grid;
      place-items: center;
    }
    dl {
      display: grid;
      gap: 6px;
      margin: 12px 0;
      color: var(--muted);
      font-size: 12px;
    }
    dl div { min-width: 0; }
    dt { float: left; width: 72px; color: #334155; }
    dd { margin-left: 78px; overflow-wrap: anywhere; }
    .commands {
      display: grid;
      gap: 6px;
    }
    .actions {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 8px;
      margin: 12px 0;
    }
    button {
      min-height: 36px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #ffffff;
      color: var(--ink);
      font: inherit;
      font-size: 13px;
      cursor: pointer;
    }
    button:hover { border-color: #8aa2b6; background: #f8fafc; }
    button[data-decision="pass"] { border-color: #99d7ce; color: var(--accent); }
    button[data-decision="needs_regeneration"] { border-color: #f4c27a; color: var(--warn); }
    button[data-decision="blocked"] { border-color: #f3aaa4; color: var(--bad); }
    #status {
      margin-top: 10px;
      color: var(--muted);
      min-height: 20px;
      font-size: 13px;
    }
    .path {
      color: var(--muted);
      font-size: 11px;
      margin-top: 8px;
      overflow-wrap: anywhere;
    }
    a { color: #0b66c3; }
    @media (max-width: 860px) {
      .topbar { display: block; }
      .summary { min-width: 0; margin-top: 16px; grid-template-columns: repeat(2, 1fr); }
      .grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <main>
    <section class="topbar">
      <div>
        <h1>SSJ EP02 SC01 Storyboard Review</h1>
        <p>Updated: $(Html ((Get-Date).ToString("s")))</p>
        <p class="path">Decision file: $(Html $DecisionPath)</p>
        <p id="status"></p>
      </div>
      <div class="summary">
        <div><strong>$($summary.pending)</strong><span>pending</span></div>
        <div><strong>$($summary.pass)</strong><span>pass</span></div>
        <div><strong>$($summary.needs_regeneration)</strong><span>needs regeneration</span></div>
        <div><strong>$($summary.blocked)</strong><span>blocked</span></div>
      </div>
    </section>
    <section class="runbook">
      <code>powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_storyboard_review_cycle.ps1 -SkipMarkdownImport</code>
      <code>powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_storyboard_i2v_queue.ps1 -DryRun</code>
    </section>
    <section class="grid">
      $($cards -join "`n")
    </section>
  </main>
  $scriptBlock
</body>
</html>
"@

New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
$html | Set-Content -LiteralPath $OutputPath -Encoding UTF8

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    decision_path = $DecisionPath
    output_path = $OutputPath
    api_base_url = $ApiBaseUrl
    decision_count = @($decisions).Count
    summary = $summary
    ok = $true
}

New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 10
