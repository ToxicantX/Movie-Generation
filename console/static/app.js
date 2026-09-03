const state = {
  status: null,
  reviews: null,
  jobs: [],
  projects: null,
  localPipeline: null,
  textSettings: null,
  imageSettings: null,
  videoSettings: null,
  audioSettings: null,
  stylePrompts: null,
  selectedStylePrompt: "真人影视",
  selectedScene: null,
  selectedReview: null,
  selectedJob: null,
  selectedShot: null,
  selectedAsset: null,
  selectedProductionUnit: "",
  mediaTab: "image",
  mobileWorkspaceTab: "image-prompt",
  assetFilter: "all",
  pendingProjectSlug: "",
  module: "production",
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const frameTimers = new Map();
let configDrawerTrigger = null;

function setConfigDrawer(open, trigger = null) {
  const drawer = $("#productionConfigDrawer");
  const backdrop = $(".config-drawer-backdrop");
  if (!drawer || !backdrop) return;

  if (open) configDrawerTrigger = trigger || document.activeElement;
  drawer.classList.toggle("open", open);
  backdrop.classList.toggle("open", open);
  drawer.setAttribute("aria-hidden", String(!open));
  $$('[data-config-drawer-open]').forEach((button) => button.setAttribute("aria-expanded", String(open)));
  document.body.classList.toggle("config-drawer-open", open);

  if (open) {
    requestAnimationFrame(() => drawer.focus());
  } else if (configDrawerTrigger instanceof HTMLElement) {
    configDrawerTrigger.focus();
    configDrawerTrigger = null;
  }
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!bytes) return "-";
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${Math.round(bytes / 1024)} KB`;
}

function labelForStage(value) {
  const labels = {
    technical_preview_cut_built_pending_human_video_review: "技术预览已生成",
    approved_for_episode_cut: "审核通过",
    pass: "通过",
    pending: "待审核",
    completed: "完成",
    running: "执行中",
    queued: "等待执行",
    failed: "失败",
    draft: "草稿",
    needs_review: "待审核",
    waiting: "等待生成",
    passed: "已生成",
    formal_cut_build_attempted: "正式剪辑已构建",
  };
  return labels[value] || value || "未知";
}

const pipelineStages = [
  ["concept", "方案"],
  ["content_plan", "内容规划"],
  ["screenplay", "剧本/脚本"],
  ["screenplay_import", "剧本/脚本导入"],
  ["director_storyboard", "导演分镜设计"],
  ["episode_outline", "分集大纲"],
  ["scene_table", "场景表"],
  ["shot_table", "分镜表"],
  ["audio_design", "台词与音频设计"],
  ["asset_catalog", "资产清单"],
  ["image_prompts", "图片提示词"],
  ["image_generation", "图片资产生成"],
  ["video_prompts", "视频提示词"],
  ["model_match", "选择/匹配模型"],
  ["clip_generation", "视频片段生成"],
  ["tts_generation", "Edge TTS 配音生成"],
  ["audio_mix", "音画合成"],
];

function badge(value, kind = "") {
  return `<span class="status-badge ${kind}">${escapeHtml(value)}</span>`;
}

function toast(message, isError = false) {
  const item = document.createElement("div");
  item.className = `toast${isError ? " error" : ""}`;
  item.textContent = message;
  $("#toastStack").append(item);
  setTimeout(() => item.remove(), 3800);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || `请求失败：${response.status}`);
  return payload;
}

function switchModule(module) {
  setConfigDrawer(false);
  state.module = module;
  $$("[data-module]").forEach((button) => button.classList.toggle("active", button.dataset.module === module));
  $$("[data-module-view]").forEach((view) => view.classList.toggle("active", view.dataset.moduleView === module));
  if (module === "reviews" && !state.reviews) loadReviews();
  if (module === "tasks") loadJobs();
  if (module === "projects" && !state.projects) loadProjects();
  if (module === "production") {
    if (!state.localPipeline) loadLocalPipeline(state.pendingProjectSlug);
    state.pendingProjectSlug = "";
    if (!state.textSettings) loadTextSettings();
    if (!state.imageSettings) loadImageSettings();
    if (!state.videoSettings) loadVideoSettings();
    if (!state.audioSettings) loadAudioSettings();
    if (!state.stylePrompts) loadStylePrompts();
  }
}

function pipelineInputs() {
  return {
    novel_path: $("#pipelineNovelPath").value.trim(),
    project_slug: $("#pipelineProjectSlug").value.trim(),
    project_title: $("#pipelineProjectTitle").value.trim(),
    max_shots: Math.max(0, Number($("#pipelineMaxShots").value || 0)),
    source_type: $("#pipelineSourceType").value,
    content_type: $("#pipelineContentType").value,
    planning_mode: $("#pipelinePlanningMode").value,
    target_episode_count: Number($("#pipelineTargetEpisodeCount").value || 0),
    target_unit_duration_seconds: Number($("#pipelineTargetDuration").value || 600),
    aspect_ratio: $("#pipelineAspectRatio").value,
    visual_style: $("#pipelinePrimaryStyle").value,
    style_status: $("#pipelineStyleBadge")?.dataset.status || "pending",
  };
}

function syncPlanningControls(scope) {
  const prefix = scope === "project" ? "projectCreate" : "pipeline";
  const contentType = $(`#${prefix}ContentType`);
  const planningMode = $(`#${prefix}PlanningMode`);
  const count = $(`#${prefix}TargetEpisodeCount`);
  const countField = $(`[data-${scope}-target-count]`);
  if (!contentType || !planningMode || !count || !countField) return;
  const isSeries = contentType.value === "series";
  planningMode.disabled = !isSeries;
  const fixed = isSeries && planningMode.value === "fixed";
  count.disabled = !fixed;
  countField.hidden = !fixed;
}

function fillPipelineProject(project, maxShots = null) {
  if (!project) return;
  $("#pipelineProjectSlug").value = project.slug || "";
  $("#pipelineProjectTitle").value = project.title || "";
  $("#pipelineNovelPath").value = project.novel_path || "";
  $("#pipelineSourceType").value = project.source_type || "novel";
  $("#pipelineContentType").value = project.content_type || "single";
  $("#pipelinePlanningMode").value = project.planning_mode || "auto";
  $("#pipelineTargetEpisodeCount").value = project.target_episode_count || 2;
  $("#pipelineTargetDuration").value = project.target_unit_duration_seconds || 600;
  $("#pipelineAspectRatio").value = project.aspect_ratio || "16:9";
  const styleSelect = $("#pipelinePrimaryStyle");
  const style = project.visual_style || "";
  styleSelect.querySelector('[data-legacy-style]')?.remove();
  if (style && ![...styleSelect.options].some((option) => option.value === style)) {
    styleSelect.add(new Option(`历史设置：${style}`, style));
    styleSelect.lastElementChild.dataset.legacyStyle = "true";
  }
  styleSelect.value = style;
  $("#pipelineStyleBadge").dataset.status = project.style_status || (project.visual_style ? "confirmed" : "pending");
  $("#pipelineStyleBadge").textContent = $("#pipelineStyleBadge").dataset.status === "confirmed" ? "已设定" : "待设定";
  $("#pipelineStyleBadge").className = `status-badge ${$("#pipelineStyleBadge").dataset.status === "confirmed" ? "ok" : "warn"}`;
  if (maxShots) $("#pipelineMaxShots").value = maxShots;
  syncPlanningControls("pipeline");
}

function pipelineStatusKind(status) {
  const value = String(status || "").toLowerCase();
  if (["complete", "completed", "ready", "pass", "approved", "done"].some((item) => value.includes(item))) return "ok";
  if (["failed", "blocked", "error"].some((item) => value.includes(item))) return "danger";
  return "warn";
}

function pipelineMedia(value) {
  if (!value) return null;
  if (typeof value === "object") {
    if (value.exists === false) return null;
    if (value.url) return { url: value.url, label: value.name || value.path || "媒体" };
    value = value.path || value.name || "";
  }
  const text = String(value || "");
  if (!text) return null;
  return { url: /^(https?:|\/)/i.test(text) ? text : `/media?path=${encodeURIComponent(text)}`, label: text.split(/[\\/]/).pop() };
}

function normalizedPipelineStages(manifest) {
  const incoming = Array.isArray(manifest?.stages) ? manifest.stages : [];
  return pipelineStages.map(([key, label], index) => {
    const item = incoming.find((stage) => stage?.key === key) || incoming[index] || {};
    return { key, label, ...item, label: item.label || label };
  });
}

function renderPipelineStages(manifest) {
  const stages = normalizedPipelineStages(manifest);
  const isAvailable = (stage) => stage.storage === "postgresql" || stage.item_count > 0;
  const available = stages.filter(isAvailable).length;
  $("#pipelineStageCount").textContent = `${available} / ${stages.length}`;
  $("#pipelineStages").innerHTML = stages.map((stage, index) => `
    <button type="button" class="stage-item ${state.localPipeline?.selectedStage === stage.key ? "active" : ""}" data-pipeline-stage="${escapeHtml(stage.key)}">
      <span class="stage-index">${isAvailable(stage) ? "✓" : String(index + 1).padStart(2, "0")}</span>
      <strong>${escapeHtml(stage.label)}</strong>
    </button>`).join("");
  requestAnimationFrame(() => {
    document.querySelector(".pipeline-band .stage-item.active")?.scrollIntoView({ block: "nearest", inline: "nearest" });
  });
}

