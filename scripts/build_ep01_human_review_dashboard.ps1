param(
    [string]$DecisionPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\human_review_decisions_ep01.json",
    [string]$OutputPath = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_HUMAN_REVIEW_DASHBOARD.html",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ep01_human_review_dashboard_result.json",
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

function To-AssetUri {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if (-not [string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
        return "$($ApiBaseUrl.TrimEnd('/'))/api/asset?path=$([System.Uri]::EscapeDataString($Path))"
    }
    return To-FileUri -Path $Path
}

function Get-Package-Asset {
    param($Decision, [string]$Suffix)

    $package = if ($Decision.review_package_markdown) { [string]$Decision.review_package_markdown } else { "" }
    if (-not $package) {
        return ""
    }
    $dir = Split-Path $package
    return Join-Path (Join-Path $dir ([string]$Decision.shot_id)) "$($Decision.shot_id)_$Suffix"
}

$decisionData = Get-Content -LiteralPath $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$decisions = @($decisionData.decisions)
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
    $contactSheet = Get-Package-Asset -Decision $decision -Suffix "contact_sheet.jpg"
    $storyboardCompare = Get-Package-Asset -Decision $decision -Suffix "storyboard_compare.jpg"
    $videoUri = To-AssetUri -Path ([string]$decision.video_path)
    $contactUri = To-AssetUri -Path $contactSheet
    $compareUri = To-AssetUri -Path $storyboardCompare
    $packageUri = To-FileUri -Path ([string]$decision.review_package_markdown)
    $shotIdHtml = Html $decision.shot_id
    $decisionClass = ([string]$decision.decision) -replace "[^a-z_]+", "_"

    $mediaHtml = ""
    if ($videoUri) {
        $mediaHtml += "<video controls preload=`"metadata`" src=`"$videoUri`"></video>"
    }
    if ((Test-Path -LiteralPath $contactSheet) -and $contactUri) {
        $mediaHtml += "<img src=`"$contactUri`" alt=`"contact sheet`">"
    }
    if ((Test-Path -LiteralPath $storyboardCompare) -and $compareUri) {
        $mediaHtml += "<img src=`"$compareUri`" alt=`"storyboard compare`">"
    }
    if (-not $mediaHtml) {
        $mediaHtml = "<div class=`"missing`">Media missing</div>"
    }

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
  <div class="meta">
    <span>Status: $(Html $decision.current_status)</span>
    <span>Scope: $(Html $decision.regeneration_scope)</span>
  </div>
  $buttonHtml
  <div class="media">$mediaHtml</div>
  <p class="path">Video: $(Html $decision.video_path)</p>
  <p class="path">Review: <a href="$packageUri">$(Html $decision.review_package_markdown)</a></p>
</article>
"@)
}

$html = @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SSJ EP01 Human Review Dashboard</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #172026;
      --muted: #5d6873;
      --line: #d8dee5;
      --panel: #ffffff;
      --bg: #f5f7f8;
      --accent: #0f766e;
      --warn: #b45309;
      --bad: #b42318;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Arial, "Microsoft YaHei", sans-serif;
      background: var(--bg);
      color: var(--ink);
    }
    main {
      width: min(1520px, calc(100% - 32px));
      margin: 0 auto;
      padding: 24px 0 48px;
    }
    .topbar {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 24px;
      padding: 0 0 18px;
      border-bottom: 1px solid var(--line);
    }
    h1 { margin: 0 0 8px; font-size: 28px; letter-spacing: 0; }
    p { margin: 0; }
    code { font-size: 12px; }
    .summary {
      display: grid;
      grid-template-columns: repeat(4, minmax(96px, 1fr));
      gap: 8px;
      min-width: 420px;
    }
    .summary div {
      background: var(--panel);
      border: 1px solid var(--line);
      padding: 10px 12px;
      border-radius: 8px;
    }
    .summary strong { display: block; font-size: 22px; }
    .summary span { color: var(--muted); font-size: 12px; }
    .commands {
      display: grid;
      gap: 6px;
      margin: 18px 0;
      color: var(--muted);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(420px, 1fr));
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
      gap: 12px;
      align-items: flex-start;
      margin-bottom: 10px;
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
    .decision-pass .pill { color: var(--accent); border-color: #99d7ce; background: #ecfdf5; }
    .decision-needs_regeneration .pill { color: var(--warn); border-color: #f6c177; background: #fff7ed; }
    .decision-blocked .pill { color: var(--bad); border-color: #f2aaa4; background: #fef3f2; }
    .meta {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      color: var(--muted);
      font-size: 12px;
      margin-bottom: 12px;
    }
    .media {
      display: grid;
      grid-template-columns: 1fr;
      gap: 10px;
    }
    video, img {
      display: block;
      width: 100%;
      max-height: 360px;
      object-fit: contain;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #0b0f12;
    }
    .missing {
      display: grid;
      min-height: 220px;
      place-items: center;
      color: #ffffff;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #0b0f12;
    }
    .actions {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 8px;
      margin: 0 0 12px;
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
    button:disabled { cursor: wait; opacity: 0.7; }
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
    @media (max-width: 840px) {
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
        <h1>SSJ EP01 Human Review Dashboard</h1>
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
    <section class="commands">
      <code>powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\import_ep01_human_review_markdown_decisions.ps1</code>
      <code>powershell -ExecutionPolicy Bypass -File E:\workspace\ComfyUIProjects\Movie-Generation\scripts\run_ep01_human_review_cycle.ps1</code>
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
