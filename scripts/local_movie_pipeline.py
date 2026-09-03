"""Restartable novel-to-local-video movie pipeline.

Image generation uses the configured OpenAI-compatible API. Video generation is
opt-in and refuses to submit to ComfyUI while its queue is busy.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping
from urllib import request

try:
    from image_api_client import ImageAPIError, ImageApiClient
    from style_presets import load_style_prompts, selected_style_preset
    from text_model_client import TextModelClient
    from video_api_client import VideoAPIError, VideoApiClient
except ImportError:  # pragma: no cover - package import
    from .image_api_client import ImageAPIError, ImageApiClient
    from .style_presets import load_style_prompts, selected_style_preset
    from .text_model_client import TextModelClient
    from .video_api_client import VideoAPIError, VideoApiClient


STAGES = (
    "concept",
    "story_bible",
    "content_plan",
    "screenplay",
    "screenplay_import",
    "director_storyboard",
    "episode_outline",
    "scene_table",
    "shot_table",
    "audio_design",
    "asset_catalog",
    "image_prompts",
    "image_generation",
    "video_prompts",
    "model_match",
    "clip_generation",
    "tts_generation",
    "audio_mix",
)
PLAN_STAGES = STAGES[:3]
H3_LENGTH = 243  # 17 * 14 + 5; the raw 10.125-second source for a strict 10-second clip.
FINAL_VIDEO_SECONDS = 10.0
ROOT = Path(__file__).resolve().parents[1]
COMFY_OUTPUT_ROOT = Path(os.getenv("MOVIE_COMFY_OUTPUT_ROOT", r"G:\ComfyUI\output"))
HOST_PROJECT_ROOT = os.getenv("MOVIE_HOST_PROJECT_ROOT", "")
HOST_OUTPUT_ROOT = os.getenv("MOVIE_HOST_OUTPUT_ROOT", "")
IMAGE_API_CONFIG_PATH = Path(__file__).resolve().parents[1] / "config" / "image_api.local.json"
VIDEO_API_CONFIG_PATH = Path(__file__).resolve().parents[1] / "config" / "video_api.local.json"
AUDIO_CONFIG_PATH = Path(__file__).resolve().parents[1] / "config" / "audio.local.json"
TEXT_API_CONFIG_PATH = Path(__file__).resolve().parents[1] / "config" / "text_api.local.json"
STYLE_PROMPTS_CONFIG_PATH = Path(__file__).resolve().parents[1] / "config" / "style_prompts.local.json"


def runtime_path(path_value: str | Path) -> Path:
    path = Path(path_value)
    if path.exists():
        return path
    text = str(path_value).replace("\\", "/")
    for host_root, runtime_root in ((HOST_PROJECT_ROOT, ROOT), (HOST_OUTPUT_ROOT, COMFY_OUTPUT_ROOT)):
        normalized = str(host_root or "").rstrip("/\\").replace("\\", "/")
        if normalized and (text.casefold() == normalized.casefold() or text.casefold().startswith(normalized.casefold() + "/")):
            return runtime_root / Path(text[len(normalized) :].lstrip("/"))
    return path


def _timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def slugify(value: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9]+", "-", str(value).strip().lower()).strip("-")
    return value or "untitled-movie"


def extract_chapters(text: str) -> list[dict[str, Any]]:
    """Extract markdown-like chapter headings, retaining plain text novels."""
    matches = list(re.finditer(r"(?im)^\s*(?:chapter\s+[^\n]*|第\s*[0-9一二三四五六七八九十百千万]+\s*章[^\n]*)\s*$", text))
    if not matches:
        return [{"chapter_id": "ch01", "title": "Opening", "text": text.strip()}]
    chapters = []
    for index, match in enumerate(matches, 1):
        end = matches[index].start() if index < len(matches) else len(text)
        title = re.sub(r"\s+", " ", match.group(0).strip())
        chapters.append({"chapter_id": f"ch{index:02d}", "title": title, "text": text[match.end() : end].strip()})
    return chapters


def read_novel_text(path: str | Path) -> str:
    data = Path(path).read_bytes()
    for encoding in ("utf-8-sig", "gb18030"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    raise UnicodeDecodeError("utf-8", data, 0, 1, "novel is not UTF-8 or GB18030 text")


def stable_image_prompt(shot: Mapping[str, Any]) -> str:
    description = str(shot.get("prompt") or shot.get("action") or "The main subject in the planned scene").strip()
    aspect_ratio = str(shot.get("aspect_ratio") or "16:9")
    visual_style = str(shot.get("visual_style") or "真人影视").strip()
    preset = shot.get("style_preset_snapshot")
    preset = dict(preset) if isinstance(preset, Mapping) else selected_style_preset(visual_style)
    style_prompt = str(preset.get("image_prompt") or "").strip()
    if style_prompt and description.startswith(style_prompt) and "Scene:" in description:
        return description
    return (
        f"{style_prompt} Create a cinematic {aspect_ratio} film still. "
        f"Primary production medium: {visual_style}. "
        "Show exactly one clearly visible adult protagonist, with a stable symmetrical face, natural eyes, "
        "anatomically correct body and hands, and wardrobe consistent with the approved story bible. "
        "Use a single coherent pose and a clean silhouette. No other people, duplicate person, crowd, child, "
        "extra limbs, fused fingers, distorted face, text, logo, or watermark. "
        "The character must be suitable as an identity reference frame for image-to-video. "
        f"Scene: {description}"
    )


def stable_video_prompt(shot: Mapping[str, Any]) -> str:
    action = str(shot.get("prompt") or shot.get("action") or "Subtle natural breathing").strip()
    visual_style = str(shot.get("visual_style") or "真人影视").strip()
    preset = shot.get("style_preset_snapshot")
    preset = dict(preset) if isinstance(preset, Mapping) else selected_style_preset(visual_style)
    style_prompt = str(preset.get("video_prompt") or "").strip()
    if action.startswith("One continuous 10-second cinematic shot at normal real-time speed."):
        return action
    if action.startswith("One continuous 10-second cinematic shot.") and "Shot direction:" in action:
        action = action.split("Shot direction:", 1)[1].strip()
    return (
        f"One continuous 10-second cinematic shot at normal real-time speed. {style_prompt} Primary production medium: {visual_style}. Keep exactly the same single adult "
        "character identity, face, hairstyle, clothing, anatomy, and body proportions throughout. Execute the "
        "described action with clear purposeful movement at natural human speed, and keep hair, clothing, props, "
        "water, foliage, and other environmental motion physically continuous. Use a smooth steady camera move at "
        "normal cinematic speed when appropriate. Do not stretch one small action across the full ten seconds. "
        "No slow motion, prolonged pause, frozen pose, speed ramp, or looping action. No face change, morphing, "
        "body deformation, extra limbs, fused hands, duplicate person, new person, scene transition, camera cut, text, "
        "logo, or watermark. "
        f"Shot direction: {action}"
    )


def _item_ids(items: list[dict[str, Any]], key: str) -> list[str]:
    return [str(item.get(key)) for item in items if item.get(key)]


def _prompt_context(shot: Mapping[str, Any], story_bible: list[dict[str, Any]], assets: list[dict[str, Any]]) -> dict[str, Any]:
    episode_id = f"EP{int(shot.get('episode') or 1):02d}"
    relevant_assets = [item for item in assets if item.get("scope") == "shared" or item.get("episode_id") == episode_id]
    return {
        "story_bible_item_ids": _item_ids(story_bible, "item_id"),
        "asset_ids": _item_ids(relevant_assets, "asset_id"),
        "scene_id": str(shot.get("scene_id") or ""),
        "shot_id": str(shot.get("shot_id") or ""),
    }


def _prompt_facts(story_bible: list[dict[str, Any]], assets: list[dict[str, Any]], shot: Mapping[str, Any]) -> str:
    context = _prompt_context(shot, story_bible, assets)
    story_ids = set(context["story_bible_item_ids"])
    asset_ids = set(context["asset_ids"])
    story = "; ".join(str(item.get("visual_prompt") or item.get("description") or "").strip() for item in story_bible if str(item.get("item_id") or "") in story_ids)
    asset = "; ".join(str(item.get("visual_prompt") or item.get("description") or "").strip() for item in assets if str(item.get("asset_id") or "") in asset_ids)
    action = str(shot.get("action") or "").strip()
    return " ".join(part for part in (story, asset, action) if part)


def _prompt_record(base_prompt: str, draft_prompt: str, settings: Mapping[str, Any], context_snapshot: Mapping[str, Any], *, negative_prompt: str = "") -> dict[str, Any]:
    return {
        "base_prompt": base_prompt,
        "draft_prompt": draft_prompt,
        "final_prompt": draft_prompt,
        "prompt": draft_prompt,
        "negative_prompt": negative_prompt,
        "review_status": "pending_review",
        "prompt_revision": 0,
        "style_preset_snapshot": dict(settings.get("style_prompt_snapshot") or {}),
        "context_snapshot": dict(context_snapshot),
    }


def _normalize_prompt_record(item: Mapping[str, Any], base: Mapping[str, Any]) -> dict[str, Any]:
    merged = {**base, **item}
    draft = str(item.get("draft_prompt") or item.get("prompt") or base.get("draft_prompt") or base.get("prompt") or "").strip()
    merged.update(
        {
            "base_prompt": str(base.get("base_prompt") or "").strip(),
            "draft_prompt": draft,
            "final_prompt": draft,
            "prompt": draft,
            "review_status": "pending_review",
            "prompt_revision": 0,
            "style_preset_snapshot": dict(base.get("style_preset_snapshot") or {}),
            "context_snapshot": dict(base.get("context_snapshot") or {}),
        }
    )
    return merged


def generation_prompt(record: Mapping[str, Any], fallback: str, *, require_approved: bool = True) -> str:
    modern = "review_status" in record or "final_prompt" in record
    if modern:
        if require_approved and record.get("review_status") != "approved":
            raise ValueError("prompt_not_approved")
        final_prompt = str(record.get("final_prompt") or "").strip()
        if not final_prompt:
            raise ValueError("prompt_final_empty")
        return final_prompt
    return fallback


def _base_manifest(slug: str, stage: str, source_path: str, items: list[dict[str, Any]], *, source: str = "fallback", model: str | None = None, reason: str | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "schema_version": "1.0",
        "project_slug": slug,
        "stage": stage,
        "status": "draft" if source == "fallback" else "needs_review",
        "source": source,
        "source_path": source_path,
        "model": model,
        "created_at": _timestamp(),
        "items": items,
    }
    if reason:
        result["reason"] = reason
    return result


def _estimated_unit_count(chapters: list[dict[str, Any]], target_duration: int) -> tuple[int, str]:
    character_count = sum(len(re.sub(r"\s+", "", str(chapter.get("text") or ""))) for chapter in chapters)
    target_characters = max(800, target_duration * 5)
    count = max(2, min(100, (character_count + target_characters - 1) // target_characters))
    return count, f"fallback estimate: {character_count} source characters, {target_duration}s target duration and chapter boundaries"


def _production_units(
    chapters: list[dict[str, Any]],
    *,
    content_type: str,
    planning_mode: str,
    target_episode_count: int | None,
    target_duration: int,
) -> tuple[list[dict[str, Any]], str]:
    if content_type == "single":
        count, basis = 1, "single video creates one production unit"
    elif planning_mode == "fixed":
        count, basis = int(target_episode_count or 2), f"fixed by user at {int(target_episode_count or 2)} episodes"
    else:
        count, basis = _estimated_unit_count(chapters, target_duration)
    source = chapters or [{"chapter_id": "ch01", "title": "Opening", "text": ""}]
    units = []
    for index in range(count):
        start = index * len(source) // count
        end = max(start + 1, (index + 1) * len(source) // count)
        selected = source[start:min(end, len(source))] or [source[min(start, len(source) - 1)]]
        summary = " ".join(str(item.get("text") or "") for item in selected).strip()[:500]
        units.append(
            {
                "unit_id": f"unit-{index + 1:02d}",
                "episode_id": f"EP{index + 1:02d}",
                "episode": index + 1,
                "title": str(selected[0].get("title") or f"Production unit {index + 1}"),
                "source_chapter_ids": [str(item.get("chapter_id") or "") for item in selected],
                "summary": summary,
                "target_duration_seconds": target_duration,
            }
        )
    return units, basis


def _fallback_story_bible(chapters: list[dict[str, Any]], visual_style: str) -> list[dict[str, Any]]:
    first = chapters[0] if chapters else {"text": ""}
    return [
        {"item_id": "setting-001", "item_type": "style_rule", "name": "视频主体风格", "description": visual_style or "待用户确定视频主体风格。", "visual_prompt": visual_style or "待确定", "importance": "core", "review_status": "pending_review"},
        {"item_id": "setting-002", "item_type": "world_rule", "name": "世界观基准", "description": "根据原文建立时代、地理、力量规则与禁用元素的项目级约束。", "visual_prompt": "继承原文时代感、地理区域和世界规则", "importance": "core", "review_status": "pending_review", "source_evidence": [{"type": "chapter", "text": str(first.get("text") or "")[:280]}]},
        {"item_id": "setting-003", "item_type": "character", "name": "主要角色候选", "description": "从原文提取的主要角色候选，需确认身份关系和视觉特征。", "visual_prompt": "保持角色脸部、发型、服装和体型跨镜头一致", "importance": "core", "review_status": "pending_review"},
        {"item_id": "setting-004", "item_type": "location", "name": "关键场景候选", "description": "从原文提取的关键场景候选，需确认空间和时间连续性。", "visual_prompt": "保持场景空间结构、光线和时代元素一致", "importance": "high", "review_status": "pending_review"},
        {"item_id": "setting-005", "item_type": "prop", "name": "关键道具候选", "description": "从原文提取的关键道具候选，需确认外观和叙事作用。", "visual_prompt": "保持道具形态、材质和标志性细节一致", "importance": "normal", "review_status": "pending_review"},
    ]


def _fallback_items(
    stage: str,
    slug: str,
    chapters: list[dict[str, Any]],
    production_units: list[dict[str, Any]] | None = None,
    settings: Mapping[str, Any] | None = None,
    story_bible: list[dict[str, Any]] | None = None,
    asset_catalog: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    title = slug.replace("-", " ").title()
    first = chapters[0] if chapters else {"chapter_id": "ch01", "title": "Opening", "text": ""}
    if stage == "concept":
        return [{"concept_id": "concept-001", "title": title, "logline": first["text"][:280], "theme": "human choices under pressure"}]
    if stage == "content_plan":
        return list(production_units or [])
    if stage == "story_bible":
        return list(story_bible or _fallback_story_bible(chapters, str((settings or {}).get("visual_style") or "")))
    settings = settings or {}
    units = production_units or [{"episode": 1, "episode_id": "EP01", "title": title, "source_chapter_ids": [item["chapter_id"] for item in chapters], "summary": first["text"][:500]}]
    chapter_map = {str(chapter.get("chapter_id")): chapter for chapter in chapters}
    scenes = []
    for unit in units:
        episode = int(unit.get("episode") or 1)
        selected = [chapter_map[item] for item in unit.get("source_chapter_ids", []) if item in chapter_map]
        if not selected:
            selected = [{"chapter_id": "ch01", "text": str(unit.get("summary") or "")}]
        for scene_number, chapter in enumerate(selected, 1):
            scenes.append({"scene_id": f"ep{episode:02d}-sc{scene_number:02d}", "episode": episode, "chapter_id": chapter["chapter_id"], "summary": str(chapter.get("text") or "")[:500], "location": "unspecified", "time": "unspecified"})
    if stage in {"screenplay", "screenplay_import", "director_storyboard", "scene_table", "episode_outline"}:
        if stage != "episode_outline":
            return scenes
        return [{**unit, "scene_ids": [scene["scene_id"] for scene in scenes if scene["episode"] == int(unit.get("episode") or 1)]} for unit in units]
    shots = []
    for scene in scenes:
        for number in (1, 2):
            episode = int(scene["episode"])
            shot_id = f"{slug}_ep{episode:02d}_sc{scene['scene_id'][-2:]}_sh{number:02d}"
            shots.append({"shot_id": shot_id, "scene_id": scene["scene_id"], "episode": episode, "duration_seconds": 10, "framing": "wide" if number == 1 else "medium", "action": scene["summary"][:240], "aspect_ratio": settings.get("aspect_ratio", "16:9"), "visual_style": settings.get("visual_style", "真人影视"), "style_preset_snapshot": dict(settings["style_prompt_snapshot"])})
    if stage == "shot_table":
        return shots
    if stage == "audio_design":
        return [{"shot_id": s["shot_id"], "dialogue": "", "narration": "", "voice": "zh-CN-YunxiNeural", "rate": "+0%", "pitch": "+0Hz"} for s in shots]
    if stage == "asset_catalog":
        bible_items = story_bible or []
        assets = []
        for index, item in enumerate(bible_items, 1):
            if item.get("item_type") not in {"character", "location", "prop", "faction"}:
                continue
            asset = {"asset_id": f"asset-{item.get('item_type')}-{index:03d}", "kind": item.get("item_type"), "name": item.get("name") or "未命名设定", "scope": "shared", "episode_id": "", "status": "placeholder", "description": item.get("description", ""), "visual_prompt": item.get("visual_prompt", "")}
            facts = str(asset.get("visual_prompt") or asset.get("description") or asset["name"])
            base_prompt = f"{settings['style_prompt_snapshot']['image_prompt']} Project asset facts: {facts}"
            asset.update(_prompt_record(base_prompt, f"{base_prompt} Create a clean reusable reference image for {asset['name']}.", settings, {"story_bible_item_ids": _item_ids(bible_items, "item_id"), "asset_ids": [asset["asset_id"]], "scene_id": "", "shot_id": ""}, negative_prompt=str(settings["style_prompt_snapshot"].get("negative_prompt") or "")))
            assets.append(asset)
        if assets:
            return assets
        asset = {"asset_id": "asset-character-001", "kind": "character", "name": "protagonist", "scope": "shared", "episode_id": "", "status": "placeholder"}
        base_prompt = f"{settings['style_prompt_snapshot']['image_prompt']} Project asset facts: protagonist"
        asset.update(_prompt_record(base_prompt, f"{base_prompt} Create a clean reusable character reference image.", settings, {"story_bible_item_ids": _item_ids(bible_items, "item_id"), "asset_ids": [asset["asset_id"]], "scene_id": "", "shot_id": ""}, negative_prompt=str(settings["style_prompt_snapshot"].get("negative_prompt") or "")))
        return [asset]
    if stage == "image_prompts":
        result = []
        for shot in shots:
            facts = _prompt_facts(story_bible or [], asset_catalog or [], shot)
            base_prompt = stable_image_prompt({**shot, "prompt": facts})
            result.append({"shot_id": shot["shot_id"], "visual_style": shot.get("visual_style", "真人影视"), **_prompt_record(base_prompt, base_prompt, settings, _prompt_context(shot, story_bible or [], asset_catalog or []), negative_prompt=str(settings["style_prompt_snapshot"].get("negative_prompt") or ""))})
        return result
    if stage == "image_generation":
        return [{"shot_id": s["shot_id"], "status": "waiting", "image_path": None, "workflow_path": None} for s in shots]
    if stage == "video_prompts":
        result = []
        for shot in shots:
            facts = _prompt_facts(story_bible or [], asset_catalog or [], shot)
            base_prompt = stable_video_prompt({**shot, "prompt": facts})
            result.append({"shot_id": shot["shot_id"], "visual_style": shot.get("visual_style", "真人影视"), "fps": 24, **_prompt_record(base_prompt, base_prompt, settings, _prompt_context(shot, story_bible or [], asset_catalog or []), negative_prompt=str(settings["style_prompt_snapshot"].get("negative_prompt") or ""))})
        return result
    if stage == "model_match":
        return [{"shot_id": s["shot_id"], "image_model": "gpt-image-2-api", "video_model": "minimax-h3-local", "quantization": "W4A8", "lora": "PDD LoRA", "steps": 8} for s in shots]
    if stage == "clip_generation":
        return [{"shot_id": s["shot_id"], "status": "waiting", "video_path": None, "workflow_path": None} for s in shots]
    if stage == "tts_generation":
        return [{"shot_id": s["shot_id"], "status": "waiting", "audio_path": None} for s in shots]
    if stage == "audio_mix":
        return [{"shot_id": s["shot_id"], "status": "waiting", "video_with_audio_path": None} for s in shots]
    return []


def _ai_items(stage: str, fallback: list[dict[str, Any]], client: TextModelClient | None, context: str, *, variable_unit_count: bool = False) -> tuple[list[dict[str, Any]], str, str | None, str | None]:
    if client is None or not client.configured:
        return fallback, "fallback", None, "not_configured"
    try:
        schema = {"items": ["stage-specific objects"]}
        instruction = f"Create the {stage} stage for this movie project. Return an object with an items array."
        if stage == "story_bible":
            instruction += " Extract project-level facts from the full source: world rules, core characters, key locations, props, factions and visual rules. Treat the confirmed visual_style setting only as the primary production medium (live action, 2D animation, or 3D animation); derive color, camera, costume, and art-direction details from the source instead of assuming the user supplied them. Each item needs item_type, name, description, visual_prompt, importance and source_evidence. Do not invent unsupported story facts."
            schema = {"items": [{"item_type": "character|location|prop|faction|world_rule|style_rule", "name": "setting name", "description": "source-grounded description", "visual_prompt": "stable visual traits", "importance": "core|high|normal", "source_evidence": [{"type": "chapter", "text": "evidence"}]}]}
        if stage == "content_plan":
            instruction += " Split by narrative beats and the requested duration. Each production unit needs unit_id, episode_id, episode, title, source_chapter_ids, summary and target_duration_seconds."
            schema = {"items": [{"unit_id": "unit-01", "episode_id": "EP01", "episode": 1, "title": "title", "source_chapter_ids": ["ch01"], "summary": "story beat", "target_duration_seconds": 120}]}
        if stage == "asset_catalog":
            instruction += " Each asset must include scope shared or episode. Shared assets are reused across episodes; episode assets must include an episode_id such as EP01. Use the supplied base prompt and facts to write a complete media-ready draft_prompt for its reference image."
            schema = {"items": [{"asset_id": "asset-001", "kind": "character|location|prop", "name": "asset name", "scope": "shared|episode", "episode_id": "EP01 or empty for shared", "description": "story fact", "visual_prompt": "stable visual facts", "draft_prompt": "complete reference image prompt"}]}
        if stage == "image_prompts":
            instruction += " For every supplied shot, use its base_prompt, story bible and relevant assets to write a complete image-generation draft_prompt. Preserve shot_id and do not approve the prompt."
            schema = {"items": [{"shot_id": "existing shot id", "draft_prompt": "complete image prompt", "negative_prompt": "image exclusions"}]}
        if stage == "video_prompts":
            instruction += " For every supplied shot, use its base_prompt, story bible and relevant assets to write a complete ten-second video-generation draft_prompt. Preserve shot_id and do not approve the prompt."
            schema = {"items": [{"shot_id": "existing shot id", "draft_prompt": "complete video prompt", "negative_prompt": "video exclusions"}]}
        payload, metadata = client.request_json(f"{instruction}\n{context[:16000]}", schema)
        items = payload.get("items") if isinstance(payload, dict) else payload
        if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
            raise ValueError("expected a JSON object containing an items array")
        items = _normalize_items(stage, items, fallback, variable_unit_count=variable_unit_count)
        return items, "ai", metadata.get("model"), None
    except Exception as exc:
        return fallback, "fallback", None, "ai_error: " + str(exc)[:180]


def _normalize_items(stage: str, items: list[dict[str, Any]], fallback: list[dict[str, Any]], *, variable_unit_count: bool = False) -> list[dict[str, Any]]:
    """Preserve deterministic shot identity when a model omits or invents IDs."""
    shot_stages = {"shot_table", "audio_design", "image_prompts", "image_generation", "video_prompts", "model_match", "clip_generation", "tts_generation", "audio_mix"}
    if stage == "asset_catalog":
        normalized = []
        for index, item in enumerate(items, 1):
            episode_value = item.get("episode_id") or item.get("episode") or ""
            episode_text = str(episode_value).strip().upper().replace("_", "").replace("-", "")
            episode_match = re.fullmatch(r"(?:EP)?(\d{1,4})", episode_text)
            episode_id = f"EP{int(episode_match.group(1)):02d}" if episode_match else ""
            scope = str(item.get("scope") or ("episode" if episode_id else "shared")).strip().lower()
            if scope not in {"shared", "episode"}:
                scope = "episode" if episode_id else "shared"
            if scope == "episode" and not re.fullmatch(r"EP\d{2,4}", episode_id):
                episode_id = "EP01"
            base = fallback[index - 1] if index <= len(fallback) else (fallback[-1] if fallback else {})
            normalized.append(_normalize_prompt_record({**item, "asset_id": str(item.get("asset_id") or f"asset-{index:03d}"), "scope": scope, "episode_id": episode_id if scope == "episode" else ""}, base))
        return normalized
    if stage == "content_plan":
        if not items or len(items) > 100 or (variable_unit_count and len(items) < 2):
            raise ValueError("AI production unit count is outside the supported range")
        if not variable_unit_count and len(items) != len(fallback):
            raise ValueError("AI production unit count does not match the requested plan")
        normalized = []
        for index, item in enumerate(items):
            base = fallback[index] if index < len(fallback) else fallback[-1]
            identity = {"unit_id": f"unit-{index + 1:02d}", "episode_id": f"EP{index + 1:02d}", "episode": index + 1}
            normalized.append({**base, **item, "unit_id": base["unit_id"], "episode_id": base["episode_id"], "episode": base["episode"], "source_chapter_ids": item.get("source_chapter_ids") or base["source_chapter_ids"], "target_duration_seconds": base["target_duration_seconds"]})
            normalized[-1].update(identity)
        return normalized
    if stage == "story_bible":
        normalized = []
        allowed = {"character", "location", "prop", "faction", "world_rule", "style_rule"}
        for index, item in enumerate(items, 1):
            item_type = str(item.get("item_type") or item.get("kind") or "world_rule").strip().lower()
            if item_type not in allowed:
                item_type = "world_rule"
            normalized.append({
                **item,
                "item_id": str(item.get("item_id") or f"setting-{index:03d}"),
                "item_type": item_type,
                "name": str(item.get("name") or f"项目设定 {index}"),
                "description": str(item.get("description") or "待审核的项目级设定"),
                "visual_prompt": str(item.get("visual_prompt") or ""),
                "review_status": str(item.get("review_status") or "pending_review"),
            })
        if not normalized:
            raise ValueError("story bible is empty")
        return normalized
    if stage not in shot_stages:
        return items
    expected = [str(item.get("shot_id")) for item in fallback]
    if len(items) != len(expected):
        raise ValueError("AI shot count does not match local shot table")
    normalized = []
    for index, item in enumerate(items):
        given = item.get("shot_id")
        if given is not None and str(given) not in expected:
            raise ValueError("AI returned an incompatible shot_id")
        base = fallback[index]
        normalized_item = {**base, **item, "shot_id": str(given) if given is not None else expected[index]}
        if stage in {"image_prompts", "video_prompts"}:
            if not base.get("base_prompt"):
                prompt_builder = stable_image_prompt if stage == "image_prompts" else stable_video_prompt
                base = {**base, "base_prompt": prompt_builder(base), "draft_prompt": base.get("prompt") or "", "context_snapshot": {}}
            normalized_item = _normalize_prompt_record(item, base)
            normalized_item["shot_id"] = str(given) if given is not None else expected[index]
            normalized_item["negative_prompt"] = str(item.get("negative_prompt") or base.get("negative_prompt") or "")
        normalized.append(normalized_item)
    return normalized


def _limit_per_unit(items: list[dict[str, Any]], max_shots: int | None) -> list[dict[str, Any]]:
    if not max_shots:
        return items
    counts: dict[int, int] = {}
    limited = []
    for item in items:
        episode = int(item.get("episode") or 1)
        counts[episode] = counts.get(episode, 0) + 1
        if counts[episode] <= max(1, max_shots):
            limited.append(item)
    return limited


def _write_stage(project_dir: Path, index: dict[str, Any], stage: str, manifest: dict[str, Any]) -> None:
    path = project_dir / f"{stage}.json"
    path.write_text(json.dumps(manifest, ensure_ascii=True, indent=2), encoding="utf-8")
    index["stages"][stage] = {"path": str(path), "status": manifest["status"], "source": manifest["source"], "item_count": len(manifest.get("items") or [])}


def build_pipeline(
    novel_path: str | Path,
    *,
    manifests_root: str | Path = "manifests",
    slug: str | None = None,
    project_title: str | None = None,
    max_shots: int | None = None,
    client: TextModelClient | None = None,
    source_type: str = "novel",
    content_type: str = "single",
    planning_mode: str = "auto",
    target_episode_count: int | None = None,
    target_unit_duration_seconds: int = 600,
    aspect_ratio: str = "16:9",
    visual_style: str = "真人影视",
    style_status: str = "confirmed",
    plan_only: bool = False,
    style_presets: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    novel = Path(novel_path)
    text = read_novel_text(novel)
    project_slug = slugify(slug or novel.stem)
    project_dir = Path(manifests_root) / "local_projects" / project_slug
    project_dir.mkdir(parents=True, exist_ok=True)
    chapters = extract_chapters(text)
    if content_type == "single":
        target_episode_count = 1
    production_units, estimate_basis = _production_units(chapters, content_type=content_type, planning_mode=planning_mode, target_episode_count=target_episode_count, target_duration=target_unit_duration_seconds)
    style_prompt_snapshot = selected_style_preset(visual_style, style_presets)
    settings = {"source_type": source_type, "content_type": content_type, "planning_mode": planning_mode, "target_episode_count": target_episode_count, "target_unit_duration_seconds": target_unit_duration_seconds, "aspect_ratio": aspect_ratio, "visual_style": visual_style, "style_status": style_status, "style_prompt_snapshot": style_prompt_snapshot}
    stage_outputs: dict[str, list[dict[str, Any]]] = {}
    index: dict[str, Any] = {"schema_version": "1.1", "project_slug": project_slug, "project_title": project_title or project_slug.replace("-", " ").title(), "novel_path": str(novel), "source_path": str(novel), **settings, "source": "fallback", "created_at": _timestamp(), "status": "draft", "current_stage": "content_plan" if plan_only else "clip_generation", "planning_status": "pending_confirmation" if plan_only else "confirmed", "text_model_configured": bool(client and client.configured), "max_shots": max_shots, "stages": {}}
    story_bible: list[dict[str, Any]] = []
    asset_catalog: list[dict[str, Any]] = []
    for stage in PLAN_STAGES if plan_only else STAGES:
        fallback = _fallback_items(stage, project_slug, chapters, production_units, settings, story_bible, asset_catalog)
        if max_shots and stage in {"shot_table", "audio_design", "image_prompts", "image_generation", "video_prompts", "model_match", "clip_generation", "tts_generation", "audio_mix"}:
            fallback = _limit_per_unit(fallback, max_shots)
        if stage in {"image_generation", "clip_generation", "tts_generation", "audio_mix"}:
            manager = "managed_by_local_comfyui" if stage in {"image_generation", "clip_generation"} else "managed_by_optional_audio_module"
            items, source, model, reason = fallback, "fallback", None, manager
        else:
            context = json.dumps({"project_settings": settings, "story_bible": story_bible, "content_plan": production_units, "asset_catalog": asset_catalog, "shot_table": stage_outputs.get("shot_table", []), "stage_input": fallback, "source_text": text[:12000]}, ensure_ascii=True)
            items, source, model, reason = _ai_items(stage, fallback, client, context, variable_unit_count=stage == "content_plan" and content_type == "series" and planning_mode == "auto")
        if stage == "content_plan":
            production_units = items
        if stage == "story_bible":
            story_bible = items
        if stage == "asset_catalog":
            asset_catalog = items
        stage_outputs[stage] = items
        manifest = _base_manifest(project_slug, stage, str(novel), items, source=source, model=model, reason=reason)
        if stage == "story_bible":
            manifest.update({"style_status": style_status, "confirmed": False})
        if stage == "content_plan":
            manifest.update({**settings, "estimated_basis": "AI narrative beat and target-duration analysis" if source == "ai" else estimate_basis, "estimated_episode_count": len(items), "confirmed": not plan_only})
        _write_stage(project_dir, index, stage, manifest)
        if stage == "shot_table":
            index["shots"] = items
    pipeline_path = project_dir / "pipeline.json"
    index["pipeline_path"] = str(pipeline_path)
    pipeline_path.write_text(json.dumps(index, ensure_ascii=True, indent=2), encoding="utf-8")
    return index


def confirm_pipeline_plan(pipeline: str | Path, *, client: TextModelClient | None = None) -> dict[str, Any]:
    pipeline_path = runtime_path(pipeline)
    index = load_json(pipeline_path)
    project_dir = pipeline_path.parent
    plan_entry = index.get("stages", {}).get("content_plan", {})
    plan_path = runtime_path(plan_entry.get("path") or project_dir / "content_plan.json")
    plan = load_json(plan_path)
    production_units = plan.get("items") if isinstance(plan.get("items"), list) else []
    if not production_units:
        raise ValueError("content plan has no production units")
    source_path = index.get("source_path") or index.get("novel_path")
    text = read_novel_text(runtime_path(source_path))
    chapters = extract_chapters(text)
    settings = {key: index.get(key) for key in ("source_type", "content_type", "planning_mode", "target_episode_count", "target_unit_duration_seconds", "aspect_ratio", "visual_style", "style_prompt_snapshot")}
    if not isinstance(settings.get("style_prompt_snapshot"), Mapping):
        settings["style_prompt_snapshot"] = selected_style_preset(str(settings.get("visual_style") or "真人影视"))
    story_entry = index.get("stages", {}).get("story_bible", {})
    story_path = runtime_path(story_entry.get("path") or project_dir / "story_bible.json")
    story_manifest = load_json(story_path)
    story_bible = story_manifest.get("items") if isinstance(story_manifest.get("items"), list) else []
    stage_outputs: dict[str, list[dict[str, Any]]] = {"story_bible": story_bible, "content_plan": production_units}
    asset_catalog: list[dict[str, Any]] = []
    max_shots = index.get("max_shots")
    for stage in STAGES[len(PLAN_STAGES):]:
        fallback = _fallback_items(stage, index["project_slug"], chapters, production_units, settings, story_bible, asset_catalog)
        if stage in {"shot_table", "audio_design", "image_prompts", "image_generation", "video_prompts", "model_match", "clip_generation", "tts_generation", "audio_mix"}:
            fallback = _limit_per_unit(fallback, max_shots)
        if stage in {"image_generation", "clip_generation", "tts_generation", "audio_mix"}:
            manager = "managed_by_local_comfyui" if stage in {"image_generation", "clip_generation"} else "managed_by_optional_audio_module"
            items, source, model, reason = fallback, "fallback", None, manager
        else:
            context = json.dumps({"project_settings": settings, "story_bible": story_bible, "content_plan": production_units, "asset_catalog": asset_catalog, "shot_table": stage_outputs.get("shot_table", []), "stage_input": fallback, "source_text": text[:12000]}, ensure_ascii=True)
            items, source, model, reason = _ai_items(stage, fallback, client, context)
        if stage == "asset_catalog":
            asset_catalog = items
        stage_outputs[stage] = items
        manifest = _base_manifest(index["project_slug"], stage, str(source_path), items, source=source, model=model, reason=reason)
        _write_stage(project_dir, index, stage, manifest)
        if stage == "shot_table":
            index["shots"] = items
    plan["confirmed"] = True
    plan["confirmed_at"] = _timestamp()
    plan["status"] = "approved"
    plan_path.write_text(json.dumps(plan, ensure_ascii=True, indent=2), encoding="utf-8")
    index["stages"]["story_bible"]["status"] = "approved"
    index["stages"]["content_plan"]["status"] = "approved"
    index["planning_status"] = "confirmed"
    index["current_stage"] = "clip_generation"
    index["updated_at"] = _timestamp()
    pipeline_path.write_text(json.dumps(index, ensure_ascii=True, indent=2), encoding="utf-8")
    return index


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(runtime_path(path).read_text(encoding="utf-8"))


def _pipeline_data(value: str | Path | Mapping[str, Any]) -> dict[str, Any]:
    return load_json(value) if isinstance(value, (str, Path)) else dict(value)


def build_sd15_image_workflow(shot: Mapping[str, Any], *, prompt: str | None = None, checkpoint: str = "v1-5-pruned-emaonly.safetensors") -> dict[str, Any]:
    shot_id = str(shot.get("shot_id", "shot"))
    return {"client_id": "local-movie-pipeline", "metadata": {"quantization": "W4A8", "lora": "PDD LoRA", "steps": 8, "fps": 24, "resolution": [736, 416]}, "prompt": {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": checkpoint}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt or shot.get("prompt", "cinematic storyboard frame"), "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": shot.get("negative_prompt", "text, watermark, logo"), "clip": ["1", 1]}},
        "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 736, "height": 416, "batch_size": 1}},
        "5": {"class_type": "KSampler", "inputs": {"model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0], "seed": 0, "steps": 20, "cfg": 7.0, "sampler_name": "euler", "scheduler": "normal", "denoise": 1.0}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
        "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": f"local_projects/{shot_id}"}},
    }}


def build_image_api_request(shot: Mapping[str, Any], *, prompt: str | None = None) -> dict[str, Any]:
    return {
        "provider": "gpt-image-api",
        "config_path": str(IMAGE_API_CONFIG_PATH),
        "prompt": prompt if prompt is not None else stable_image_prompt(shot),
        "output": str(COMFY_OUTPUT_ROOT / "local_projects" / f"{shot.get('shot_id', 'shot')}_gpt_image.png"),
    }


def valid_h3_length(length: int) -> bool:
    return isinstance(length, int) and 124 <= length <= 362 and (length - 5) % 17 == 0


def comfy_output_annotation(path_value: str | None, shot_id: str) -> str:
    if path_value:
        path = Path(str(path_value))
        try:
            relative = path.resolve().relative_to(COMFY_OUTPUT_ROOT.resolve())
            return relative.as_posix() + " [output]"
        except (OSError, ValueError):
            text = str(path_value).replace("\\", "/")
            if text.endswith(" [output]"):
                return text
    return f"local_projects/{shot_id}_00001_.png [output]"


def build_minimax_h3_workflow(shot: Mapping[str, Any], *, first_frame: str | None = None, prompt: str | None = None, length: int = H3_LENGTH) -> dict[str, Any]:
    if not valid_h3_length(length):
        raise ValueError("MiniMax H3 length must be 124-362 frames and satisfy 17k+5")
    shot_id = str(shot.get("shot_id", "shot"))
    frame_input = first_frame or shot.get("image_input") or comfy_output_annotation(shot.get("image_path"), shot_id)
    return {"client_id": "local-movie-pipeline", "metadata": {"quantization": "W4A8", "lora": "PDD LoRA", "steps": 8, "fps": 24, "resolution": [736, 416], "raw_frames": length, "duration_seconds": FINAL_VIDEO_SECONDS}, "prompt": {
        "1": {"class_type": "LoadImageOutput", "inputs": {"image": frame_input}},
        "2": {"class_type": "UNETLoader", "inputs": {"unet_name": "minimax_h3_fl2va_pruned_w4a8_mixed.safetensors", "weight_dtype": "default"}},
        "3": {"class_type": "LoraLoaderModelOnly", "inputs": {"model": ["2", 0], "lora_name": "MiniMax-H3-FL2VA-Acc-8Step_pruned_comfy.safetensors", "strength_model": 1.0}},
        "4": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors", "type": "minimax", "device": "cpu"}},
        "5": {"class_type": "VAELoader", "inputs": {"vae_name": "minimax_h3_video_vae_int8_convrot.safetensors"}},
        "6": {"class_type": "VAELoader", "inputs": {"vae_name": "minimax_h3_audio_vae_fp32.safetensors"}},
        "7": {"class_type": "MiniMaxH3ImageToVideo", "inputs": {"clip": ["4", 0], "vae": ["5", 0], "first_frame": ["1", 0], "prompt": prompt if prompt is not None else stable_video_prompt(shot), "width": 736, "height": 416, "length": length}},
        "8": {"class_type": "RandomNoise", "inputs": {"noise_seed": 314159265}},
        "9": {"class_type": "BasicGuider", "inputs": {"model": ["3", 0], "conditioning": ["7", 0]}},
        "10": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "res_multistep"}},
        "11": {"class_type": "BasicScheduler", "inputs": {"model": ["3", 0], "scheduler": "simple", "steps": 8, "denoise": 1.0}},
        "12": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["8", 0], "guider": ["9", 0], "sampler": ["10", 0], "sigmas": ["11", 0], "latent_image": ["7", 1]}},
        "13": {"class_type": "VAEDecode", "inputs": {"samples": ["12", 1], "vae": ["5", 0]}},
        "14": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["12", 1], "vae": ["6", 0]}},
        "15": {"class_type": "CreateVideo", "inputs": {"images": ["13", 0], "fps": 24.0, "audio": ["14", 0], "bit_depth": 8, "color_space": "sRGB"}},
        "16": {"class_type": "Video Slice", "inputs": {"video": ["15", 0], "start_time": 0.0, "duration": FINAL_VIDEO_SECONDS, "strict_duration": True}},
        "17": {"class_type": "SaveVideo", "inputs": {"video": ["16", 0], "filename_prefix": f"local_projects/{shot_id}", "format": "mp4"}},
    }}


def build_video_api_request(shot: Mapping[str, Any], client: VideoApiClient, *, prompt: str | None = None) -> dict[str, Any]:
    shot_id = str(shot.get("shot_id", "shot"))
    return {
        "provider": "minimax-video-api",
        "config_path": str(VIDEO_API_CONFIG_PATH),
        "model": client.config.model,
        "prompt": prompt if prompt is not None else stable_video_prompt(shot),
        "first_frame": str(shot.get("image_path") or ""),
        "duration": client.config.duration,
        "resolution": client.config.resolution,
        "output": str(COMFY_OUTPUT_ROOT / "local_projects" / f"{shot_id}_minimax_api.mp4"),
    }


def _stage_items(index: Mapping[str, Any], stage: str) -> list[dict[str, Any]]:
    entry = index["stages"][stage]
    return load_json(entry["path"])["items"]


def build_workflows(pipeline: str | Path | Mapping[str, Any], *, workflows_root: str | Path | None = None, video_config_path: str | Path = VIDEO_API_CONFIG_PATH) -> list[str]:
    index = _pipeline_data(pipeline)
    slug = str(index["project_slug"])
    if workflows_root is None:
        pipeline_path = runtime_path(index.get("pipeline_path", "manifests"))
        workflows_root = pipeline_path.parents[2].parent / "workflows" if pipeline_path.name == "pipeline.json" else Path("workflows")
    out = Path(workflows_root) / "local_projects" / slug
    out.mkdir(parents=True, exist_ok=True)
    shots = _stage_items(index, "shot_table")
    images = _stage_items(index, "image_prompts")
    videos = _stage_items(index, "video_prompts")
    generated_images = _stage_items(index, "image_generation")
    image_by_id = {str(item.get("shot_id")): item for item in images}
    video_by_id = {str(item.get("shot_id")): item for item in videos}
    generated_image_by_id = {str(item.get("shot_id")): item for item in generated_images}
    video_client = VideoApiClient.from_env(config_path=video_config_path)
    paths: list[str] = []
    for shot in shots:
        shot_id = str(shot["shot_id"])
        image_record = image_by_id.get(shot_id, {})
        image_source = {**shot, **image_record}
        image_prompt = generation_prompt(image_record, stable_image_prompt(image_source), require_approved=False)
        image_workflow = build_image_api_request(image_source, prompt=image_prompt)
        video_source = {**shot, **video_by_id.get(shot_id, {}), **generated_image_by_id.get(shot_id, {})}
        video_record = video_by_id.get(shot_id, {})
        video_prompt = generation_prompt(video_record, stable_video_prompt(video_source), require_approved=False)
        video_workflow = build_video_api_request(video_source, video_client, prompt=video_prompt) if video_client.config.mode == "api" else build_minimax_h3_workflow(video_source, prompt=video_prompt)
        for kind, workflow in (("image", image_workflow), ("video", video_workflow)):
            path = out / f"{shot_id}_{kind}.json"
            path.write_text(json.dumps(workflow, ensure_ascii=True, indent=2), encoding="utf-8")
            paths.append(str(path))
    # Keep generated artifact locations in the stage manifests for restartable runs.
    for stage, kind in (("image_generation", "image"), ("clip_generation", "video")):
        manifest_path = runtime_path(index["stages"][stage]["path"])
        manifest = load_json(manifest_path)
        for item in manifest.get("items", []):
            shot_id = str(item.get("shot_id"))
            item["workflow_path"] = str(out / f"{shot_id}_{kind}.json")
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=True, indent=2), encoding="utf-8")
    if index.get("pipeline_path"):
        runtime_path(index["pipeline_path"]).write_text(json.dumps(index, ensure_ascii=True, indent=2), encoding="utf-8")
    return paths


def _http_json(opener: Callable[..., Any], url: str, *, method: str = "GET", body: Mapping[str, Any] | None = None, timeout: float = 30) -> Any:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with opener(req, timeout=timeout) as response:
        raw = response.read().decode("utf-8")
    return json.loads(raw) if raw else {}


def _history_output_files(entry: Mapping[str, Any]) -> list[dict[str, str]]:
    records = []

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            filename = value.get("filename")
            if filename:
                subfolder = str(value.get("subfolder") or "")
                output_type = str(value.get("type") or "output")
                relative = Path(subfolder) / str(filename) if subfolder else Path(str(filename))
                absolute = COMFY_OUTPUT_ROOT / relative if output_type == "output" else Path(str(filename))
                records.append(
                    {
                        "filename": str(filename),
                        "subfolder": subfolder,
                        "type": output_type,
                        "path": str(absolute),
                        "annotated_path": relative.as_posix() + (" [output]" if output_type == "output" else ""),
                    }
                )
            for item in value.values():
                visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)

    visit(entry.get("outputs") or {})
    unique = {}
    for record in records:
        unique[(record["path"], record["type"])] = record
    return list(unique.values())


def submit_workflow_and_wait(workflow: Mapping[str, Any], *, base_url: str = "http://127.0.0.1:8188", timeout: float = 900, poll_interval: float = 2, opener: Callable[..., Any] = request.urlopen) -> dict[str, Any]:
    """Submit one workflow only when /queue reports idle; never clears the queue."""
    base_url = base_url.rstrip("/")
    try:
        queue = _http_json(opener, base_url + "/queue", timeout=min(timeout, 30))
    except Exception as exc:
        return {"status": "failed", "reason": "queue_check_failed", "error": str(exc)}
    busy = queue.get("queue_running", []) or queue.get("running", []) or queue.get("queue_pending", []) or queue.get("pending", [])
    if busy:
        return {"status": "waiting", "reason": "comfy_busy", "queue": queue}
    try:
        submitted = _http_json(opener, base_url + "/prompt", method="POST", body={"prompt": workflow.get("prompt", workflow), "client_id": workflow.get("client_id", "local-movie-pipeline")}, timeout=min(timeout, 30))
        prompt_id = submitted.get("prompt_id")
        if not prompt_id:
            return {"status": "failed", "reason": "missing_prompt_id", "response": submitted}
    except Exception as exc:
        return {"status": "failed", "reason": "submit_failed", "error": str(exc)}
    deadline = time.monotonic() + max(0, timeout)
    while time.monotonic() <= deadline:
        try:
            history = _http_json(opener, base_url + "/history/" + str(prompt_id), timeout=min(timeout, 30))
        except Exception as exc:
            return {"status": "failed", "prompt_id": prompt_id, "reason": "history_check_failed", "error": str(exc)}
        entry = history.get(str(prompt_id), history) if isinstance(history, dict) else {}
        status = entry.get("status", {}) if isinstance(entry, dict) else {}
        status_text = str(status.get("status_str", "")).lower() if isinstance(status, dict) else ""
        if status_text in {"error", "failed"} or (isinstance(status, dict) and status.get("completed") is False and status_text):
            return {"status": "failed", "prompt_id": prompt_id, "history": entry}
        if entry and (status_text in {"success", "completed"} or "outputs" in entry):
            return {"status": "passed", "prompt_id": prompt_id, "outputs": _history_output_files(entry), "history": entry}
        if poll_interval > 0:
            time.sleep(min(poll_interval, max(0, deadline - time.monotonic())))
        else:
            break
    return {"status": "waiting", "prompt_id": prompt_id, "reason": "timeout"}


def _update_shot_status(index: dict[str, Any], stage: str, shot_id: str, result: Mapping[str, Any]) -> None:
    path = runtime_path(index["stages"][stage]["path"])
    manifest = load_json(path)
    for item in manifest.get("items", []):
        if str(item.get("shot_id")) == shot_id:
            item["status"] = result.get("status", "failed")
            item["last_run"] = _timestamp()
            item["run_result"] = dict(result)
            outputs = result.get("outputs") if isinstance(result.get("outputs"), list) else []
            suffixes = {".png", ".jpg", ".jpeg", ".webp"} if stage == "image_generation" else ({".mp4", ".webm"} if stage in {"clip_generation", "audio_mix"} else {".mp3", ".wav", ".m4a"})
            output = next((entry for entry in outputs if Path(str(entry.get("filename") or "")).suffix.lower() in suffixes), None)
            if output:
                if stage == "image_generation":
                    item["image_path"] = output.get("path")
                    item["image_input"] = output.get("annotated_path") or comfy_output_annotation(output.get("path"), shot_id)
                elif stage == "tts_generation":
                    item["audio_path"] = output.get("path")
                elif stage == "audio_mix":
                    item["video_with_audio_path"] = output.get("path")
                else:
                    item["video_path"] = output.get("path")
    manifest["status"] = result.get("status", "failed")
    manifest["updated_at"] = _timestamp()
    path.write_text(json.dumps(manifest, ensure_ascii=True, indent=2), encoding="utf-8")
    index["stages"][stage]["status"] = manifest["status"]
    index["updated"] = _timestamp()
    if index.get("pipeline_path"):
        runtime_path(index["pipeline_path"]).write_text(json.dumps(index, ensure_ascii=True, indent=2), encoding="utf-8")


def _audio_settings(config_path: str | Path = AUDIO_CONFIG_PATH) -> dict[str, Any]:
    defaults = {"enabled": False, "voice": "zh-CN-YunxiNeural", "rate": "+0%", "pitch": "+0Hz", "ffmpeg": "ffmpeg"}
    path = Path(config_path)
    if not path.is_file():
        return defaults
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("音频配置无法读取") from exc
    return {**defaults, **(value.get("edge_tts", value) if isinstance(value, dict) else {})}


def generate_edge_tts(text: str, output_path: str | Path, *, voice: str, rate: str = "+0%", pitch: str = "+0Hz", executable: str = "edge-tts") -> dict[str, Any]:
    if not str(text or "").strip():
        return {"status": "skipped", "reason": "empty_dialogue"}
    command = [executable, "--voice", voice, "--rate", rate, "--pitch", pitch, "--text", str(text), "--write-media", str(output_path)]
    try:
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=180)
    except FileNotFoundError:
        return {"status": "failed", "reason": "edge_tts_not_installed", "hint": "pip install edge-tts"}
    except subprocess.CalledProcessError as exc:
        return {"status": "failed", "reason": "edge_tts_failed", "error": (exc.stderr or exc.stdout or "")[-500:]}
    except OSError as exc:
        return {"status": "failed", "reason": "edge_tts_failed", "error": str(exc)}
    return {"status": "passed", "outputs": [{"path": str(output_path), "filename": Path(output_path).name}]}


def mix_video_audio(video_path: str | Path, audio_path: str | Path, output_path: str | Path, *, ffmpeg: str = "ffmpeg") -> dict[str, Any]:
    command = [ffmpeg, "-y", "-i", str(video_path), "-i", str(audio_path), "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-shortest", str(output_path)]
    try:
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=300)
    except FileNotFoundError:
        return {"status": "failed", "reason": "ffmpeg_not_installed"}
    except subprocess.CalledProcessError as exc:
        return {"status": "failed", "reason": "audio_mix_failed", "error": (exc.stderr or exc.stdout or "")[-500:]}
    except OSError as exc:
        return {"status": "failed", "reason": "audio_mix_failed", "error": str(exc)}
    return {"status": "passed", "outputs": [{"path": str(output_path), "filename": Path(output_path).name}]}


def run_audio(stage: str, shot_id: str, pipeline: str | Path, *, audio_config_path: str | Path = AUDIO_CONFIG_PATH) -> dict[str, Any]:
    index = _pipeline_data(pipeline)
    shot = next((item for item in _stage_items(index, "shot_table") if str(item.get("shot_id")) == shot_id), None)
    if shot is None:
        result = {"status": "failed", "reason": "shot_not_found", "shot_id": shot_id}
    else:
        settings = _audio_settings(audio_config_path)
        design = next((item for item in _stage_items(index, "audio_design") if str(item.get("shot_id")) == shot_id), {})
        if stage == "tts_generation":
            if not settings.get("enabled"):
                result = {"status": "skipped", "reason": "audio_disabled"}
            else:
                text = " ".join(str(design.get(key) or "").strip() for key in ("dialogue", "narration") if str(design.get(key) or "").strip())
                output = COMFY_OUTPUT_ROOT / "local_projects" / f"{shot_id}_edge_tts.mp3"
                result = generate_edge_tts(text, output, voice=str(design.get("voice") or settings["voice"]), rate=str(design.get("rate") or settings["rate"]), pitch=str(design.get("pitch") or settings["pitch"]), executable=str(settings.get("edge_tts") or "edge-tts"))
        else:
            tts = next((item for item in _stage_items(index, "tts_generation") if str(item.get("shot_id")) == shot_id), {})
            video = next((item for item in _stage_items(index, "clip_generation") if str(item.get("shot_id")) == shot_id), {})
            audio_path, video_path = tts.get("audio_path"), video.get("video_path")
            if not audio_path or not video_path or not runtime_path(str(audio_path)).is_file() or not runtime_path(str(video_path)).is_file():
                result = {"status": "failed", "reason": "missing_video_or_audio", "shot_id": shot_id}
            else:
                output = COMFY_OUTPUT_ROOT / "local_projects" / f"{shot_id}_with_audio.mp4"
                result = mix_video_audio(runtime_path(video_path), runtime_path(audio_path), output, ffmpeg=str(settings.get("ffmpeg") or "ffmpeg"))
    result["shot_id"] = shot_id
    _update_shot_status(index, stage, shot_id, result)
    return result


def run_shot(stage: str, shot_id: str, pipeline: str | Path, *, base_url: str, timeout: float, poll_interval: float, opener: Callable[..., Any] = request.urlopen, image_client: ImageApiClient | None = None, image_config_path: str | Path = IMAGE_API_CONFIG_PATH, video_client: VideoApiClient | None = None, video_config_path: str | Path = VIDEO_API_CONFIG_PATH, workflows_root: str | Path | None = None) -> dict[str, Any]:
    index = _pipeline_data(pipeline)
    if stage == "image_generation":
        shot = next((item for item in _stage_items(index, "shot_table") if str(item.get("shot_id")) == shot_id), None)
        image_prompt = next((item for item in _stage_items(index, "image_prompts") if str(item.get("shot_id")) == shot_id), None)
        if shot is None:
            result = {"status": "failed", "reason": "shot_not_found", "shot_id": shot_id}
        elif image_prompt and ("review_status" in image_prompt or "final_prompt" in image_prompt) and (image_prompt.get("review_status") != "approved" or not str(image_prompt.get("final_prompt") or "").strip()):
            result = {"status": "failed", "reason": "prompt_not_approved", "shot_id": shot_id}
        else:
            client = image_client or ImageApiClient.from_env(config_path=image_config_path)
            if not client.configured:
                result = {"status": "failed", "reason": "image_api_not_configured", "shot_id": shot_id}
            else:
                output_path = COMFY_OUTPUT_ROOT / "local_projects" / f"{shot_id}_gpt_image.png"
                try:
                    prompt = generation_prompt(image_prompt or {}, stable_image_prompt({**shot, **(image_prompt or {})}))
                    result = client.generate(prompt, output_path)
                except (ImageAPIError, OSError, ValueError) as exc:
                    result = {"status": "failed", "reason": "image_api_failed", "error": str(exc)[:300]}
                result["shot_id"] = shot_id
        _update_shot_status(index, stage, shot_id, result)
        if result.get("status") == "passed":
            build_workflows(index, workflows_root=workflows_root, video_config_path=video_config_path)
        return result
    if stage == "clip_generation":
        client = video_client or VideoApiClient.from_env(config_path=video_config_path)
        shot = next((item for item in _stage_items(index, "shot_table") if str(item.get("shot_id")) == shot_id), None)
        video_prompt = next((item for item in _stage_items(index, "video_prompts") if str(item.get("shot_id")) == shot_id), None)
        if shot is not None and video_prompt and ("review_status" in video_prompt or "final_prompt" in video_prompt) and (video_prompt.get("review_status") != "approved" or not str(video_prompt.get("final_prompt") or "").strip()):
            result = {"status": "failed", "reason": "prompt_not_approved", "shot_id": shot_id}
            _update_shot_status(index, stage, shot_id, result)
            return result
        if client.config.mode == "api":
            image = next((item for item in _stage_items(index, "image_generation") if str(item.get("shot_id")) == shot_id), None)
            image_path = runtime_path(str((image or {}).get("image_path") or ""))
            if shot is None:
                result = {"status": "failed", "reason": "shot_not_found", "shot_id": shot_id}
            elif not str((image or {}).get("image_path") or "") or not image_path.is_file():
                result = {"status": "failed", "reason": "video_first_frame_missing", "shot_id": shot_id}
            elif not client.configured:
                result = {"status": "failed", "reason": "video_api_not_configured", "shot_id": shot_id}
            else:
                output_path = COMFY_OUTPUT_ROOT / "local_projects" / f"{shot_id}_minimax_api.mp4"
                try:
                    prompt = generation_prompt(video_prompt or {}, stable_video_prompt({**shot, **(video_prompt or {})}))
                    result = client.generate(prompt, image_path, output_path)
                except (VideoAPIError, OSError, ValueError) as exc:
                    result = {"status": "failed", "reason": "video_api_failed", "error": str(exc)[:300]}
                result.update({"shot_id": shot_id, "mode": "api"})
            _update_shot_status(index, stage, shot_id, result)
            return result
        build_workflows(index, workflows_root=workflows_root, video_config_path=video_config_path)
    kind = "image" if stage == "image_generation" else "video"
    path = None
    for item in _stage_items(index, stage):
        if str(item.get("shot_id")) == shot_id and item.get("workflow_path"):
            path = Path(item["workflow_path"])
            break
    if path is None:
        workflow_dir = Path(workflows_root or "workflows") / "local_projects" / index["project_slug"]
        path = workflow_dir / f"{shot_id}_{kind}.json"
    if not path.exists():
        build_workflows(index, workflows_root=workflows_root, video_config_path=video_config_path)
    if not path.exists():
        result = {"status": "failed", "reason": "workflow_not_found", "shot_id": shot_id}
    else:
        result = submit_workflow_and_wait(load_json(path), base_url=base_url, timeout=timeout, poll_interval=poll_interval, opener=opener)
        result["shot_id"] = shot_id
    _update_shot_status(index, stage, shot_id, result)
    return result


def _default_pipeline(slug: str) -> Path:
    return Path("manifests") / "local_projects" / slugify(slug) / "pipeline.json"


def _resolve_pipeline(pipeline: str | None, slug: str | None) -> Path:
    if pipeline:
        return runtime_path(pipeline)
    if slug:
        return _default_pipeline(slug)
    raise ValueError("provide --pipeline or --project-slug")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build local movie manifests and ComfyUI workflows")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("novel_pos", nargs="?")
    init.add_argument("--novel")
    init.add_argument("--slug", "--project-slug", dest="project_slug")
    init.add_argument("--project-title")
    init.add_argument("--max-shots", type=int)
    init.add_argument("--source-type", choices=("novel", "screenplay"), default="novel")
    init.add_argument("--content-type", choices=("single", "series"), default="single")
    init.add_argument("--planning-mode", choices=("auto", "fixed"), default="auto")
    init.add_argument("--target-episode-count", type=int)
    init.add_argument("--target-unit-duration-seconds", type=int, default=600)
    init.add_argument("--aspect-ratio", choices=("16:9", "9:16", "1:1"), default="16:9")
    init.add_argument("--visual-style", default="真人影视")
    init.add_argument("--style-status", choices=("pending", "confirmed"), default="confirmed")
    init.add_argument("--plan-only", action="store_true")
    init.add_argument("--manifests-root", default="manifests")
    init.add_argument("--workflows-root", default=None)
    init.add_argument("--text-config", default=str(TEXT_API_CONFIG_PATH))
    init.add_argument("--style-prompts-config", default=str(STYLE_PROMPTS_CONFIG_PATH))
    init.add_argument("--no-ai", action="store_true")
    confirm = sub.add_parser("confirm-plan")
    confirm.add_argument("--pipeline", default=None)
    confirm.add_argument("--slug", "--project-slug", dest="project_slug")
    confirm.add_argument("--workflows-root", default=None)
    confirm.add_argument("--text-config", default=str(TEXT_API_CONFIG_PATH))
    confirm.add_argument("--no-ai", action="store_true")
    show = sub.add_parser("show")
    show.add_argument("--pipeline", default=None)
    show.add_argument("--slug", "--project-slug", dest="project_slug", default="untitled-movie")
    build = sub.add_parser("build-workflows")
    build.add_argument("--pipeline")
    build.add_argument("--project-slug")
    build.add_argument("--workflows-root", default=None)
    build.add_argument("--video-config", default=str(VIDEO_API_CONFIG_PATH))
    for name, stage in (("run-image", "image_generation"), ("run-video", "clip_generation"), ("run-tts", "tts_generation"), ("mix-audio", "audio_mix")):
        command = sub.add_parser(name)
        command.set_defaults(run_stage=stage)
        command.add_argument("--pipeline")
        command.add_argument("--project-slug")
        command.add_argument("--shot-id", required=True)
        command.add_argument("--base-url", default=os.getenv("MOVIE_COMFY_BASE_URL", "http://127.0.0.1:8188"))
        command.add_argument("--timeout", type=float, default=900)
        command.add_argument("--poll-interval", type=float, default=2)
        command.add_argument("--image-config", default=str(IMAGE_API_CONFIG_PATH))
        command.add_argument("--video-config", default=str(VIDEO_API_CONFIG_PATH))
        command.add_argument("--audio-config", default=str(AUDIO_CONFIG_PATH))
        command.add_argument("--workflows-root", default=None)
    args = parser.parse_args(argv)
    if args.command == "init":
        client = None if args.no_ai else TextModelClient(config_path=args.text_config)
        novel = args.novel or args.novel_pos
        if not novel:
            parser.error("init requires a novel path via --novel or positional argument")
        index = build_pipeline(
            novel,
            manifests_root=args.manifests_root,
            slug=args.project_slug,
            project_title=args.project_title,
            max_shots=args.max_shots,
            client=client,
            source_type=args.source_type,
            content_type=args.content_type,
            planning_mode=args.planning_mode,
            target_episode_count=args.target_episode_count,
            target_unit_duration_seconds=args.target_unit_duration_seconds,
            aspect_ratio=args.aspect_ratio,
            visual_style=args.visual_style,
            style_status=args.style_status,
            plan_only=args.plan_only,
            style_presets=load_style_prompts(args.style_prompts_config),
        )
        paths = [] if args.plan_only else build_workflows(index, workflows_root=args.workflows_root)
        print(json.dumps({"pipeline": index["pipeline_path"], "workflow_count": len(paths)}, ensure_ascii=True))
    elif args.command == "confirm-plan":
        client = None if args.no_ai else TextModelClient(config_path=args.text_config)
        index = confirm_pipeline_plan(_resolve_pipeline(args.pipeline, args.project_slug), client=client)
        paths = build_workflows(index, workflows_root=args.workflows_root)
        print(json.dumps({"pipeline": index["pipeline_path"], "workflow_count": len(paths)}, ensure_ascii=True))
    elif args.command == "show":
        path = Path(args.pipeline) if args.pipeline else _default_pipeline(args.project_slug)
        print(json.dumps(load_json(path), ensure_ascii=True, indent=2))
    elif args.command == "build-workflows":
        paths = build_workflows(_resolve_pipeline(args.pipeline, args.project_slug), workflows_root=args.workflows_root, video_config_path=args.video_config)
        print(json.dumps({"workflow_count": len(paths), "workflows": paths}, ensure_ascii=True))
    else:
        try:
            pipeline = _resolve_pipeline(args.pipeline, args.project_slug)
        except ValueError as exc:
            parser.error(str(exc))
        if args.run_stage in {"tts_generation", "audio_mix"}:
            result = run_audio(args.run_stage, args.shot_id, pipeline, audio_config_path=args.audio_config)
        else:
            result = run_shot(args.run_stage, args.shot_id, pipeline, base_url=args.base_url, timeout=args.timeout, poll_interval=args.poll_interval, image_config_path=args.image_config, video_config_path=args.video_config, workflows_root=args.workflows_root)
        print(json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