function renderPipelineModels(manifest) {
  const models = manifest?.models;
  const manifestEntries = Array.isArray(models)
    ? models.map((item, index) => [item?.name || item?.key || `模型 ${index + 1}`, item?.model || item?.status || "-"])
    : Object.entries(models || {});
  const videoSettings = state.videoSettings || { mode: "local" };
  const manifestVideoModel = manifestEntries.find(([name]) => String(name).toLowerCase() === "video")?.[1] || "MiniMax H3 local";
  const videoModel = videoSettings.mode === "api" ? `MiniMax API / ${videoSettings.model || "未配置"}` : manifestVideoModel;
  const videoSpec = videoSettings.mode === "api"
    ? `${videoSettings.resolution || "768P"} · ${videoSettings.duration || 10} 秒`
    : "736×416 · 24fps · 243 帧 → 10.000s";
  const entries = [
    ["文本模型", state.textSettings?.configured ? state.textSettings.model : "规则草稿（未配置）"],
    ["图片模型", state.imageSettings?.model || "gpt-image-2"],
    ["视频模型", videoModel],
    ["输出规格", videoSpec],
  ];
  $("#pipelineModelBadge").textContent = entries.length ? `${entries.length} 个` : "未配置";
  $("#pipelineModels").innerHTML = entries.length
    ? entries.map(([name, value]) => `<div class="model-row"><span>${escapeHtml(name)}</span><strong>${escapeHtml(value)}</strong></div>`).join("")
    : '<div class="empty-state compact-empty">等待项目模型配置。</div>';
}

function renderPipelineArtifacts(manifest) {
  const items = normalizedPipelineStages(manifest).filter((stage) => stage.storage || stage.item_count);
  $("#pipelineArtifactBadge").textContent = `${items.length} 项`;
  $("#pipelineArtifactList").innerHTML = items.length
    ? items.map((item) => `<div class="artifact-row">
      <span><strong>${escapeHtml(item.label || item.key)}</strong><small>${escapeHtml(item.source || item.model || "流水线阶段")}</small></span>
      <span class="artifact-record-meta"><strong>${escapeHtml(labelForStage(item.status))} · ${Number(item.item_count || 0)} 条</strong><small>${escapeHtml(item.updated_at ? new Date(item.updated_at).toLocaleString("zh-CN", { hour12: false }) : "尚未写入")} · PostgreSQL</small></span>
    </div>`).join("")
    : '<div class="empty-state compact-empty">暂无阶段产物。</div>';
}

function renderPlanReview(manifest) {
  const panel = $("#pipelinePlanReview");
  const units = Array.isArray(manifest?.production_units) ? manifest.production_units : [];
  const pending = manifest?.planning_status === "pending_confirmation";
  panel.hidden = !units.length;
  if (!units.length) {
    panel.innerHTML = "";
    return;
  }
  panel.innerHTML = `
    <header class="plan-review-head">
      <div><p class="eyebrow">内容规划</p><h2>${pending ? "确认生产单元后继续" : "生产单元已确认"}</h2></div>
      ${badge(pending ? "等待确认" : "已确认", pending ? "warn" : "ok")}
    </header>
    <div class="plan-unit-list">${units.map((unit) => `
      <article class="plan-unit">
        <span>${escapeHtml(unit.episode_id || unit.unit_id)}</span>
        <div><strong>${escapeHtml(unit.title || "未命名生产单元")}</strong><small>${escapeHtml(unit.summary || "等待文本规划摘要")}</small></div>
        <em>${Math.round(Number(unit.target_duration_seconds || manifest.target_unit_duration_seconds || 0) / 60)} 分钟</em>
      </article>`).join("")}
    </div>
    ${pending ? '<button class="primary plan-confirm" type="button" data-pipeline-action="confirm_plan">确认规划并生成后续阶段</button>' : ""}`;
}

function renderStyleSetup(manifest, registeredProject) {
  const panel = $("#pipelineStyleSetup");
  if (!panel) return;
  const source = manifest || registeredProject;
  const confirmed = source?.style_status === "confirmed" || Boolean(source?.visual_style && source?.planning_status);
  panel.hidden = Boolean(manifest?.story_bible?.length) || !source;
  if (!panel.hidden) {
    $("#pipelineStyleBadge").dataset.status = confirmed ? "confirmed" : "pending";
    $("#pipelineStyleBadge").textContent = confirmed ? "已设定" : "待设定";
    $("#pipelineStyleBadge").className = `status-badge ${confirmed ? "ok" : "warn"}`;
  }
}

function renderStoryBible(manifest) {
  const panel = $("#pipelineStoryBible");
  const list = $("#pipelineStoryBibleList");
  const badgeElement = $("#pipelineStoryBibleBadge");
  if (!panel || !list || !badgeElement) return;
  const items = Array.isArray(manifest?.story_bible) ? manifest.story_bible.filter((item) => item && typeof item === "object") : [];
  const confirmed = manifest?.planning_status === "confirmed" || manifest?.stages?.find?.((stage) => stage?.key === "story_bible")?.status === "approved";
  panel.hidden = !manifest;
  badgeElement.textContent = !items.length ? "待提取" : confirmed ? "已确认" : `${items.length} 条待确认`;
  badgeElement.className = `status-badge ${confirmed ? "ok" : items.length ? "warn" : ""}`;
  if (!items.length) {
    list.innerHTML = '<div class="empty-state compact-empty">文本分析完成后，这里会列出世界观、角色、场景、道具、阵营与视觉规范。</div>';
    return;
  }
  const labels = {
    world_rule: "世界观",
    character: "核心角色",
    location: "关键场景",
    prop: "关键道具",
    faction: "阵营",
    style_rule: "视觉规范",
  };
  const groups = new Map();
  items.forEach((item) => {
    const type = String(item.item_type || item.kind || "world_rule").toLowerCase();
    if (!groups.has(type)) groups.set(type, []);
    groups.get(type).push(item);
  });
  list.innerHTML = [...groups.entries()].map(([type, entries]) => `
    <section class="story-bible-group">
      <h3>${escapeHtml(labels[type] || "项目设定")}</h3>
      <div class="story-bible-items">${entries.map((item) => `
        <article class="story-bible-item">
          <div class="story-bible-item-head"><strong>${escapeHtml(item.name || "未命名设定")}</strong>${badge(confirmed || item.review_status === "confirmed" ? "已确认" : "待确认", confirmed || item.review_status === "confirmed" ? "ok" : "warn")}</div>
          <p>${escapeHtml(item.description || "暂无文字说明")}</p>
          ${item.visual_prompt ? `<small>视觉约束：${escapeHtml(item.visual_prompt)}</small>` : ""}
        </article>`).join("")}</div>
    </section>`).join("");
}

function pipelineProductionReady(manifest) {
  return Boolean(manifest && manifest.planning_status === "confirmed" && Array.isArray(manifest.story_bible) && manifest.story_bible.length && Array.isArray(manifest.shots) && manifest.shots.length);
}

function exportPipeline() {
  const slug = state.localPipeline?.manifest?.project_slug;
  if (!slug) {
    toast("当前没有可导出的制作项目", true);
    return;
  }
  const link = document.createElement("a");
  link.href = `/api/local-pipeline/export?project_slug=${encodeURIComponent(slug)}`;
  link.download = `${slug}-pipeline.json`;
  document.body.append(link);
  link.click();
  link.remove();
  toast("已临时生成项目导出文件");
}

async function importPipeline(file) {
  if (!file) return;
  try {
    const payload = JSON.parse(await file.text());
    const result = await api("/api/local-pipeline/import", { method: "POST", body: JSON.stringify(payload) });
    state.pendingProjectSlug = result.project_slug;
    await loadProjects();
    await loadLocalPipeline(result.project_slug);
    toast(`已导入 ${result.artifact_count} 个阶段产物`);
  } catch (error) {
    toast(error instanceof SyntaxError ? "JSON 文件格式无效" : error.message, true);
  } finally {
    $("#pipelineImportFile").value = "";
  }
}

function pipelineEpisodeIds(manifest) {
  const values = (Array.isArray(manifest?.episodes) ? manifest.episodes : [])
    .map((episode, index) => String(episode?.episode_id || episode?.episode || `EP${String(index + 1).padStart(2, "0")}`).toUpperCase().replace(/[-_]/g, ""))
    .map((value) => /^EP\d+$/.test(value) ? `EP${String(Number(value.slice(2))).padStart(2, "0")}` : value);
  return [...new Set(values.filter(Boolean))];
}

function currentPipelineEpisode(manifest) {
  if (state.selectedProductionUnit) return state.selectedProductionUnit;
  const shot = selectedPipelineShot(manifest);
  return String(shot?.episode_id || pipelineEpisodeIds(manifest)[0] || "EP01").toUpperCase().replace(/[-_]/g, "");
}

function shotEpisodeId(shot) {
  const value = String(shot?.episode_id || shot?.episode || "EP01").toUpperCase().replace(/[-_]/g, "");
  return /^\d+$/.test(value) ? `EP${String(Number(value)).padStart(2, "0")}` : /^EP\d+$/.test(value) ? `EP${String(Number(value.slice(2))).padStart(2, "0")}` : value;
}

function renderProductionUnitFilter(manifest) {
  const units = Array.isArray(manifest?.production_units) && manifest.production_units.length ? manifest.production_units : (manifest?.episodes || []);
  const entries = units.map((unit, index) => ({
    id: String(unit?.episode_id || `EP${String(index + 1).padStart(2, "0")}`).toUpperCase().replace(/[-_]/g, ""),
    title: unit?.title || `生产单元 ${index + 1}`,
  }));
  const valid = entries.map((entry) => entry.id);
  if (!valid.includes(state.selectedProductionUnit)) state.selectedProductionUnit = valid[0] || "";
  $("#pipelineUnitFilter").innerHTML = '<option value="">全部生产单元</option>' + entries
    .map((entry) => `<option value="${escapeHtml(entry.id)}" ${state.selectedProductionUnit === entry.id ? "selected" : ""}>${escapeHtml(entry.id)} · ${escapeHtml(entry.title)}</option>`).join("");
}

function renderPipelineAssets(manifest) {
  const assets = Array.isArray(manifest?.assets) ? manifest.assets : [];
  const episodeId = currentPipelineEpisode(manifest);
  const episodeIds = pipelineEpisodeIds(manifest);
  if (!episodeIds.includes(episodeId)) episodeIds.unshift(episodeId);
  const sharedCount = assets.filter((item) => item.scope === "shared").length;
  const episodeCount = assets.filter((item) => item.scope === "episode" && item.episode_id === episodeId).length;
  const visible = assets.filter((item) => state.assetFilter === "all"
    || (state.assetFilter === "shared" && item.scope === "shared")
    || (state.assetFilter === "episode" && item.scope === "episode" && item.episode_id === episodeId));
  if (!assets.some((item) => item.asset_id === state.selectedAsset)) state.selectedAsset = null;
  $("#pipelineAssetBadge").textContent = `通用 ${sharedCount} · ${episodeId} ${episodeCount}`;
  $("#episodeAssetFilter").textContent = `${episodeId} 素材`;
  $$('[data-asset-filter]').forEach((button) => button.classList.toggle("active", button.dataset.assetFilter === state.assetFilter));
  const kindLabels = { character: "人物", location: "场景", prop: "道具", costume: "服装", vehicle: "载具" };
  $("#pipelineAssetList").innerHTML = visible.length ? visible.map((asset) => `
    <div class="asset-row ${state.selectedAsset === asset.asset_id ? "active" : ""}">
      <span class="asset-kind">${escapeHtml(kindLabels[asset.kind] || asset.kind || "素材")}</span>
      <span class="asset-name"><strong>${escapeHtml(asset.name || asset.asset_id)}</strong><small>${escapeHtml(asset.asset_id)}</small></span>
      <select data-asset-scope="${escapeHtml(asset.asset_id)}" aria-label="${escapeHtml(asset.name || asset.asset_id)} 作用域">
        <option value="shared" ${asset.scope === "shared" ? "selected" : ""}>通用素材</option>
        <option value="episode" ${asset.scope === "episode" ? "selected" : ""}>单集素材</option>
      </select>
      <select data-asset-episode="${escapeHtml(asset.asset_id)}" aria-label="${escapeHtml(asset.name || asset.asset_id)} 所属集" ${asset.scope === "shared" ? "hidden" : ""}>
        ${episodeIds.map((value) => `<option value="${escapeHtml(value)}" ${asset.episode_id === value ? "selected" : ""}>${escapeHtml(value)}</option>`).join("")}
      </select>
      <button class="asset-edit" type="button" data-asset-edit="${escapeHtml(asset.asset_id)}" aria-label="编辑 ${escapeHtml(asset.name || asset.asset_id)} 提示词" title="编辑提示词">✎</button>
    </div>`).join("") : `<div class="empty-state compact-empty">${state.assetFilter === "shared" ? "暂无通用素材。" : state.assetFilter === "episode" ? `${escapeHtml(episodeId)} 暂无单集素材。` : "暂无项目素材。"}</div>`;
  const selected = assets.find((item) => item.asset_id === state.selectedAsset);
  const editor = $("#pipelineAssetPromptEditor");
  editor.hidden = !selected;
  if (selected) {
    $("#pipelineAssetPromptTitle").textContent = selected.name || selected.asset_id;
    fillPromptEditor("pipelineAsset", selected, true);
  }
}

const promptReviewLabels = { pending_review: "待审核", approved: "已通过", needs_revision: "需修改", legacy: "旧数据" };

function fillPromptEditor(prefix, record, enabled) {
  const status = record?.review_status || (record?.prompt || record?.final_prompt ? "legacy" : "pending_review");
  $(`#${prefix}BasePrompt`).value = record?.base_prompt || "";
  $(`#${prefix}DraftPrompt`).value = record?.draft_prompt || record?.prompt || "";
  const finalField = $(`#${prefix}${prefix === "pipelineAsset" ? "FinalPrompt" : "Prompt"}`);
  finalField.value = record?.final_prompt || record?.prompt || "";
  $(`#${prefix}NegativePrompt`).value = record?.negative_prompt || "";
  const badge = $(`#${prefix}PromptReview`);
  badge.textContent = promptReviewLabels[status] || status;
  badge.className = `status-badge ${status === "approved" ? "ok" : status === "needs_revision" ? "danger" : "warn"}`;
  const panel = finalField.closest(".prompt-editor, .asset-prompt-editor");
  panel?.querySelectorAll("textarea:not([readonly]), [data-save-prompt-review]").forEach((control) => { control.disabled = !enabled; });
}

async function updateAssetScope(assetId, scope, episodeId = "") {
  const projectSlug = state.localPipeline?.manifest?.project_slug;
  if (!projectSlug) return;
  try {
    await api("/api/local-pipeline/asset-scope", { method: "PUT", body: JSON.stringify({ project_slug: projectSlug, asset_id: assetId, scope, episode_id: episodeId }) });
    await loadLocalPipeline(projectSlug);
    toast("素材作用域已更新");
  } catch (error) {
    toast(error.message, true);
    await loadLocalPipeline(projectSlug);
  }
}

async function savePromptReview(targetType, reviewStatus) {
  const manifest = state.localPipeline?.manifest;
  const shotTargets = {
    shot_image: ["selectedImage", state.selectedShot],
    shot_video: ["selectedVideo", state.selectedShot],
  };
  const [prefix, targetId] = targetType === "asset" ? ["pipelineAsset", state.selectedAsset] : (shotTargets[targetType] || []);
  if (!manifest?.project_slug || !prefix || !targetId) return;
  const finalField = $(`#${prefix}${prefix === "pipelineAsset" ? "FinalPrompt" : "Prompt"}`);
  const finalPrompt = finalField.value.trim();
  if (reviewStatus === "approved" && !finalPrompt) {
    toast("审核通过前必须填写终稿提示词", true);
    return;
  }
  try {
    await api("/api/local-pipeline/prompt-review", {
      method: "PUT",
      body: JSON.stringify({
        project_slug: manifest.project_slug,
        target_type: targetType,
        target_id: targetId,
        final_prompt: finalPrompt,
        negative_prompt: $(`#${prefix}NegativePrompt`).value.trim(),
        review_status: reviewStatus,
      }),
    });
    await loadLocalPipeline(manifest.project_slug);
    toast(reviewStatus === "approved" ? "提示词已审核通过" : reviewStatus === "needs_revision" ? "已标记为需要修改" : "提示词修改已保存");
  } catch (error) {
    toast(error.message, true);
  }
}

function filteredPipelineShots(manifest) {
  const filter = $("#pipelineShotFilter").value;
  const productionUnit = state.selectedProductionUnit;
  const search = $("#pipelineShotSearch")?.value.trim().toLowerCase() || "";
  return (Array.isArray(manifest?.shots) ? manifest.shots : []).filter((shot) => {
    const image = pipelineMedia(shot.image_media || shot.image_output);
    const video = pipelineMedia(shot.video_media || shot.video_output);
    const matchesSearch = !search || [shot.shot_id, shot.title, shot.action, shot.episode_id, shot.scene_id]
      .some((value) => String(value || "").toLowerCase().includes(search));
    if (!matchesSearch || (productionUnit && shotEpisodeId(shot) !== productionUnit)) return false;
    if (filter === "ready") return Boolean(image || video);
    if (filter === "failed") return String(shot.status || "").toLowerCase().includes("fail");
    if (filter === "pending") return !image && !video;
    return true;
  });
}

function renderPipelineShots(manifest) {
  const shots = filteredPipelineShots(manifest);
  $("#pipelineShots").innerHTML = shots.length ? shots.map((shot) => {
    const image = pipelineMedia(shot.image_media || shot.image_output);
    const video = pipelineMedia(shot.video_media || shot.video_output);
    const statusKind = pipelineStatusKind(shot.status);
    const thumbnail = image
      ? `<img loading="lazy" src="${escapeHtml(image.url)}" alt="${escapeHtml(shot.title || shot.shot_id || "镜头")} 首帧">`
      : '<span class="shot-thumbnail-empty">无首帧</span>';
    const duration = shot.duration_seconds ? `${shot.duration_seconds}s` : "10s";
    const mediaState = video ? "视频已生成" : image ? "首帧已生成" : "等待处理";
    return `<article class="pipeline-shot-card ${state.selectedShot === shot.shot_id ? "active" : ""}" data-pipeline-shot-id="${escapeHtml(shot.shot_id || "")}" tabindex="0">
      <div class="pipeline-shot-media">${thumbnail}<small>${escapeHtml(duration)}</small></div>
      <div class="pipeline-shot-body">
        <div class="shot-head"><strong>${escapeHtml(shot.shot_id || "-")}</strong><span class="shot-status-dot ${statusKind}"></span></div>
        <p>${escapeHtml(shot.title || shot.action || "未命名镜头")}</p>
        <small>${escapeHtml(shot.episode_id || "EP01")} · ${escapeHtml(shot.scene_id || "场景未定")}</small>
        <span class="shot-state-label ${statusKind}">${escapeHtml(mediaState)}</span>
      </div>
    </article>`;
  }).join("") : '<div class="empty-state">当前项目没有符合条件的镜头。</div>';
  renderSelectedShot(manifest);
}

function selectedPipelineShot(manifest) {
  const shots = Array.isArray(manifest?.shots) ? manifest.shots : [];
  return shots.find((shot) => shot.shot_id === state.selectedShot) || null;
}

function renderMobileWorkspaceTab() {
  $$("[data-mobile-workspace-tab]").forEach((button) => {
    button.classList.toggle("active", button.dataset.mobileWorkspaceTab === state.mobileWorkspaceTab);
  });
  $$("[data-mobile-panel]").forEach((panel) => {
    panel.classList.toggle("mobile-active", panel.dataset.mobilePanel === state.mobileWorkspaceTab);
  });
}

function renderSelectedShot(manifest) {
  const shot = selectedPipelineShot(manifest);
  $("#selectedShotTitle").textContent = shot?.title || shot?.action || "选择左侧镜头开始制作";
  $("#selectedShotPath").textContent = shot
    ? `${shot.episode_id || "EP01"} / ${shot.scene_id || "场景未定"} / ${shot.shot_id}`
    : "镜头工作区";
  const shotBadge = $("#selectedShotBadge");
  shotBadge.textContent = shot ? labelForStage(shot.status) : "待选择";
  shotBadge.className = `status-badge ${shot ? pipelineStatusKind(shot.status) : "warn"}`;
  const imagePrompt = shot?.image_prompt_record || (shot ? { prompt: shot.image_prompt } : {});
  const videoPrompt = shot?.video_prompt_record || (shot ? { prompt: shot.video_prompt } : {});
  fillPromptEditor("selectedImage", imagePrompt, Boolean(shot));
  fillPromptEditor("selectedVideo", videoPrompt, Boolean(shot));
  $("#selectedDialogue").value = shot?.audio_design?.dialogue || shot?.audio_design?.narration || "";

  const image = pipelineMedia(shot?.image_media || shot?.image_output);
  const video = pipelineMedia(shot?.video_media || shot?.video_output);
  const selectedMedia = state.mediaTab === "video" ? video : image;
  const sourceLabel = state.mediaTab === "video" ? "打开原视频" : "查看原图";
  const sourceLink = selectedMedia
    ? `<a class="media-source-link" href="${escapeHtml(selectedMedia.url)}" target="_blank" rel="noreferrer" title="${sourceLabel}" aria-label="${sourceLabel}"><span aria-hidden="true">↗</span>${sourceLabel}</a>`
    : "";
  $("#pipelineMediaPreview").innerHTML = !shot
    ? '<div class="media-empty"><strong>未选择镜头</strong><span>从左侧队列选择一个镜头</span></div>'
    : selectedMedia
      ? state.mediaTab === "video"
        ? `<video controls preload="metadata" src="${escapeHtml(selectedMedia.url)}"></video>${sourceLink}`
        : `<a class="media-canvas-link" href="${escapeHtml(selectedMedia.url)}" target="_blank" rel="noreferrer" title="查看原图"><img src="${escapeHtml(selectedMedia.url)}" alt="${escapeHtml(shot.title || shot.shot_id)} 首帧"></a>${sourceLink}`
      : `<div class="media-empty"><strong>${state.mediaTab === "video" ? "视频尚未生成" : "首帧尚未生成"}</strong><span>${state.mediaTab === "video" ? "先生成首帧，再提交 MiniMax H3" : "使用 GPT Image API 配置生成首帧"}</span></div>`;
  $$("[data-media-tab]").forEach((button) => button.classList.toggle("active", button.dataset.mediaTab === state.mediaTab));
  if (manifest) renderPipelineAssets(manifest);
  renderMobileWorkspaceTab();
}

function renderLocalPipeline() {
  const payload = state.localPipeline || { exists: false, manifest: null, projects: [] };
  const manifest = payload.manifest && typeof payload.manifest === "object" ? payload.manifest : null;
  const project = manifest?.project;
  const registeredProject = payload.registered_project;
  const projectTitle = (typeof project === "object" ? (project.title || project.name) : project) || manifest?.project_title || registeredProject?.title;
  const projectSlug = (typeof project === "object" ? project.slug : "") || manifest?.project_slug || payload.project_slug;
  const source = (typeof manifest?.source === "object" ? (manifest.source.path || manifest.source.novel_path || manifest.source.name) : (manifest?.novel_path || manifest?.source)) || registeredProject?.novel_path;
  $("#pipelineExistsBadge").textContent = payload.exists && manifest ? "已载入" : "未载入";
  $("#pipelineExistsBadge").className = `status-badge ${payload.exists && manifest ? "ok" : "warn"}`;
  $("#pipelineTitle").textContent = projectTitle || "等待项目源";
  $("#pipelineSource").textContent = source || "载入本地流水线状态";
  if (source && !$("#pipelineNovelPath").value) $("#pipelineNovelPath").value = source;
  if (projectSlug && !$("#pipelineProjectSlug").value) $("#pipelineProjectSlug").value = projectSlug;
  if (projectTitle && !$("#pipelineProjectTitle").value) $("#pipelineProjectTitle").value = projectTitle;
  if (manifest?.max_shots) $("#pipelineMaxShots").value = manifest.max_shots;
  if (registeredProject || manifest) fillPipelineProject({ ...(registeredProject || {}), ...(manifest || {}), slug: projectSlug, title: projectTitle, novel_path: source }, manifest?.max_shots);
  if (projectTitle) {
    $("#projectName").textContent = projectTitle;
    $("#projectStage").textContent = manifest ? `${labelForStage(manifest.status)} / ${manifest.shots?.length || 0} 个镜头` : `${projectStatusLabels[registeredProject?.status] || "草稿"} / 尚未初始化`;
  }
  if (manifest?.planning_status === "pending_confirmation") state.localPipeline.selectedStage = "content_plan";
  else if (manifest && !state.localPipeline.selectedStage) state.localPipeline.selectedStage = "clip_generation";
  const episodes = Array.isArray(manifest?.episodes) ? manifest.episodes.length : 0;
  const shots = Array.isArray(manifest?.shots) ? manifest.shots : [];
  renderProductionUnitFilter(manifest);
  const unitShots = state.selectedProductionUnit ? shots.filter((shot) => shotEpisodeId(shot) === state.selectedProductionUnit) : shots;
  if (!unitShots.some((shot) => shot.shot_id === state.selectedShot)) state.selectedShot = unitShots[0]?.shot_id || null;
  $("#pipelineStats").innerHTML = [["章节/集数", episodes, "项目已登记集数"], ["镜头", shots.length, "可执行镜头"], ["当前状态", manifest?.status || "待初始化", "manifest 状态"]]
    .map(([name, value, note]) => `<article><span>${escapeHtml(name)}</span><strong>${escapeHtml(value)}</strong><small>${escapeHtml(note)}</small></article>`).join("");
  $("#pipelineEmpty").hidden = Boolean(manifest);
  $("#pipelineArtifacts").hidden = !manifest;
  $("#pipelineAssets").hidden = !manifest;
  $("#pipelineShotsPanel").hidden = !manifest;
  renderPipelineStages(manifest);
  renderStyleSetup(manifest, registeredProject);
  renderStoryBible(manifest);
  renderPlanReview(manifest);
  renderPipelineModels(manifest);
  $("#pipelineUnitContext").textContent = state.selectedProductionUnit ? `${state.selectedProductionUnit} / ${episodes}` : episodes ? `${episodes} 个生产单元` : "待规划";
  const productionReady = pipelineProductionReady(manifest);
  $$('[data-pipeline-action="build_workflows"], [data-pipeline-action="generate_image"], [data-pipeline-action="generate_video"], [data-pipeline-action="generate_tts"], [data-pipeline-action="mix_audio"]').forEach((button) => {
    button.disabled = !productionReady || (button.dataset.pipelineAction === "generate_video" && state.videoSettings?.mode === "api" && !state.videoSettings?.api_key_configured);
  });
  if (manifest) {
    renderPipelineArtifacts(manifest);
    renderPipelineAssets(manifest);
    renderPipelineShots(manifest);
  } else {
    renderSelectedShot(null);
  }
  const runningJobs = state.jobs.filter((job) => ["queued", "running"].includes(job.status));
  const channel = state.videoSettings?.mode === "api" ? "视频 API" : "本地 ComfyUI";
  $("#pipelineJobHint").textContent = runningJobs.length ? "已有制作任务执行中，可在任务中心查看输出。" : `任务会出现在任务中心，生成前请确认 ${channel} 可用。`;
  $("#pipelineTaskSummary").textContent = runningJobs.length ? `${runningJobs.length} 个任务正在运行或等待` : "暂无运行中任务";
}

async function loadLocalPipeline(projectSlug = "") {
  try {
    const query = projectSlug ? `?project_slug=${encodeURIComponent(projectSlug)}` : "";
    state.localPipeline = await api(`/api/local-pipeline${query}`);
    renderLocalPipeline();
  } catch (error) {
    state.localPipeline = { exists: false, manifest: null, projects: [] };
    renderLocalPipeline();
    toast(error.message, true);
  }
}

const projectStatusLabels = { draft: "草稿", active: "制作中", paused: "已暂停", completed: "已完成", archived: "已归档" };

function renderProjects() {
  const projects = state.projects || [];
  $("#projectListCount").textContent = String(projects.length);
  $("#projectList").innerHTML = projects.length ? projects.map((project) => `
    <article class="project-card">
      <div>
        <h3>${escapeHtml(project.title)}</h3>
        <p>${escapeHtml(project.slug)} · ${project.source_type === "screenplay" ? "剧本" : "小说"} · ${project.content_type === "series" ? "短剧" : "单片"}</p>
        <small>${escapeHtml(projectStatusLabels[project.status] || project.status)} · ${escapeHtml(project.current_stage || "方案")} · ${project.has_manifest ? "已有内容规划" : "尚未规划"}</small>
      </div>
      <div class="project-card-actions">
        <select data-project-status="${escapeHtml(project.slug)}" aria-label="${escapeHtml(project.title)} 状态">
          ${Object.entries(projectStatusLabels).map(([value, label]) => `<option value="${value}" ${project.status === value ? "selected" : ""}>${label}</option>`).join("")}
        </select>
        <button type="button" data-project-open="${escapeHtml(project.slug)}">打开</button>
      </div>
    </article>`).join("") : '<div class="empty-state">还没有登记的电影项目。</div>';
}

async function loadProjects() {
  try {
    const payload = await api("/api/projects");
    state.projects = Array.isArray(payload.items) ? payload.items : [];
    renderProjects();
  } catch (error) {
    state.projects = [];
    renderProjects();
    toast(error.message, true);
  }
}

function openProject(slug) {
  const project = (state.projects || []).find((item) => item.slug === slug);
  if (!project) return;
  fillPipelineProject(project);
  state.selectedShot = null;
  state.selectedProductionUnit = "";
  state.localPipeline = null;
  state.pendingProjectSlug = project.slug;
  switchModule("production");
}

async function createProject(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const payload = Object.fromEntries(new FormData(form).entries());
  payload.max_shots = Number(payload.max_shots || 4);
  try {
    const project = await api("/api/projects", { method: "POST", body: JSON.stringify(payload) });
    fillPipelineProject(project, payload.max_shots);
    state.selectedShot = null;
    state.selectedProductionUnit = "";
    state.localPipeline = null;
    state.pendingProjectSlug = project.slug;
    switchModule("production");
    toast("项目已创建，请先确定视觉风格");
    await loadProjects();
  } catch (error) {
    toast(error.message, true);
  }
}

async function saveProjectStyle(event) {
  event.preventDefault();
  const slug = $("#pipelineProjectSlug").value.trim();
  const style = $("#pipelinePrimaryStyle").value;
  if (!slug || !style) {
    toast("请先选择视频主体风格", true);
    return;
  }
  const button = event.currentTarget.querySelector("button[type=submit]");
  button.disabled = true;
  try {
    await api(`/api/projects/${encodeURIComponent(slug)}`, {
      method: "PUT",
      body: JSON.stringify({
        visual_style: style,
        style_status: "confirmed",
        current_stage: "content_plan",
      }),
    });
    $("#pipelineStyleBadge").dataset.status = "confirmed";
    await loadProjects();
    toast("视频主体风格已确认，开始提取故事圣经");
    await startPipelineJob("init");
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

async function updateProjectStatus(slug, status) {
  try {
    await api(`/api/projects/${encodeURIComponent(slug)}`, { method: "PUT", body: JSON.stringify({ status }) });
    await loadProjects();
    toast("项目状态已更新");
  } catch (error) {
    toast(error.message, true);
    await loadProjects();
  }
}

function renderTextSettings() {
  const settings = state.textSettings || {};
  const configured = Boolean(settings.configured);
  const badgeElement = $("#textSettingsBadge");
  badgeElement.textContent = configured ? "已配置" : "规则草稿";
  badgeElement.className = `status-badge ${configured ? "ok" : "warn"}`;
  $("#textProvider").value = settings.provider || "OpenAI 兼容文本 API";
  $("#textBaseUrl").value = settings.base_url || "https://api.openai.com/v1";
  $("#textModel").value = settings.model || "";
  $("#textTimeout").value = String(settings.timeout || 120);
  $("#textApiKey").value = "";
  if (state.localPipeline?.manifest) renderPipelineModels(state.localPipeline.manifest);
}

function captureStylePromptFields() {
  const preset = state.stylePrompts?.presets?.[state.selectedStylePrompt];
  if (!preset) return;
  preset.image_prompt = $("#styleImagePrompt").value;
  preset.video_prompt = $("#styleVideoPrompt").value;
  preset.negative_prompt = $("#styleNegativePrompt").value;
}

function renderStylePrompts() {
  const payload = state.stylePrompts;
  const preset = payload?.presets?.[state.selectedStylePrompt];
  if (!preset) return;
  $$('[data-style-prompt-style]').forEach((button) => {
    const active = button.dataset.stylePromptStyle === state.selectedStylePrompt;
    button.classList.toggle("active", active);
    button.setAttribute("aria-selected", String(active));
  });
  $("#styleImagePrompt").value = preset.image_prompt || "";
  $("#styleVideoPrompt").value = preset.video_prompt || "";
  $("#styleNegativePrompt").value = preset.negative_prompt || "";
  const badge = $("#stylePromptsBadge");
  badge.textContent = payload.source === "custom" ? "已自定义" : "默认";
  badge.className = `status-badge ${payload.source === "custom" ? "ok" : ""}`;
}

async function loadStylePrompts() {
  try {
    state.stylePrompts = await api("/api/style-prompts");
    renderStylePrompts();
  } catch (error) {
    state.stylePrompts = null;
    toast(error.message, true);
  }
}

async function saveStylePrompts(event) {
  event.preventDefault();
  captureStylePromptFields();
  const button = $("#stylePromptsForm button[type=submit]");
  button.disabled = true;
  try {
    state.stylePrompts = await api("/api/style-prompts", { method: "PUT", body: JSON.stringify({ presets: state.stylePrompts.presets }) });
    renderStylePrompts();
    toast("风格提示词预设已保存");
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

async function resetStylePrompts() {
  if (!window.confirm("恢复三种风格的默认提示词？")) return;
  try {
    state.stylePrompts = await api("/api/style-prompts/reset", { method: "POST", body: "{}" });
    renderStylePrompts();
    toast("已恢复默认风格提示词");
  } catch (error) {
    toast(error.message, true);
  }
}

async function loadTextSettings() {
  try {
    state.textSettings = await api("/api/text-settings");
    renderTextSettings();
  } catch (error) {
    state.textSettings = null;
    renderTextSettings();
    toast(error.message, true);
  }
}

async function saveTextSettings(event) {
  event.preventDefault();
  const button = $("#textSettingsForm button[type=submit]");
  button.disabled = true;
  const payload = {
    base_url: $("#textBaseUrl").value.trim(),
    model: $("#textModel").value.trim(),
    timeout: Number($("#textTimeout").value),
  };
  const apiKey = $("#textApiKey").value.trim();
  if (apiKey) payload.api_key = apiKey;
  try {
    await api("/api/text-settings", { method: "PUT", body: JSON.stringify(payload) });
    toast("文本 AI 配置已保存");
    await loadTextSettings();
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

function normalizeImageSettings(payload) {
  const source = payload && typeof payload.settings === "object" ? payload.settings : payload || {};
  const configured = typeof payload?.configured === "boolean"
    ? payload.configured
    : typeof payload?.api_key_configured === "boolean"
      ? payload.api_key_configured
    : typeof payload?.exists === "boolean"
      ? payload.exists
      : typeof source.configured === "boolean"
        ? source.configured
        : typeof source.api_key_configured === "boolean"
          ? source.api_key_configured
          : typeof source.exists === "boolean" ? source.exists : false;
  return {
    configured,
    provider: "GPT Image API",
    base_url: source.base_url || payload?.base_url || "",
    model: source.model || payload?.model || "",
    size: source.size || payload?.size || "1536x1024",
    quality: source.quality || payload?.quality || "auto",
  };
}

function renderImageSettings() {
  const settings = state.imageSettings || normalizeImageSettings({});
  const badgeElement = $("#imageSettingsBadge");
  badgeElement.textContent = settings.configured ? "已配置" : "未配置";
  badgeElement.className = `status-badge ${settings.configured ? "ok" : "warn"}`;
  $("#imageProvider").value = "GPT Image API";
  $("#imageBaseUrl").value = settings.base_url;
  $("#imageModel").value = settings.model;
  $("#imageSize").value = settings.size;
  $("#imageQuality").value = settings.quality;
  $("#imageApiKey").value = "";
  if (state.localPipeline?.manifest) renderPipelineModels(state.localPipeline.manifest);
}

async function loadImageSettings() {
  try {
    state.imageSettings = normalizeImageSettings(await api("/api/image-settings"));
    renderImageSettings();
  } catch (error) {
    state.imageSettings = null;
    renderImageSettings();
    toast(error.message, true);
  }
}

async function saveImageSettings(event) {
  event.preventDefault();
  const button = $("#imageSettingsForm button[type=submit]");
  button.disabled = true;
  const payload = {
    provider: "GPT Image API",
    base_url: $("#imageBaseUrl").value.trim(),
    model: $("#imageModel").value.trim(),
    size: $("#imageSize").value,
    quality: $("#imageQuality").value,
  };
  const apiKey = $("#imageApiKey").value.trim();
  if (apiKey) payload.api_key = apiKey;
  try {
    await api("/api/image-settings", { method: "PUT", body: JSON.stringify(payload) });
    $("#imageApiKey").value = "";
    toast("图片生成配置已保存");
    await loadImageSettings();
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

function renderVideoSettings() {
  const settings = state.videoSettings || {
    mode: "local",
    base_url: "https://api.minimax.io",
    model: "MiniMax-Hailuo-02",
    duration: 10,
    resolution: "768P",
  };
  const isApi = settings.mode === "api";
  $("#videoMode").value = isApi ? "api" : "local";
  $$('[data-video-mode]').forEach((button) => button.classList.toggle("active", button.dataset.videoMode === settings.mode));
  $("#videoLocalSettings").hidden = isApi;
  $("#videoApiSettings").hidden = !isApi;
  $("#videoProvider").value = settings.provider || "MiniMax Video API";
  $("#videoBaseUrl").value = settings.base_url || "https://api.minimax.io";
  $("#videoModel").value = settings.model || "MiniMax-Hailuo-02";
  $("#videoDuration").value = String(settings.duration || 10);
  $("#videoResolution").value = settings.resolution || "768P";
  $("#videoApiKey").value = "";
  $("#generateVideoAction").textContent = `生成 ${isApi ? settings.duration || 10 : 10} 秒视频`;
  $$('[data-pipeline-action="generate_video"]').forEach((button) => {
    button.disabled = !pipelineProductionReady(state.localPipeline?.manifest) || (isApi && !settings.api_key_configured);
  });
  if (!state.jobs.some((job) => ["queued", "running"].includes(job.status))) {
    $("#pipelineJobHint").textContent = `任务会出现在任务中心，生成前请确认 ${isApi ? "视频 API" : "本地 ComfyUI"} 可用。`;
  }
  const badge = $("#videoSettingsBadge");
  badge.textContent = isApi ? (settings.api_key_configured ? "API 已配置" : "API 缺少密钥") : "本地 H3";
  badge.className = `status-badge ${!isApi || settings.api_key_configured ? "ok" : "warn"}`;
  if (state.localPipeline?.manifest) renderPipelineModels(state.localPipeline.manifest);
}

async function loadVideoSettings() {
  try {
    state.videoSettings = await api("/api/video-settings");
    renderVideoSettings();
  } catch (error) {
    state.videoSettings = null;
    renderVideoSettings();
    toast(error.message, true);
  }
}

async function saveVideoSettings(event) {
  event.preventDefault();
  const button = $("#videoSettingsForm button[type=submit]");
  button.disabled = true;
  const payload = {
    mode: $("#videoMode").value,
    base_url: $("#videoBaseUrl").value.trim(),
    model: $("#videoModel").value.trim(),
    duration: Number($("#videoDuration").value),
    resolution: $("#videoResolution").value,
  };
  const apiKey = $("#videoApiKey").value.trim();
  if (apiKey) payload.api_key = apiKey;
  try {
    await api("/api/video-settings", { method: "PUT", body: JSON.stringify(payload) });
    toast("视频生成配置已保存");
    await loadVideoSettings();
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

function renderAudioSettings() {
  const settings = state.audioSettings || {};
  const badgeElement = $("#audioSettingsBadge");
  if (!badgeElement) return;
  badgeElement.textContent = settings.configured ? "已启用" : "未启用";
  badgeElement.className = `status-badge ${settings.configured ? "ok" : "warn"}`;
  $("#audioEnabled").checked = Boolean(settings.enabled);
  $("#audioVoice").value = settings.voice || "zh-CN-YunxiNeural";
  $("#audioRate").value = settings.rate || "+0%";
  $("#audioPitch").value = settings.pitch || "+0Hz";
}

async function loadAudioSettings() {
  try { state.audioSettings = await api("/api/audio-settings"); renderAudioSettings(); }
  catch (error) { toast(error.message, true); }
}

async function saveAudioSettings(event) {
  event.preventDefault();
  const button = $("#audioSettingsForm button[type=submit]"); button.disabled = true;
  try {
    await api("/api/audio-settings", { method: "PUT", body: JSON.stringify({ enabled: $("#audioEnabled").checked, voice: $("#audioVoice").value.trim(), rate: $("#audioRate").value.trim(), pitch: $("#audioPitch").value.trim() }) });
    await loadAudioSettings(); toast("Edge TTS 配置已保存");
  } catch (error) { toast(error.message, true); } finally { button.disabled = false; }
}

async function startPipelineJob(action, shotId = "") {
  const input = pipelineInputs();
  if (action === "init" && !input.novel_path) {
    toast("请先填写小说或剧本文件路径", true);
    return;
  }
  if (!shotId && ["generate_image", "generate_video", "generate_tts", "mix_audio"].includes(action)) {
    const shots = (Array.isArray(state.localPipeline?.manifest?.shots) ? state.localPipeline.manifest.shots : [])
      .filter((shot) => !state.selectedProductionUnit || shotEpisodeId(shot) === state.selectedProductionUnit);
    const candidate = shots.find((shot) => {
      const image = pipelineMedia(shot.image_media || shot.image_output);
      const video = pipelineMedia(shot.video_media || shot.video_output);
      return action === "generate_image" ? !image : action === "generate_video" ? image && !video : video;
    });
    if (!candidate) {
      toast(action === "generate_video" ? "没有可生成视频的镜头，请先生成首帧" : action === "generate_tts" ? "没有可配音的镜头" : "没有可合成的镜头", true);
      return;
    }
    shotId = candidate.shot_id;
  }
  const payload = { action, ...input };
  if (shotId) payload.shot_id = shotId;
  try {
    const job = await api("/api/local-pipeline/jobs", { method: "POST", body: JSON.stringify(payload) });
    toast(`${job.label || action} 已加入任务队列`);
    state.selectedJob = job.id;
    await loadJobs();
    if (action === "init") await loadLocalPipeline();
  } catch (error) {
    toast(error.message, true);
  }
}

function renderRail() {
  const status = state.status;
  const summary = status.summary;
  $("#projectName").textContent = status.project;
  $("#projectStage").textContent = `${summary.episode} / ${summary.completed_scenes} 个场景已完成`;
  $("#sceneMetric").textContent = `${summary.completed_scenes} / ${summary.scene_count}`;
  $("#nextMetric").textContent = summary.next_scene;
  $("#comfyMetric").textContent = status.services.comfy.ok ? "在线" : "离线";
  $("#videoMetric").textContent = status.services.video.ok ? "在线" : "离线";
}

function renderHome() {
  const { status } = state;
  const { summary } = status;
  $("#updatedMetric").textContent = `状态更新时间 ${status.updated || "未知"}`;
  $("#nextSceneBadge").textContent = summary.next_scene;
  $("#homeStats").innerHTML = [
    ["已完成场景", summary.completed_scenes, `共 ${summary.scene_count} 个已建场景`],
    ["已登记镜头", summary.shot_count, "分镜与视频审核条目"],
    ["技术预览", summary.fallback_count, "仅测试，不是生产视频"],
    ["EP01 审核", status.ep01.formal_gate.ok ? "通过" : "待处理", labelForStage(status.ep01.cycle_state)],
  ].map(([name, value, note]) => `<article><span>${escapeHtml(name)}</span><strong>${escapeHtml(value)}</strong><small>${escapeHtml(note)}</small></article>`).join("");

  $("#nextActions").innerHTML = status.next_actions.length
    ? status.next_actions.map((item, index) => `<div class="action-row"><span>${String(index + 1).padStart(2, "0")}</span><p>${escapeHtml(item)}</p></div>`).join("")
    : '<div class="empty-state">当前没有待处理动作。</div>';

  const serviceLabels = { comfy: "ComfyUI", video: "视频服务", ep01_review: "EP01 审核服务", storyboard_review: "分镜审核服务" };
  const services = Object.entries(status.services);
  $("#serviceBadge").textContent = `${services.filter(([, item]) => item.ok).length} / ${services.length} 在线`;
  $("#serviceBadge").className = `status-badge ${services.some(([, item]) => !item.ok) ? "warn" : "ok"}`;
  $("#serviceList").innerHTML = services.map(([key, item]) => `
    <div class="service-row">
      <div><strong>${escapeHtml(serviceLabels[key] || key)}</strong><small>${escapeHtml(item.url)} · ${item.latency_ms} ms</small></div>
      <span class="service-dot ${item.ok ? "ok" : ""}" title="${item.ok ? "在线" : "离线"}"></span>
    </div>`).join("");

  const recent = [...status.scenes].slice(-5).reverse();
  $("#recentScenes").innerHTML = recent.map((scene) => `
    <button class="recent-row" type="button" data-scene-open="${scene.id}">
      <span class="recent-id">${scene.id}</span>
      <span><strong>${escapeHtml(scene.title)}</strong><small>${escapeHtml(scene.source || scene.beat_id)}</small></span>
      ${badge(scene.ready ? "已完成" : "待处理", scene.ready ? "ok" : "warn")}
    </button>`).join("");
}

function filteredScenes() {
  const search = $("#sceneSearch").value.trim().toLowerCase();
  const filter = $("#sceneFilter").value;
  return state.status.scenes.filter((scene) => {
    const matchesText = !search || `${scene.id} ${scene.title} ${scene.source}`.toLowerCase().includes(search);
    const matchesFilter = filter === "all"
      || (filter === "ready" && scene.ready)
      || (filter === "fallback" && scene.fallback_count > 0)
      || (filter === "pending" && !scene.ready);
    return matchesText && matchesFilter;
  });
}

function renderSceneList() {
  const items = filteredScenes();
  $("#sceneListCount").textContent = String(items.length);
  $("#sceneList").innerHTML = items.length ? items.map((scene) => `
    <button type="button" class="scene-item ${state.selectedScene === scene.id ? "active" : ""}" data-scene-id="${scene.id}">
      <span class="scene-item-id">${scene.id}</span>
      <span><strong>${escapeHtml(scene.title)}</strong><small>${scene.shot_count} 镜头 · ${scene.fallback_count ? "技术预览" : "生产候选"}</small></span>
      <span class="scene-item-mark ${scene.ready ? "ready" : ""}"></span>
    </button>`).join("") : '<div class="empty-state">没有符合筛选条件的场景。</div>';
}

function fileLink(file, label) {
  if (!file?.exists || !file.url) return "";
  return `<a class="button-link" href="${escapeHtml(file.url)}" target="_blank" rel="noreferrer">${escapeHtml(label)}</a>`;
}

function formatTime(value) {
  const seconds = Math.max(0, Math.round(Number(value || 0)));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function stopFramePlayer(player) {
  const timer = frameTimers.get(player);
  if (timer) clearInterval(timer);
  frameTimers.delete(player);
  player.dataset.playing = "false";
  const button = player.querySelector("[data-frame-play]");
  if (button) button.textContent = "播放";
}

function updateFramePlayer(player, time) {
  const duration = Number(player.dataset.duration || 0);
  const nextTime = Math.max(0, Math.min(Number(time || 0), duration));
  const slider = player.querySelector("[data-frame-seek]");
  const image = player.querySelector("[data-frame-image]");
  slider.value = String(nextTime);
  player.querySelector("[data-frame-time]").textContent = `${formatTime(nextTime)} / ${formatTime(duration)}`;
  image.src = `/video-frame?path=${encodeURIComponent(player.dataset.path)}&time=${nextTime.toFixed(2)}&v=${Date.now()}`;
  if (nextTime >= duration) stopFramePlayer(player);
}

function framePlayer(file, frameCount, fps) {
  if (!file?.exists) return '<div class="empty-state">当前场景没有可预览的正式片段。</div>';
  const duration = Number(frameCount || 0) / Math.max(Number(fps || 0), 1);
  return `<div class="frame-player" data-frame-player data-path="${escapeHtml(file.path)}" data-duration="${duration}" data-playing="false">
    <img data-frame-image src="/video-frame?path=${encodeURIComponent(file.path)}&time=0" alt="场景视频帧预览">
    <div class="frame-controls">
      <button type="button" data-frame-play>播放</button>
      <input type="range" data-frame-seek min="0" max="${duration}" step="0.5" value="0" aria-label="视频帧预览进度">
      <output data-frame-time>0:00 / ${formatTime(duration)}</output>
      <a class="button-link" href="${escapeHtml(file.url)}" target="_blank" rel="noreferrer">打开原片</a>
    </div>
  </div>`;
}

function renderSceneDetail() {
  const scene = state.status.scenes.find((item) => item.id === state.selectedScene);
  if (!scene) return;
  $("#sceneScope").textContent = `${scene.segment_id} / ${scene.beat_id || "场景"}`;
  $("#sceneTitle").textContent = scene.title;
  $("#sceneSource").textContent = scene.source || "未登记来源";
  $("#sceneHeroActions").innerHTML = [
    fileLink(scene.storyboard_dashboard, "打开分镜看板"),
    fileLink(scene.formal_cut.file, "打开成片"),
  ].filter(Boolean).join("");

  const formalFile = scene.formal_cut.file;
  const formalPlayer = framePlayer(formalFile, scene.formal_cut.frame_count, scene.formal_cut.fps);
  const warning = scene.fallback_count
    ? `<div class="production-warning">本场景有 ${scene.fallback_count} 个镜头使用 technical still fallback，仅用于测试流水线连续性，不能视为生产级视频。</div>`
    : "";
  const shots = scene.shots.length ? scene.shots.map((shot) => {
    const image = shot.storyboard?.exists ? `<img src="${escapeHtml(shot.storyboard.url)}" alt="${escapeHtml(shot.title)} 分镜" loading="lazy">` : '<div class="empty-state">分镜图缺失</div>';
    const checks = Object.entries(shot.checks || {}).map(([name, value]) => `<span class="${value === "pass" ? "pass" : ""}">${escapeHtml(name)} · ${escapeHtml(value)}</span>`).join("");
    const isFallback = shot.mode.includes("technical") || shot.mode.includes("fallback");
    return `<article class="shot-card">
      ${image}
      <div class="shot-body">
        <div class="shot-head"><h3>${escapeHtml(shot.title)}</h3>${badge(isFallback ? "仅测试" : labelForStage(shot.status), isFallback ? "warn" : "ok")}</div>
        <small>${escapeHtml(shot.shot_id)} · ${escapeHtml(shot.duration)}</small>
        <div class="check-strip">${checks}</div>
        <p class="shot-notes">${escapeHtml(shot.notes)}</p>
        <div class="file-links">${fileLink(shot.storyboard, "查看分镜")}${fileLink(shot.video, "播放镜头")}</div>
      </div>
    </article>`;
  }).join("") : '<div class="empty-state">没有镜头审核数据。</div>';

  $("#sceneContent").innerHTML = `
    <section class="scene-summary">
      <div><span>场景状态</span><strong>${escapeHtml(scene.ready ? "已完成测试片段" : "待处理")}</strong></div>
      <div><span>镜头数量</span><strong>${scene.shot_count}</strong></div>
      <div><span>视频审核</span><strong>${escapeHtml(labelForStage(scene.review_decision))}</strong></div>
      <div><span>片段大小</span><strong>${formatBytes(scene.formal_cut.bytes)}</strong></div>
    </section>
    ${warning}
    <section class="panel media-section">
      <div class="section-head"><div><p class="eyebrow">场景片段</p><h2>视频预览</h2></div>${badge(scene.formal_cut.ready ? "可播放" : "缺失", scene.formal_cut.ready ? "ok" : "danger")}</div>
      ${formalPlayer}
    </section>
    <section class="panel media-section">
      <div class="section-head"><div><p class="eyebrow">镜头清单</p><h2>分镜与审核检查</h2></div>${badge(`${scene.shots.length} 项`)}</div>
      <div class="shot-grid">${shots}</div>
    </section>`;
}

function selectScene(sceneId) {
  state.selectedScene = sceneId;
  renderSceneList();
  renderSceneDetail();
  requestAnimationFrame(() => {
    document.querySelector(".scene-item.active")?.scrollIntoView({ block: "nearest" });
  });
}

function renderScenes() {
  if (!state.selectedScene && state.status.scenes.length) state.selectedScene = state.status.scenes.at(-1).id;
  renderSceneList();
  renderSceneDetail();
  requestAnimationFrame(() => {
    document.querySelector(".scene-item.active")?.scrollIntoView({ block: "nearest" });
  });
}

async function loadReviews() {
  try {
    state.reviews = await api("/api/reviews");
    if (!state.selectedReview && state.reviews.items.length) state.selectedReview = state.reviews.items.at(-1).id;
    renderReviews();
  } catch (error) {
    toast(error.message, true);
  }
}

function filteredReviews() {
  const filter = $("#reviewFilter").value;
  return state.reviews.items.filter((item) => filter === "all"
    || (filter === "pending" && !["pass", "approved_for_episode_cut"].includes(item.decision))
    || (filter === "fallback" && item.fallback_count > 0));
}

function renderReviews() {
  const { summary } = state.reviews;
  $("#reviewStats").innerHTML = [
    ["审核项目", summary.total, "EP01 与 EP02 场景"],
    ["待处理", summary.pending, "尚未通过审核"],
    ["技术预览镜头", summary.fallback, "发布前必须重新生成"],
  ].map(([name, value, note]) => `<article><span>${name}</span><strong>${value}</strong><small>${note}</small></article>`).join("");
  const items = filteredReviews();
  $("#reviewList").innerHTML = items.length ? items.map((item) => `
    <button type="button" class="review-row ${state.selectedReview === item.id ? "active" : ""}" data-review-id="${item.id}">
      <span class="recent-id">${escapeHtml(item.id)}</span>
      <span><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(item.kind)} · ${item.fallback_count || 0} 个技术预览</small></span>
      ${badge(labelForStage(item.decision), ["pass", "approved_for_episode_cut"].includes(item.decision) ? "ok" : "warn")}
    </button>`).join("") : '<div class="empty-state">没有符合条件的审核项目。</div>';
  renderReviewDetail();
}

function renderReviewDetail() {
  const item = state.reviews.items.find((entry) => entry.id === state.selectedReview);
  if (!item) {
    $("#reviewDetail").innerHTML = '<div class="empty-state">选择审核项目查看详情。</div>';
    return;
  }
  const counts = item.counts || {};
  $("#reviewDetail").innerHTML = `
    <p class="eyebrow">${escapeHtml(item.kind)}</p>
    <h2>${escapeHtml(item.title)}</h2>
    <p>当前决定：${escapeHtml(labelForStage(item.decision))}</p>
    ${item.fallback_count ? `<div class="production-warning">包含 ${item.fallback_count} 个仅供测试的技术预览镜头。</div>` : ""}
    <div class="review-counts">
      <div><span>通过</span><strong>${counts.pass || 0}</strong></div>
      <div><span>待审</span><strong>${counts.pending || 0}</strong></div>
      <div><span>需重生成</span><strong>${counts.needs_regeneration || 0}</strong></div>
      <div><span>阻塞</span><strong>${counts.blocked || 0}</strong></div>
    </div>
    <div class="file-links">${fileLink(item.media, "打开审核材料")}${item.id.startsWith("SC") ? `<button type="button" data-scene-open="${item.id}">查看场景</button>` : ""}</div>`;
}

async function startAction(action) {
  const buttons = $$(`[data-action="${action}"]`);
  buttons.forEach((button) => { button.disabled = true; });
  try {
    const job = await api("/api/jobs", { method: "POST", body: JSON.stringify({ action }) });
    toast(`${job.label} 已加入任务队列`);
    state.selectedJob = job.id;
    await loadJobs();
    switchModule("tasks");
  } catch (error) {
    toast(error.message, true);
  } finally {
    buttons.forEach((button) => { button.disabled = false; });
  }
}

async function loadJobs() {
  try {
    const wasRunning = state.jobs.some((job) => ["queued", "running"].includes(job.status));
    const payload = await api("/api/jobs");
    state.jobs = payload.items;
    const isRunning = state.jobs.some((job) => ["queued", "running"].includes(job.status));
    if (!state.selectedJob && state.jobs.length) state.selectedJob = state.jobs[0].id;
    renderJobs();
    if (state.localPipeline) renderLocalPipeline();
    if (wasRunning && !isRunning && state.localPipeline) await loadLocalPipeline();
    if (isRunning) setTimeout(loadJobs, 1600);
  } catch (error) {
    toast(error.message, true);
  }
}

function renderJobs() {
  $("#jobList").innerHTML = state.jobs.length ? state.jobs.map((job) => `
    <button type="button" class="job-row ${state.selectedJob === job.id ? "active" : ""}" data-job-id="${job.id}">
      <span><strong>${escapeHtml(job.label)}</strong><small>${escapeHtml(job.created)} · ${escapeHtml(job.id)}</small></span>
      ${badge(labelForStage(job.status), job.status === "completed" ? "ok" : job.status === "failed" ? "danger" : "warn")}
    </button>`).join("") : '<div class="empty-state">还没有控制台任务。</div>';
  const selected = state.jobs.find((job) => job.id === state.selectedJob);
  $("#jobLogTitle").textContent = selected?.label || "选择任务";
  $("#jobLog").textContent = selected?.output || (selected ? `任务状态：${labelForStage(selected.status)}` : "暂无任务输出。");
}

async function loadStatus(showToast = false) {
  $("#refreshButton").disabled = true;
  try {
    state.status = await api("/api/status");
    renderRail();
    renderHome();
    renderScenes();
    if (state.reviews) await loadReviews();
    if (showToast) toast("项目状态已刷新");
  } catch (error) {
    toast(error.message, true);
  } finally {
    $("#refreshButton").disabled = false;
  }
}

document.addEventListener("click", (event) => {
  const moduleButton = event.target.closest("[data-module]");
  if (moduleButton) switchModule(moduleButton.dataset.module);
  const openModule = event.target.closest("[data-open-module]");
  if (openModule) switchModule(openModule.dataset.openModule);
  const sceneItem = event.target.closest("[data-scene-id]");
  if (sceneItem) selectScene(sceneItem.dataset.sceneId);
  const sceneOpen = event.target.closest("[data-scene-open]");
  if (sceneOpen) { selectScene(sceneOpen.dataset.sceneOpen); switchModule("scenes"); }
  const review = event.target.closest("[data-review-id]");
  if (review) { state.selectedReview = review.dataset.reviewId; renderReviews(); }
  const action = event.target.closest("[data-action]");
  if (action) startAction(action.dataset.action);
  const pipelineAction = event.target.closest("[data-pipeline-action]");
  if (pipelineAction && pipelineAction.dataset.pipelineAction !== "init") {
    const actionName = pipelineAction.dataset.pipelineAction;
    const shotId = ["generate_image", "generate_video", "generate_tts", "mix_audio"].includes(actionName) ? state.selectedShot : "";
    startPipelineJob(actionName, shotId);
  }
  const projectOpen = event.target.closest("[data-project-open]");
  if (projectOpen) openProject(projectOpen.dataset.projectOpen);
  const projectRefresh = event.target.closest("[data-projects-refresh]");
  if (projectRefresh) loadProjects();
  const saveAudio = event.target.closest("[data-save-audio-design]");
  if (saveAudio && state.selectedShot && state.localPipeline?.manifest?.project_slug) {
    api("/api/local-pipeline/audio-design", { method: "PUT", body: JSON.stringify({ project_slug: state.localPipeline.manifest.project_slug, shot_id: state.selectedShot, dialogue: $("#selectedDialogue").value }) })
      .then(() => { toast("镜头台词已保存"); loadLocalPipeline(); })
      .catch((error) => toast(error.message, true));
  }
  const pipelineStage = event.target.closest("[data-pipeline-stage]");
  if (pipelineStage && state.localPipeline) {
    state.localPipeline.selectedStage = pipelineStage.dataset.pipelineStage;
    renderPipelineStages(state.localPipeline.manifest);
  }
  const pipelineImport = event.target.closest("[data-pipeline-import]");
  if (pipelineImport) $("#pipelineImportFile").click();
  const pipelineExport = event.target.closest("[data-pipeline-export]");
  if (pipelineExport) exportPipeline();
  const assetFilter = event.target.closest("[data-asset-filter]");
  if (assetFilter && state.localPipeline?.manifest) {
    state.assetFilter = assetFilter.dataset.assetFilter;
    renderPipelineAssets(state.localPipeline.manifest);
  }
  const assetEdit = event.target.closest("[data-asset-edit]");
  if (assetEdit && state.localPipeline?.manifest) {
    state.selectedAsset = assetEdit.dataset.assetEdit;
    renderPipelineAssets(state.localPipeline.manifest);
    $("#pipelineAssetPromptEditor")?.scrollIntoView({ behavior: "smooth", block: "center" });
  }
  const promptReview = event.target.closest("[data-save-prompt-review]");
  if (promptReview) savePromptReview(promptReview.dataset.savePromptReview, promptReview.dataset.reviewStatus);
  const videoMode = event.target.closest("[data-video-mode]");
  if (videoMode) {
    state.videoSettings = { ...(state.videoSettings || {}), mode: videoMode.dataset.videoMode };
    renderVideoSettings();
  }
  const stylePromptStyle = event.target.closest("[data-style-prompt-style]");
  if (stylePromptStyle && state.stylePrompts) {
    captureStylePromptFields();
    state.selectedStylePrompt = stylePromptStyle.dataset.stylePromptStyle;
    renderStylePrompts();
  }
  const pipelineShotAction = event.target.closest("[data-pipeline-shot-action]");
  if (pipelineShotAction) {
    state.selectedShot = pipelineShotAction.dataset.shotId;
    startPipelineJob(pipelineShotAction.dataset.pipelineShotAction, pipelineShotAction.dataset.shotId);
  }
  const pipelineShot = event.target.closest("[data-pipeline-shot-id]");
  if (pipelineShot && state.localPipeline?.manifest) {
    state.selectedShot = pipelineShot.dataset.pipelineShotId;
    renderPipelineShots(state.localPipeline.manifest);
  }
  const mediaTab = event.target.closest("[data-media-tab]");
  if (mediaTab && state.localPipeline?.manifest) {
    state.mediaTab = mediaTab.dataset.mediaTab;
    renderSelectedShot(state.localPipeline.manifest);
  }
  const mobileWorkspaceTab = event.target.closest("[data-mobile-workspace-tab]");
  if (mobileWorkspaceTab) {
    state.mobileWorkspaceTab = mobileWorkspaceTab.dataset.mobileWorkspaceTab;
    renderMobileWorkspaceTab();
  }
  const configDrawerOpen = event.target.closest("[data-config-drawer-open]");
  if (configDrawerOpen) setConfigDrawer(true, configDrawerOpen);
  const configDrawerClose = event.target.closest("[data-config-drawer-close]");
  if (configDrawerClose) setConfigDrawer(false);
  const job = event.target.closest("[data-job-id]");
  if (job) { state.selectedJob = job.dataset.jobId; renderJobs(); }
  const playButton = event.target.closest("[data-frame-play]");
  if (playButton) {
    const player = playButton.closest("[data-frame-player]");
    if (player.dataset.playing === "true") {
      stopFramePlayer(player);
    } else {
      player.dataset.playing = "true";
      playButton.textContent = "暂停";
      const startedAt = performance.now() - Number(player.querySelector("[data-frame-seek]").value) * 1000;
      const timer = setInterval(() => updateFramePlayer(player, (performance.now() - startedAt) / 1000), 500);
      frameTimers.set(player, timer);
    }
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && $("#productionConfigDrawer")?.classList.contains("open")) {
    setConfigDrawer(false);
    return;
  }
  const pipelineShot = event.target.closest("[data-pipeline-shot-id]");
  if (!pipelineShot || !["Enter", " "].includes(event.key) || !state.localPipeline?.manifest) return;
  event.preventDefault();
  state.selectedShot = pipelineShot.dataset.pipelineShotId;
  renderPipelineShots(state.localPipeline.manifest);
});

document.addEventListener("input", (event) => {
  const slider = event.target.closest("[data-frame-seek]");
  if (!slider) return;
  const player = slider.closest("[data-frame-player]");
  stopFramePlayer(player);
  updateFramePlayer(player, slider.value);
});

document.addEventListener("change", (event) => {
  if (["projectCreateContentType", "projectCreatePlanningMode"].includes(event.target.id)) syncPlanningControls("project");
  if (["pipelineContentType", "pipelinePlanningMode"].includes(event.target.id)) syncPlanningControls("pipeline");
  const projectStatus = event.target.closest("[data-project-status]");
  if (projectStatus) updateProjectStatus(projectStatus.dataset.projectStatus, projectStatus.value);
  const assetScope = event.target.closest("[data-asset-scope]");
  if (assetScope) {
    const episode = assetScope.closest(".asset-row")?.querySelector("[data-asset-episode]")?.value || currentPipelineEpisode(state.localPipeline?.manifest);
    updateAssetScope(assetScope.dataset.assetScope, assetScope.value, assetScope.value === "episode" ? episode : "");
  }
  const assetEpisode = event.target.closest("[data-asset-episode]");
  if (assetEpisode) updateAssetScope(assetEpisode.dataset.assetEpisode, "episode", assetEpisode.value);
});

$("#sceneSearch").addEventListener("input", renderSceneList);
$("#sceneFilter").addEventListener("change", renderSceneList);
$("#reviewFilter").addEventListener("change", renderReviews);
$("#pipelineForm").addEventListener("submit", (event) => {
  event.preventDefault();
  startPipelineJob("init");
});
$("#pipelineStyleForm")?.addEventListener("submit", saveProjectStyle);
$("#projectCreateForm")?.addEventListener("submit", createProject);
$("#textSettingsForm")?.addEventListener("submit", saveTextSettings);
$("#stylePromptsForm")?.addEventListener("submit", saveStylePrompts);
$("#resetStylePrompts")?.addEventListener("click", resetStylePrompts);
$("#imageSettingsForm").addEventListener("submit", saveImageSettings);
$("#videoSettingsForm").addEventListener("submit", saveVideoSettings);
$("#audioSettingsForm")?.addEventListener("submit", saveAudioSettings);
$("#pipelineShotFilter").addEventListener("change", () => {
  if (state.localPipeline?.manifest) renderPipelineShots(state.localPipeline.manifest);
});
$("#pipelineUnitFilter").addEventListener("change", (event) => {
  state.selectedProductionUnit = event.target.value;
  const manifest = state.localPipeline?.manifest;
  if (!manifest) return;
  const first = filteredPipelineShots(manifest)[0];
  state.selectedShot = first?.shot_id || null;
  renderPipelineAssets(manifest);
  renderPipelineShots(manifest);
  $("#pipelineUnitContext").textContent = state.selectedProductionUnit ? `${state.selectedProductionUnit} / ${pipelineEpisodeIds(manifest).length}` : `${pipelineEpisodeIds(manifest).length} 个生产单元`;
});
$("#pipelineShotSearch").addEventListener("input", () => {
  if (state.localPipeline?.manifest) renderPipelineShots(state.localPipeline.manifest);
});
$("#pipelineImportFile")?.addEventListener("change", (event) => importPipeline(event.target.files?.[0]));
$("#refreshButton").addEventListener("click", () => loadStatus(true));
$("#refreshJobsButton").addEventListener("click", loadJobs);

async function bootstrap() {
  syncPlanningControls("project");
  syncPlanningControls("pipeline");
  await loadStatus();
  switchModule(state.module);
}

bootstrap();
