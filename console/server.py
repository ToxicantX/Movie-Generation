from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse


ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "console" / "static"
TEXT_SETTINGS_PATH = ROOT / "config" / "text_api.local.json"
IMAGE_SETTINGS_PATH = ROOT / "config" / "image_api.local.json"
VIDEO_SETTINGS_PATH = ROOT / "config" / "video_api.local.json"
AUDIO_SETTINGS_PATH = ROOT / "config" / "audio.local.json"
MANIFESTS = ROOT / "manifests"
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from style_presets import STYLE_NAMES, load_style_prompts, save_style_prompts

STYLE_PROMPTS_PATH = ROOT / "config" / "style_prompts.local.json"
COMFY_BASE_URL = os.getenv("MOVIE_COMFY_BASE_URL", "http://127.0.0.1:8188").rstrip("/")
SERVICE_HOST = os.getenv("MOVIE_SERVICE_HOST", "127.0.0.1").strip()
COMFY_OUTPUT_ROOT = Path(os.getenv("MOVIE_COMFY_OUTPUT_ROOT", r"G:\ComfyUI\output"))
OUTPUT_ROOT = COMFY_OUTPUT_ROOT / "AIShortDrama"
LOCAL_OUTPUT_ROOT = COMFY_OUTPUT_ROOT / "local_projects"
WORKSPACE_ROOT = Path(os.getenv("MOVIE_WORKSPACE_ROOT", str(ROOT.parent)))
HOST_PROJECT_ROOT = os.getenv("MOVIE_HOST_PROJECT_ROOT", "")
HOST_WORKSPACE_ROOT = os.getenv("MOVIE_HOST_WORKSPACE_ROOT", "")
DATABASE_URL = os.getenv("MOVIE_DATABASE_URL", "postgresql://movie_generation:movie_generation_local@127.0.0.1:55432/movie_generation")
REDIS_URL = os.getenv("MOVIE_REDIS_URL", "redis://127.0.0.1:56379/0")
STATUS_PATH = MANIFESTS / "ai_short_drama_status_report.json"
STATE_PATH = MANIFESTS / "current_pipeline_state.json"
LOCAL_PIPELINE_ROOT = MANIFESTS / "local_projects"
LOCAL_PIPELINE_SCRIPT = SCRIPTS / "local_movie_pipeline.py"
PIPELINE_EXCHANGE_FORMAT = "movie-generation-pipeline"
PIPELINE_EXCHANGE_VERSION = 1

SCENE_RE = re.compile(r"EP02\s+SC(\d+)", re.IGNORECASE)
SAFE_MEDIA_SUFFIXES = {
    ".html",
    ".jpg",
    ".jpeg",
    ".json",
    ".md",
    ".mp4",
    ".png",
    ".txt",
    ".webm",
}
SAFE_NOVEL_SUFFIXES = {".md", ".novel", ".text", ".txt"}
SAFE_PROJECT_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,63}$")
SAFE_SHOT_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{1,95}$")
LOCAL_STAGE_LABELS = {
    "concept": "方案",
    "story_bible": "故事圣经",
    "content_plan": "内容规划",
    "screenplay": "剧本 / 脚本",
    "screenplay_import": "剧本 / 脚本导入",
    "director_storyboard": "导演分镜设计",
    "episode_outline": "分集大纲",
    "scene_table": "场景表",
    "shot_table": "分镜表",
    "audio_design": "台词与音频设计",
    "asset_catalog": "资产清单",
    "image_prompts": "图片提示词",
    "image_generation": "图片资产生成",
    "video_prompts": "视频提示词",
    "model_match": "选择 / 匹配模型",
    "clip_generation": "视频片段生成",
    "tts_generation": "Edge TTS 配音生成",
    "audio_mix": "音画合成",
}
SOURCE_TYPES = {"novel", "screenplay"}
CONTENT_TYPES = {"single", "series"}
PLANNING_MODES = {"auto", "fixed"}
ASPECT_RATIOS = {"16:9", "9:16", "1:1"}
VIDEO_PRIMARY_STYLES = {"真人影视", "二维动漫", "三维动画"}


def runtime_path(path_value: str | Path) -> Path:
    path = Path(path_value)
    if path.exists():
        return path
    text = str(path_value).replace("\\", "/")
    mappings = (
        (HOST_PROJECT_ROOT, ROOT),
        (HOST_WORKSPACE_ROOT, WORKSPACE_ROOT),
        (os.getenv("MOVIE_HOST_OUTPUT_ROOT", ""), COMFY_OUTPUT_ROOT),
    )
    for host_root, runtime_root in mappings:
        normalized = str(host_root or "").rstrip("/\\").replace("\\", "/")
        if normalized and (text.casefold() == normalized.casefold() or text.casefold().startswith(normalized.casefold() + "/")):
            relative = text[len(normalized) :].lstrip("/")
            return runtime_root / Path(relative)
    return path


def read_json(path: str | Path, default=None):
    try:
        return json.loads(runtime_path(path).read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError, TypeError):
        return default


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def scene_number(segment_id: str) -> int:
    match = SCENE_RE.search(segment_id or "")
    return int(match.group(1)) if match else 0


def file_info(path_value: str | None) -> dict | None:
    if not path_value:
        return None
    path = runtime_path(path_value)
    try:
        exists = path.is_file()
        size = path.stat().st_size if exists else 0
    except OSError:
        exists = False
        size = 0
    return {
        "path": str(path),
        "name": path.name,
        "exists": exists,
        "size": size,
        "url": f"/media?path={quote_path(path)}" if exists else "",
    }


def quote_path(path: Path) -> str:
    from urllib.parse import quote

    return quote(str(path), safe="")


def decision_counts(value: dict | None) -> dict:
    value = value if isinstance(value, dict) else {}
    return {
        "pending": int(value.get("pending") or 0),
        "pass": int(value.get("pass") or 0),
        "needs_regeneration": int(value.get("needs_regeneration") or 0),
        "blocked": int(value.get("blocked") or 0),
        "other": int(value.get("other") or 0),
    }


def probe_http(url: str, timeout: float = 1.5) -> dict:
    from urllib.request import Request, urlopen

    started = time.monotonic()
    try:
        request = Request(url, headers={"User-Agent": "Movie-Pipeline-Console/1.0"})
        with urlopen(request, timeout=timeout) as response:
            status = response.status
        return {
            "ok": 200 <= status < 500,
            "status": status,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "url": url,
        }
    except Exception as exc:  # The API should report an unavailable dependency, not fail.
        return {
            "ok": False,
            "status": 0,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "url": url,
            "error": str(exc),
        }


def localize_next_action(value: str) -> str:
    text = str(value or "")
    if text.startswith("ComfyUI is busy"):
        return "ComfyUI 队列当前非空。无人值守生成前应等待队列空闲，不要清除其他任务。"
    match = re.search(r"EP02 SC(\d+).*?use (.+?ssj_ep02_sc\d+_seed\.json)", text, re.IGNORECASE)
    if match:
        return f"EP02 SC{int(match.group(1)):02d} 测试片段已完成。下一步从 {match.group(2)} 继续；I2V 保持无字幕，中文对白在剪辑阶段加入。"
    return text


def load_scene(segment: dict, include_shots: bool = True) -> dict:
    number = scene_number(str(segment.get("segment_id") or ""))
    seed_path = MANIFESTS / f"ssj_ep02_sc{number:02d}_seed.json"
    seed = read_json(seed_path, {}) or {}
    review_path = segment.get("video_review_path")
    review = read_json(review_path, {}) if include_shots else {}
    review = review if isinstance(review, dict) else {}

    shots = []
    fallback_count = 0
    for shot in review.get("shots") or []:
        mode = str(shot.get("preferred_video_mode") or "")
        if "technical" in mode or "fallback" in mode:
            fallback_count += 1
        shots.append(
            {
                "shot_id": shot.get("shot_id") or "",
                "title": shot.get("title") or "未命名镜头",
                "duration": shot.get("duration_seconds") or "",
                "status": shot.get("status") or "unknown",
                "mode": mode,
                "notes": shot.get("notes") or "",
                "checks": shot.get("checks") or {},
                "storyboard": file_info(shot.get("storyboard_path")),
                "video": file_info(shot.get("video_path")),
            }
        )

    formal = segment.get("formal_cut") if isinstance(segment.get("formal_cut"), dict) else {}
    counts = decision_counts(segment.get("decision_counts"))
    return {
        "id": f"SC{number:02d}",
        "number": number,
        "segment_id": segment.get("segment_id") or f"EP02 SC{number:02d}",
        "title": seed.get("title") or review.get("title") or f"场景 {number:02d}",
        "source": seed.get("source") or review.get("source") or "",
        "beat_id": seed.get("beat_id") or review.get("beat_id") or "",
        "ready": bool(segment.get("ready")),
        "stage": segment.get("postprocess_state") or segment.get("cycle_state") or "unknown",
        "review_decision": segment.get("video_review_global_decision") or review.get("global_decision") or "pending",
        "decision_counts": counts,
        "video_counts": decision_counts(segment.get("video_review_counts")),
        "shot_count": len(shots) or sum(counts.values()),
        "fallback_count": fallback_count,
        "formal_cut": {
            "ready": bool(formal.get("ready") or formal.get("ok")),
            "fps": formal.get("fps") or 0,
            "frame_count": formal.get("frame_count") or 0,
            "bytes": formal.get("bytes") or 0,
            "file": file_info(formal.get("output_path")),
        },
        "storyboard_dashboard": file_info(segment.get("storyboard_dashboard")),
        "storyboard_review": file_info(segment.get("storyboard_review")),
        "decision_file": file_info(segment.get("decision_path")),
        "review_file": file_info(review_path),
        "seed_file": file_info(seed_path),
        "next_seed": file_info(segment.get("next_seed")),
        "shots": shots,
    }


def load_status_payload() -> dict:
    report = read_json(STATUS_PATH, {}) or {}
    state = read_json(STATE_PATH, {}) or {}
    segments = [load_scene(item) for item in report.get("segments") or []]
    segments.sort(key=lambda item: item["number"])
    ready_count = sum(1 for item in segments if item["ready"])
    fallback_count = sum(item["fallback_count"] for item in segments)
    next_scene = ready_count + 1
    if segments:
        last_seed = segments[-1].get("next_seed") or {}
        seed_name = last_seed.get("name") or ""
        match = re.search(r"sc(\d+)", seed_name, re.IGNORECASE)
        if match:
            next_scene = int(match.group(1))

    ep01 = report.get("ep01") if isinstance(report.get("ep01"), dict) else {}
    service_urls = {
        "comfy": COMFY_BASE_URL,
        "video": f"http://{SERVICE_HOST}:7860",
        "ep01_review": f"http://{SERVICE_HOST}:8097",
        "storyboard_review": f"http://{SERVICE_HOST}:8098",
    }
    with ThreadPoolExecutor(max_workers=len(service_urls)) as executor:
        service_results = dict(zip(service_urls, executor.map(probe_http, service_urls.values())))

    return {
        "project": state.get("project") or "AI短剧生成工厂",
        "updated": report.get("updated") or state.get("updated") or "",
        "stage": report.get("current_stage") or state.get("current_stage") or "",
        "summary": {
            "episode": "EP02",
            "completed_scenes": ready_count,
            "scene_count": len(segments),
            "next_scene": f"SC{next_scene:02d}",
            "shot_count": sum(item["shot_count"] for item in segments),
            "fallback_count": fallback_count,
        },
        "comfy": report.get("comfy") or {},
        "ep01": {
            "decision_counts": decision_counts(ep01.get("decision_counts")),
            "formal_gate": ep01.get("formal_gate") or {},
            "cycle_state": ep01.get("cycle_state") or "",
            "review_dashboard": file_info(ep01.get("review_dashboard")),
            "review_server": ep01.get("review_server") or "",
        },
        "next_actions": [localize_next_action(item) for item in report.get("next_actions") or []],
        "services": service_results,
        "scenes": segments,
    }


def review_queue(status: dict) -> dict:
    items = []
    ep01_counts = status["ep01"]["decision_counts"]
    items.append(
        {
            "id": "EP01",
            "kind": "成片审核",
            "title": "EP01 正式剪辑审核",
            "decision": "pass" if status["ep01"]["formal_gate"].get("ok") else "pending",
            "counts": ep01_counts,
            "media": status["ep01"].get("review_dashboard"),
        }
    )
    for scene in status["scenes"]:
        items.append(
            {
                "id": scene["id"],
                "kind": "场景审核",
                "title": f"{scene['id']} {scene['title']}",
                "decision": scene["review_decision"],
                "counts": scene["video_counts"],
                "fallback_count": scene["fallback_count"],
                "media": scene.get("storyboard_dashboard") or scene.get("storyboard_review"),
            }
        )
    pending = sum(1 for item in items if item["decision"] not in {"pass", "approved_for_episode_cut"})
    fallback = sum(int(item.get("fallback_count") or 0) for item in items)
    return {"items": items, "summary": {"total": len(items), "pending": pending, "fallback": fallback}}


def validate_project_slug(value: str) -> str:
    slug = str(value or "").strip().lower()
    if not SAFE_PROJECT_SLUG_RE.fullmatch(slug):
        raise ValueError("项目标识仅支持 2-64 位小写字母、数字、下划线和连字符")
    return slug


def validate_shot_id(value: str) -> str:
    shot_id = str(value or "").strip()
    if not SAFE_SHOT_ID_RE.fullmatch(shot_id):
        raise ValueError("镜头 ID 格式无效")
    return shot_id


def validate_novel_path(value: str) -> Path:
    raw = str(value or "").strip().strip('"')
    if not raw:
        raise ValueError("请选择小说文件")
    try:
        path = runtime_path(raw).resolve(strict=True)
    except OSError as exc:
        raise ValueError("小说文件不存在") from exc
    workspace = WORKSPACE_ROOT.resolve()
    if path.suffix.lower() not in SAFE_NOVEL_SUFFIXES or workspace not in path.parents:
        raise ValueError("小说必须是工作区内的 txt、md、text 或 novel 文件")
    return path


TEXT_SETTING_DEFAULTS = {
    "base_url": "https://api.openai.com/v1",
    "model": "",
    "timeout": 120,
}


def _read_private_text_settings() -> dict:
    if not TEXT_SETTINGS_PATH.is_file():
        return dict(TEXT_SETTING_DEFAULTS)
    try:
        value = json.loads(TEXT_SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("文本 AI 配置无法读取") from exc
    settings = value.get("text_api", value) if isinstance(value, dict) else {}
    if not isinstance(settings, dict):
        raise ValueError("文本 AI 配置格式无效")
    return {**TEXT_SETTING_DEFAULTS, **settings}


def text_settings_payload() -> dict:
    settings = _read_private_text_settings()
    api_key_configured = bool(settings.get("api_key"))
    model = str(settings.get("model") or "")
    return {
        "provider": "OpenAI 兼容文本 API",
        "base_url": str(settings.get("base_url") or TEXT_SETTING_DEFAULTS["base_url"]),
        "model": model,
        "timeout": int(settings.get("timeout") or TEXT_SETTING_DEFAULTS["timeout"]),
        "api_key_configured": api_key_configured,
        "configured": bool(api_key_configured and model),
    }


def save_text_settings(payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise ValueError("文本 AI 配置格式无效")
    current = _read_private_text_settings()
    base_url = str(payload.get("base_url") or current.get("base_url") or "").strip().rstrip("/")
    parsed = urlparse(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("Base URL 必须是有效的 HTTP(S) 地址，且不能包含凭据")
    model = str(payload.get("model") or current.get("model") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}", model):
        raise ValueError("文本模型名称无效")
    try:
        timeout = int(payload.get("timeout", current.get("timeout") or 120))
    except (TypeError, ValueError) as exc:
        raise ValueError("文本模型超时无效") from exc
    if not 1 <= timeout <= 600:
        raise ValueError("文本模型超时必须在 1 到 600 秒之间")
    api_key = str(current.get("api_key") or "")
    submitted_key = payload.get("api_key")
    if submitted_key is not None and str(submitted_key).strip():
        api_key = str(submitted_key).strip()
    if payload.get("clear_api_key") is True:
        api_key = ""
    settings = {"api_key": api_key, "base_url": base_url, "model": model, "timeout": timeout}
    TEXT_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = TEXT_SETTINGS_PATH.with_suffix(TEXT_SETTINGS_PATH.suffix + ".tmp")
    temporary.write_text(json.dumps({"text_api": settings}, ensure_ascii=True, indent=2), encoding="utf-8")
    os.replace(temporary, TEXT_SETTINGS_PATH)
    return text_settings_payload()


IMAGE_SETTING_DEFAULTS = {
    "base_url": "https://api.openai.com",
    "model": "gpt-image-2",
    "size": "1536x1024",
    "quality": "high",
}
IMAGE_SETTING_SIZES = {"1536x1024", "1024x1024", "1024x1536"}
IMAGE_SETTING_QUALITIES = {"auto", "medium", "high"}


def _read_private_image_settings() -> dict:
    if not IMAGE_SETTINGS_PATH.is_file():
        return dict(IMAGE_SETTING_DEFAULTS)
    try:
        value = json.loads(IMAGE_SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("图片生成配置无法读取") from exc
    settings = value.get("image_api", value) if isinstance(value, dict) else {}
    if not isinstance(settings, dict):
        raise ValueError("图片生成配置格式无效")
    return {**IMAGE_SETTING_DEFAULTS, **settings}


def image_settings_payload() -> dict:
    settings = _read_private_image_settings()
    return {
        "provider": "GPT Image API",
        "base_url": str(settings.get("base_url") or IMAGE_SETTING_DEFAULTS["base_url"]),
        "model": str(settings.get("model") or IMAGE_SETTING_DEFAULTS["model"]),
        "size": str(settings.get("size") or IMAGE_SETTING_DEFAULTS["size"]),
        "quality": str(settings.get("quality") or IMAGE_SETTING_DEFAULTS["quality"]),
        "api_key_configured": bool(settings.get("api_key")),
    }


def save_image_settings(payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise ValueError("图片生成配置格式无效")
    current = _read_private_image_settings()
    base_url = str(payload.get("base_url") or current.get("base_url") or "").strip().rstrip("/")
    parsed = urlparse(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("Base URL 必须是有效的 HTTP(S) 地址，且不能包含凭据")
    model = str(payload.get("model") or current.get("model") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,99}", model):
        raise ValueError("图片模型名称无效")
    size = str(payload.get("size") or current.get("size") or "")
    quality = str(payload.get("quality") or current.get("quality") or "")
    if size not in IMAGE_SETTING_SIZES:
        raise ValueError("图片尺寸无效")
    if quality not in IMAGE_SETTING_QUALITIES:
        raise ValueError("图片质量无效")
    api_key = str(current.get("api_key") or "")
    submitted_key = payload.get("api_key")
    if submitted_key is not None and str(submitted_key).strip():
        api_key = str(submitted_key).strip()
    if payload.get("clear_api_key") is True:
        api_key = ""
    settings = {
        "api_key": api_key,
        "base_url": base_url,
        "model": model,
        "size": size,
        "quality": quality,
    }
    IMAGE_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = IMAGE_SETTINGS_PATH.with_suffix(IMAGE_SETTINGS_PATH.suffix + ".tmp")
    temporary.write_text(json.dumps({"image_api": settings}, ensure_ascii=True, indent=2), encoding="utf-8")
    os.replace(temporary, IMAGE_SETTINGS_PATH)
    return image_settings_payload()


VIDEO_SETTING_DEFAULTS = {
    "mode": "local",
    "provider": "minimax",
    "base_url": "https://api.minimax.io",
    "model": "MiniMax-Hailuo-02",
    "duration": 10,
    "resolution": "768P",
}
VIDEO_SETTING_MODES = {"local", "api"}
VIDEO_SETTING_DURATIONS = {6, 10}
VIDEO_SETTING_RESOLUTIONS = {"768P", "1080P"}


def _read_private_video_settings() -> dict:
    if not VIDEO_SETTINGS_PATH.is_file():
        return dict(VIDEO_SETTING_DEFAULTS)
    try:
        value = json.loads(VIDEO_SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("视频生成配置无法读取") from exc
    settings = value.get("video_api", value) if isinstance(value, dict) else {}
    if not isinstance(settings, dict):
        raise ValueError("视频生成配置格式无效")
    return {**VIDEO_SETTING_DEFAULTS, **settings}


def video_settings_payload() -> dict:
    settings = _read_private_video_settings()
    mode = str(settings.get("mode") or "local")
    api_key_configured = bool(settings.get("api_key"))
    return {
        "mode": mode,
        "provider": "MiniMax Video API",
        "base_url": str(settings.get("base_url") or VIDEO_SETTING_DEFAULTS["base_url"]),
        "model": str(settings.get("model") or VIDEO_SETTING_DEFAULTS["model"]),
        "duration": int(settings.get("duration") or VIDEO_SETTING_DEFAULTS["duration"]),
        "resolution": str(settings.get("resolution") or VIDEO_SETTING_DEFAULTS["resolution"]),
        "api_key_configured": api_key_configured,
        "configured": mode == "local" or api_key_configured,
    }


def save_video_settings(payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise ValueError("视频生成配置格式无效")
    current = _read_private_video_settings()
    mode = str(payload.get("mode") or current.get("mode") or "local").strip().lower()
    if mode not in VIDEO_SETTING_MODES:
        raise ValueError("视频生成方式无效")
    base_url = str(payload.get("base_url") or current.get("base_url") or "").strip().rstrip("/")
    parsed = urlparse(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("Base URL 必须是有效的 HTTP(S) 地址，且不能包含凭据")
    model = str(payload.get("model") or current.get("model") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,99}", model):
        raise ValueError("视频模型名称无效")
    try:
        duration = int(payload.get("duration", current.get("duration") or 10))
    except (TypeError, ValueError) as exc:
        raise ValueError("视频时长无效") from exc
    resolution = str(payload.get("resolution") or current.get("resolution") or "")
    if duration not in VIDEO_SETTING_DURATIONS:
        raise ValueError("视频时长仅支持 6 或 10 秒")
    if resolution not in VIDEO_SETTING_RESOLUTIONS:
        raise ValueError("视频分辨率无效")
    api_key = str(current.get("api_key") or "")
    submitted_key = payload.get("api_key")
    if submitted_key is not None and str(submitted_key).strip():
        api_key = str(submitted_key).strip()
    if payload.get("clear_api_key") is True:
        api_key = ""
    settings = {
        "mode": mode,
        "provider": "minimax",
        "api_key": api_key,
        "base_url": base_url,
        "model": model,
        "duration": duration,
        "resolution": resolution,
    }
    VIDEO_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = VIDEO_SETTINGS_PATH.with_suffix(VIDEO_SETTINGS_PATH.suffix + ".tmp")
    temporary.write_text(json.dumps({"video_api": settings}, ensure_ascii=True, indent=2), encoding="utf-8")
    os.replace(temporary, VIDEO_SETTINGS_PATH)
    return video_settings_payload()


AUDIO_SETTING_DEFAULTS = {"voice": "zh-CN-YunxiNeural", "rate": "+0%", "pitch": "+0Hz", "enabled": False}


def audio_settings_payload() -> dict:
    settings = read_json(AUDIO_SETTINGS_PATH, {}) or {}
    settings = settings.get("edge_tts", settings) if isinstance(settings, dict) else {}
    return {"provider": "Edge TTS", **{key: settings.get(key, value) for key, value in AUDIO_SETTING_DEFAULTS.items()}, "configured": bool(settings.get("enabled"))}


def save_audio_settings(payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise ValueError("音频配置格式无效")
    current = audio_settings_payload()
    settings = {
        "enabled": bool(payload.get("enabled", current["enabled"])),
        "voice": str(payload.get("voice") or current["voice"]).strip()[:120],
        "rate": str(payload.get("rate") or current["rate"]).strip()[:20],
        "pitch": str(payload.get("pitch") or current["pitch"]).strip()[:20],
    }
    AUDIO_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = AUDIO_SETTINGS_PATH.with_suffix(AUDIO_SETTINGS_PATH.suffix + ".tmp")
    temporary.write_text(json.dumps({"edge_tts": settings}, ensure_ascii=True, indent=2), encoding="utf-8")
    os.replace(temporary, AUDIO_SETTINGS_PATH)
    return audio_settings_payload()


def style_prompts_payload() -> dict:
    return {
        "styles": list(STYLE_NAMES),
        "presets": load_style_prompts(STYLE_PROMPTS_PATH),
        "source": "custom" if STYLE_PROMPTS_PATH.is_file() else "default",
    }


def save_style_prompts_settings(payload: dict) -> dict:
    if not isinstance(payload, dict) or set(payload) != {"presets"}:
        raise ValueError("风格提示词配置格式无效")
    save_style_prompts(STYLE_PROMPTS_PATH, payload["presets"])
    return style_prompts_payload()


def reset_style_prompts_settings() -> dict:
    try:
        STYLE_PROMPTS_PATH.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise ValueError("风格提示词配置无法恢复默认") from exc
    return style_prompts_payload()


PROJECT_STATUSES = {"draft", "active", "paused", "completed", "archived"}
PROJECT_CACHE_KEY = "movie-generation:projects:v1"
_PROJECT_DB_READY = False
_PROJECT_DB_LOCK = threading.Lock()


def validate_project_configuration(payload: dict, current: dict | None = None) -> dict:
    current = current or {}
    source_type = str(payload.get("source_type") or current.get("source_type") or "novel").strip().lower()
    content_type = str(payload.get("content_type") or current.get("content_type") or "single").strip().lower()
    planning_mode = str(payload.get("planning_mode") or current.get("planning_mode") or "auto").strip().lower()
    aspect_ratio = str(payload.get("aspect_ratio") or current.get("aspect_ratio") or "16:9").strip()
    visual_style = str(payload.get("visual_style") if "visual_style" in payload else current.get("visual_style") or "").strip()[:200]
    style_status = str(payload.get("style_status") or current.get("style_status") or ("confirmed" if visual_style else "pending")).strip().lower()
    if source_type not in SOURCE_TYPES:
        raise ValueError("来源类型无效")
    if content_type not in CONTENT_TYPES:
        raise ValueError("视频类型无效")
    if planning_mode not in PLANNING_MODES:
        raise ValueError("集数规划方式无效")
    if aspect_ratio not in ASPECT_RATIOS:
        raise ValueError("画幅无效")
    if style_status not in {"pending", "confirmed"}:
        raise ValueError("风格状态无效")
    if style_status == "confirmed" and not visual_style:
        raise ValueError("视觉风格不能为空")
    style_explicitly_set = "visual_style" in payload
    if style_status == "confirmed" and style_explicitly_set and visual_style not in VIDEO_PRIMARY_STYLES:
        raise ValueError("视频主体风格无效")
    try:
        target_duration = int(payload.get("target_unit_duration_seconds") or current.get("target_unit_duration_seconds") or 600)
    except (TypeError, ValueError) as exc:
        raise ValueError("目标时长无效") from exc
    if not 10 <= target_duration <= 7200:
        raise ValueError("目标时长必须在 10 到 7200 秒之间")
    target_count = payload.get("target_episode_count", current.get("target_episode_count"))
    if content_type == "single":
        target_count = 1
    elif planning_mode == "auto":
        target_count = None
    else:
        try:
            target_count = int(target_count)
        except (TypeError, ValueError) as exc:
            raise ValueError("固定集数无效") from exc
        if not 2 <= target_count <= 100:
            raise ValueError("固定集数必须在 2 到 100 集之间")
    return {
        "source_type": source_type,
        "content_type": content_type,
        "planning_mode": planning_mode,
        "target_episode_count": target_count,
        "target_unit_duration_seconds": target_duration,
        "aspect_ratio": aspect_ratio,
        "visual_style": visual_style,
        "style_status": style_status,
    }


@contextmanager
def _project_db_connection():
    try:
        import psycopg
        from psycopg.rows import dict_row

        with psycopg.connect(DATABASE_URL, connect_timeout=5, row_factory=dict_row) as connection:
            yield connection
    except ImportError as exc:
        raise RuntimeError("项目数据库驱动未安装") from exc
    except Exception as exc:
        if isinstance(exc, RuntimeError):
            raise
        raise RuntimeError("项目数据库不可用") from exc


def _project_record(row: dict) -> dict:
    created_at = row["created_at"]
    updated_at = row["updated_at"]
    return {
        "id": row["id"],
        "slug": row["slug"],
        "title": row["title"],
        "novel_path": row["novel_path"],
        "source_type": row.get("source_type") or "novel",
        "content_type": row.get("content_type") or "single",
        "planning_mode": row.get("planning_mode") or "auto",
        "target_episode_count": row.get("target_episode_count"),
        "target_unit_duration_seconds": row.get("target_unit_duration_seconds") or 600,
        "aspect_ratio": row.get("aspect_ratio") or "16:9",
        "visual_style": row.get("visual_style") or "",
        "style_status": row.get("style_status") or ("confirmed" if row.get("visual_style") else "pending"),
        "status": row["status"],
        "current_stage": row["current_stage"],
        "created_at": created_at.isoformat() if hasattr(created_at, "isoformat") else str(created_at),
        "updated_at": updated_at.isoformat() if hasattr(updated_at, "isoformat") else str(updated_at),
        "has_manifest": False,
    }


def _redis_client():
    if not REDIS_URL:
        return None
    try:
        import redis

        return redis.Redis.from_url(REDIS_URL, socket_connect_timeout=1, socket_timeout=1, decode_responses=True)
    except (ImportError, ValueError):
        return None


def _read_project_cache() -> list[dict] | None:
    client = _redis_client()
    if not client:
        return None
    try:
        value = client.get(PROJECT_CACHE_KEY)
        payload = json.loads(value) if value else None
        return payload if isinstance(payload, list) else None
    except Exception:
        return None


def _write_project_cache(projects: list[dict]) -> None:
    client = _redis_client()
    if not client:
        return
    try:
        client.setex(PROJECT_CACHE_KEY, 60, json.dumps(projects, ensure_ascii=False))
    except Exception:
        pass


def _clear_project_cache() -> None:
    client = _redis_client()
    if not client:
        return
    try:
        client.delete(PROJECT_CACHE_KEY)
    except Exception:
        pass


def ensure_project_db() -> None:
    global _PROJECT_DB_READY
    if _PROJECT_DB_READY:
        return
    with _PROJECT_DB_LOCK:
        if _PROJECT_DB_READY:
            return
        with _project_db_connection() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS projects (
                    id BIGSERIAL PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    novel_path TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'draft',
                    current_stage TEXT NOT NULL DEFAULT 'concept',
                    created_at TIMESTAMPTZ NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL,
                    CONSTRAINT projects_status_check CHECK (status IN ('draft', 'active', 'paused', 'completed', 'archived'))
                )
                """,
            )
            for statement in (
                "ALTER TABLE projects ADD COLUMN IF NOT EXISTS source_type TEXT NOT NULL DEFAULT 'novel'",
                "ALTER TABLE projects ADD COLUMN IF NOT EXISTS content_type TEXT NOT NULL DEFAULT 'single'",
                "ALTER TABLE projects ADD COLUMN IF NOT EXISTS planning_mode TEXT NOT NULL DEFAULT 'auto'",
                "ALTER TABLE projects ADD COLUMN IF NOT EXISTS target_episode_count INTEGER",
                "ALTER TABLE projects ADD COLUMN IF NOT EXISTS target_unit_duration_seconds INTEGER NOT NULL DEFAULT 600",
                "ALTER TABLE projects ADD COLUMN IF NOT EXISTS aspect_ratio TEXT NOT NULL DEFAULT '16:9'",
            "ALTER TABLE projects ADD COLUMN IF NOT EXISTS visual_style TEXT NOT NULL DEFAULT '真人影视'",
                "ALTER TABLE projects ADD COLUMN IF NOT EXISTS style_status TEXT NOT NULL DEFAULT 'confirmed'",
            ):
                connection.execute(statement)
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS pipeline_manifests (
                    project_slug TEXT PRIMARY KEY REFERENCES projects(slug) ON DELETE CASCADE,
                    payload JSONB NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """,
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS pipeline_artifacts (
                    project_slug TEXT NOT NULL REFERENCES projects(slug) ON DELETE CASCADE,
                    stage TEXT NOT NULL,
                    payload JSONB NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    source TEXT NOT NULL DEFAULT '',
                    model TEXT NOT NULL DEFAULT '',
                    item_count INTEGER NOT NULL DEFAULT 0,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    PRIMARY KEY (project_slug, stage)
                )
                """,
            )
            if LOCAL_PIPELINE_ROOT.is_dir():
                for path in LOCAL_PIPELINE_ROOT.glob("*/pipeline.json"):
                    manifest = read_json(path, {}) or {}
                    try:
                        slug = validate_project_slug(manifest.get("project_slug") or path.parent.name)
                    except ValueError:
                        continue
                    project = manifest.get("project") if isinstance(manifest.get("project"), dict) else {}
                    title = str(manifest.get("project_title") or project.get("title") or slug)
                    novel_path = str(manifest.get("novel_path") or "")
                    status = str(manifest.get("status") or "draft")
                    if status not in PROJECT_STATUSES:
                        status = "draft"
                    current_stage = str(manifest.get("current_stage") or "concept")
                    timestamp = str(manifest.get("updated") or manifest.get("updated_at") or datetime.now(timezone.utc).isoformat(timespec="seconds"))
                    connection.execute(
                        """
                        INSERT INTO projects
                            (slug, title, novel_path, status, current_stage, created_at, updated_at)
                        VALUES (%s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (slug) DO NOTHING
                        """,
                        (slug, title[:120], novel_path, status, current_stage[:80], timestamp, timestamp),
                    )
        _PROJECT_DB_READY = True


def _jsonb(value):
    from psycopg.types.json import Jsonb

    return Jsonb(value)


def _metadata_text(value) -> str:
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))[:500]
    return str(value or "")[:500]


def _normalize_pipeline_manifest(manifest: dict) -> dict:
    normalized = json.loads(json.dumps(manifest, ensure_ascii=False))
    normalized.pop("pipeline_path", None)
    stages = normalized.get("stages") if isinstance(normalized.get("stages"), dict) else {}
    for entry in stages.values():
        if isinstance(entry, dict):
            entry.pop("path", None)
    normalized["stages"] = stages
    return normalized


def normalize_episode_id(value) -> str:
    if isinstance(value, int):
        return f"EP{value:02d}"
    text = str(value or "").strip().upper().replace("_", "").replace("-", "")
    match = re.fullmatch(r"(?:EP)?(\d{1,4})", text)
    return f"EP{int(match.group(1)):02d}" if match else ""


def normalize_asset_catalog(payload: dict) -> dict:
    normalized = json.loads(json.dumps(payload, ensure_ascii=False))
    items = normalized.get("items") if isinstance(normalized.get("items"), list) else []
    normalized_items = []
    for index, item in enumerate(items, 1):
        if not isinstance(item, dict):
            continue
        episode_id = normalize_episode_id(item.get("episode_id") or item.get("episode"))
        scope = str(item.get("scope") or ("episode" if episode_id else "shared")).strip().lower()
        if scope not in {"shared", "episode"}:
            scope = "episode" if episode_id else "shared"
        if scope == "episode" and not episode_id:
            episode_id = "EP01"
        normalized_items.append(
            {
                **item,
                "asset_id": str(item.get("asset_id") or f"asset-{index:03d}")[:120],
                "scope": scope,
                "episode_id": episode_id if scope == "episode" else "",
            }
        )
    normalized["items"] = normalized_items
    normalized["asset_scope_version"] = 1
    return normalized


def _upsert_pipeline_artifact(connection, project_slug: str, stage: str, artifact: dict) -> None:
    if stage == "asset_catalog":
        artifact = normalize_asset_catalog(artifact)
    items = artifact.get("items") if isinstance(artifact.get("items"), list) else []
    connection.execute(
        """
        INSERT INTO pipeline_artifacts
            (project_slug, stage, payload, status, source, model, item_count, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, NOW(), NOW())
        ON CONFLICT (project_slug, stage) DO UPDATE SET
            payload = EXCLUDED.payload,
            status = EXCLUDED.status,
            source = EXCLUDED.source,
            model = EXCLUDED.model,
            item_count = EXCLUDED.item_count,
            updated_at = NOW()
        """,
        (
            project_slug,
            stage,
            _jsonb(artifact),
            str(artifact.get("status") or "pending")[:80],
            _metadata_text(artifact.get("source")),
            _metadata_text(artifact.get("model")),
            len(items),
        ),
    )


def _write_pipeline_storage(connection, manifest: dict, artifacts: dict[str, dict]) -> str:
    project = manifest.get("project") if isinstance(manifest.get("project"), dict) else {}
    slug = validate_project_slug(manifest.get("project_slug") or project.get("slug"))
    title = str(manifest.get("project_title") or project.get("title") or slug).strip()[:120]
    status = str(manifest.get("status") or "draft")
    if status not in PROJECT_STATUSES:
        status = "draft"
    current_stage = str(manifest.get("current_stage") or "concept")[:80]
    novel_path = str(manifest.get("novel_path") or "")
    connection.execute(
        """
        INSERT INTO projects (slug, title, novel_path, source_type, content_type, planning_mode, target_episode_count, target_unit_duration_seconds, aspect_ratio, visual_style, style_status, status, current_stage, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, NOW(), NOW())
        ON CONFLICT (slug) DO UPDATE SET
            title = EXCLUDED.title,
            novel_path = EXCLUDED.novel_path,
            source_type = EXCLUDED.source_type,
            content_type = EXCLUDED.content_type,
            planning_mode = EXCLUDED.planning_mode,
            target_episode_count = EXCLUDED.target_episode_count,
            target_unit_duration_seconds = EXCLUDED.target_unit_duration_seconds,
            aspect_ratio = EXCLUDED.aspect_ratio,
            visual_style = EXCLUDED.visual_style,
            style_status = EXCLUDED.style_status,
            status = EXCLUDED.status,
            current_stage = EXCLUDED.current_stage,
            updated_at = NOW()
        """,
        (
            slug,
            title,
            novel_path,
            str(manifest.get("source_type") or "novel"),
            str(manifest.get("content_type") or "single"),
            str(manifest.get("planning_mode") or "auto"),
            manifest.get("target_episode_count"),
            int(manifest.get("target_unit_duration_seconds") or 600),
            str(manifest.get("aspect_ratio") or "16:9"),
            str(manifest.get("visual_style") or "真人影视"),
            str(manifest.get("style_status") or "confirmed"),
            status,
            current_stage,
        ),
    )
    normalized = _normalize_pipeline_manifest({**manifest, "project_slug": slug, "project_title": title})
    connection.execute(
        """
        INSERT INTO pipeline_manifests (project_slug, payload, created_at, updated_at)
        VALUES (%s, %s, NOW(), NOW())
        ON CONFLICT (project_slug) DO UPDATE SET payload = EXCLUDED.payload, updated_at = NOW()
        """,
        (slug, _jsonb(normalized)),
    )
    connection.execute("DELETE FROM pipeline_artifacts WHERE project_slug = %s", (slug,))
    for stage, artifact in artifacts.items():
        if stage in LOCAL_STAGE_LABELS and isinstance(artifact, dict):
            _upsert_pipeline_artifact(connection, slug, stage, artifact)
    return slug


def save_pipeline_storage(manifest: dict, artifacts: dict[str, dict]) -> str:
    if not isinstance(manifest, dict) or not isinstance(artifacts, dict):
        raise ValueError("流水线交换数据格式无效")
    ensure_project_db()
    with _project_db_connection() as connection:
        slug = _write_pipeline_storage(connection, manifest, artifacts)
    _clear_project_cache()
    return slug


def load_pipeline_storage(project_slug: str) -> tuple[dict | None, dict[str, dict], list[dict]]:
    slug = validate_project_slug(project_slug)
    ensure_project_db()
    with _project_db_connection() as connection:
        manifest_row = connection.execute(
            "SELECT payload, updated_at FROM pipeline_manifests WHERE project_slug = %s",
            (slug,),
        ).fetchone()
        rows = connection.execute(
            """
            SELECT stage, payload, status, source, model, item_count, updated_at
            FROM pipeline_artifacts
            WHERE project_slug = %s
            ORDER BY updated_at DESC, stage ASC
            """,
            (slug,),
        ).fetchall()
    manifest = dict(manifest_row["payload"]) if manifest_row and isinstance(manifest_row["payload"], dict) else None
    artifacts = {row["stage"]: dict(row["payload"]) for row in rows if isinstance(row["payload"], dict)}
    records = [
        {
            "stage": row["stage"],
            "status": row["status"],
            "source": row["source"],
            "model": row["model"],
            "item_count": row["item_count"],
            "updated_at": row["updated_at"].isoformat() if hasattr(row["updated_at"], "isoformat") else str(row["updated_at"]),
        }
        for row in rows
    ]
    return manifest, artifacts, records


def pipeline_export_bundle(project_slug: str) -> dict:
    manifest, artifacts, _ = load_pipeline_storage(project_slug)
    if not manifest:
        raise ValueError("项目尚未完成小说导入")
    return {
        "format": PIPELINE_EXCHANGE_FORMAT,
        "version": PIPELINE_EXCHANGE_VERSION,
        "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "manifest": manifest,
        "artifacts": artifacts,
    }


def import_pipeline_bundle(payload: dict) -> dict:
    if not isinstance(payload, dict) or payload.get("format") != PIPELINE_EXCHANGE_FORMAT:
        raise ValueError("不是有效的电影流水线交换文件")
    if int(payload.get("version") or 0) != PIPELINE_EXCHANGE_VERSION:
        raise ValueError("流水线交换文件版本不受支持")
    manifest = payload.get("manifest")
    artifacts = payload.get("artifacts")
    if not isinstance(manifest, dict) or not isinstance(artifacts, dict):
        raise ValueError("流水线交换文件缺少清单或阶段产物")
    slug = save_pipeline_storage(manifest, artifacts)
    return {"ok": True, "project_slug": slug, "artifact_count": len(artifacts)}


def materialize_pipeline_workspace(project_slug: str, *, initialize: bool = False) -> tuple[Path, Path]:
    slug = validate_project_slug(project_slug)
    temp_root = Path(tempfile.mkdtemp(prefix=f"movie-pipeline-{slug}-"))
    manifests_root = temp_root / "manifests"
    pipeline_path = manifests_root / "local_projects" / slug / "pipeline.json"
    if initialize:
        return temp_root, pipeline_path
    try:
        manifest, artifacts, _ = load_pipeline_storage(slug)
        if not manifest:
            raise ValueError("项目尚未完成小说导入")
        project_dir = pipeline_path.parent
        project_dir.mkdir(parents=True, exist_ok=True)
        runtime_manifest = json.loads(json.dumps(manifest, ensure_ascii=False))
        runtime_stages = runtime_manifest.get("stages") if isinstance(runtime_manifest.get("stages"), dict) else {}
        for stage, artifact in artifacts.items():
            stage_path = project_dir / f"{stage}.json"
            write_json(stage_path, artifact)
            entry = runtime_stages.get(stage) if isinstance(runtime_stages.get(stage), dict) else {}
            runtime_stages[stage] = {**entry, "path": str(stage_path)}
        runtime_manifest["stages"] = runtime_stages
        runtime_manifest["pipeline_path"] = str(pipeline_path)
        write_json(pipeline_path, runtime_manifest)
        return temp_root, pipeline_path
    except Exception:
        shutil.rmtree(temp_root, ignore_errors=True)
        raise


def sync_pipeline_workspace(project_slug: str, temp_root: str | Path) -> dict:
    slug = validate_project_slug(project_slug)
    pipeline_path = Path(temp_root) / "manifests" / "local_projects" / slug / "pipeline.json"
    manifest = read_json(pipeline_path, None)
    if not isinstance(manifest, dict):
        raise RuntimeError("临时流水线清单未生成")
    artifacts = {}
    raw_stages = manifest.get("stages") if isinstance(manifest.get("stages"), dict) else {}
    for stage in LOCAL_STAGE_LABELS:
        entry = raw_stages.get(stage) if isinstance(raw_stages.get(stage), dict) else {}
        artifact = read_json(entry.get("path") or pipeline_path.parent / f"{stage}.json", None)
        if isinstance(artifact, dict):
            artifacts[stage] = artifact
    save_pipeline_storage(manifest, artifacts)
    return {"project_slug": slug, "artifact_count": len(artifacts)}


def migrate_legacy_pipeline_storage(*, remove_files: bool = False) -> dict:
    ensure_project_db()
    imported = []
    removable: list[Path] = []
    if not LOCAL_PIPELINE_ROOT.is_dir():
        return {"projects": 0, "artifacts": 0, "removed_files": 0, "items": []}
    for pipeline_path in sorted(LOCAL_PIPELINE_ROOT.glob("*/pipeline.json")):
        manifest = read_json(pipeline_path, None)
        if not isinstance(manifest, dict):
            raise RuntimeError(f"无法读取历史清单：{pipeline_path}")
        slug = validate_project_slug(manifest.get("project_slug") or pipeline_path.parent.name)
        artifacts = {}
        raw_stages = manifest.get("stages") if isinstance(manifest.get("stages"), dict) else {}
        project_files = [pipeline_path]
        for stage in LOCAL_STAGE_LABELS:
            entry = raw_stages.get(stage) if isinstance(raw_stages.get(stage), dict) else {}
            stage_path = runtime_path(entry.get("path") or pipeline_path.parent / f"{stage}.json")
            if not stage_path.is_file():
                stage_path = pipeline_path.parent / f"{stage}.json"
            if stage_path.is_file():
                artifact = read_json(stage_path, None)
                if not isinstance(artifact, dict):
                    raise RuntimeError(f"无法读取历史阶段产物：{stage_path}")
                artifacts[stage] = artifact
                project_files.append(stage_path)
        save_pipeline_storage(manifest, artifacts)
        stored_manifest, stored_artifacts, _ = load_pipeline_storage(slug)
        if stored_manifest != _normalize_pipeline_manifest({**manifest, "project_slug": slug, "project_title": stored_manifest.get("project_title") if stored_manifest else ""}) or stored_artifacts != artifacts:
            raise RuntimeError(f"历史项目迁移校验失败：{slug}")
        imported.append({"project_slug": slug, "artifact_count": len(artifacts)})
        removable.extend(project_files)
    removed = 0
    if remove_files:
        for path in removable:
            if path.is_file():
                path.unlink()
                removed += 1
        for directory in sorted({path.parent for path in removable}, reverse=True):
            try:
                directory.rmdir()
            except OSError:
                pass
    return {
        "projects": len(imported),
        "artifacts": sum(item["artifact_count"] for item in imported),
        "removed_files": removed,
        "items": imported,
    }


def storage_health() -> dict:
    database_ok = False
    redis_ok = False
    try:
        ensure_project_db()
        with _project_db_connection() as connection:
            database_ok = connection.execute("SELECT 1 AS ok").fetchone()["ok"] == 1
    except RuntimeError:
        database_ok = False
    client = _redis_client()
    if client:
        try:
            redis_ok = bool(client.ping())
        except Exception:
            redis_ok = False
    return {"postgres": database_ok, "redis": redis_ok}


def list_project_records() -> list[dict]:
    ensure_project_db()
    cached = _read_project_cache()
    if cached is not None:
        return cached
    with _project_db_connection() as connection:
        rows = connection.execute(
            """
            SELECT projects.*,
                   EXISTS (SELECT 1 FROM pipeline_manifests WHERE project_slug = projects.slug) AS has_manifest
            FROM projects
            ORDER BY updated_at DESC, slug ASC
            """
        ).fetchall()
    projects = [{**_project_record(row), "has_manifest": bool(row["has_manifest"])} for row in rows]
    _write_project_cache(projects)
    return projects


def get_project_record(slug: str) -> dict | None:
    slug = validate_project_slug(slug)
    ensure_project_db()
    with _project_db_connection() as connection:
        row = connection.execute(
            "SELECT projects.*, EXISTS (SELECT 1 FROM pipeline_manifests WHERE project_slug = projects.slug) AS has_manifest FROM projects WHERE slug = %s",
            (slug,),
        ).fetchone()
    if not row:
        return None
    return {**_project_record(row), "has_manifest": bool(row["has_manifest"])}


def create_project_record(payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise ValueError("项目参数格式无效")
    slug = validate_project_slug(payload.get("slug") or payload.get("project_slug"))
    title = str(payload.get("title") or payload.get("project_title") or "").strip()
    if not title:
        raise ValueError("项目名称不能为空")
    novel_path = validate_novel_path(payload.get("novel_path")) if payload.get("novel_path") else Path("")
    config = validate_project_configuration(payload)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    ensure_project_db()
    try:
        with _project_db_connection() as connection:
            connection.execute(
                "INSERT INTO projects (slug, title, novel_path, source_type, content_type, planning_mode, target_episode_count, target_unit_duration_seconds, aspect_ratio, visual_style, style_status, status, current_stage, created_at, updated_at) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'draft', 'style_setup', %s, %s)",
                (slug, title[:120], str(novel_path) if str(novel_path) != "." else "", config["source_type"], config["content_type"], config["planning_mode"], config["target_episode_count"], config["target_unit_duration_seconds"], config["aspect_ratio"], config["visual_style"], config["style_status"], now, now),
            )
    except RuntimeError as exc:
        cause = exc.__cause__
        if getattr(cause, "sqlstate", "") == "23505":
            raise ValueError("项目标识已存在") from exc
        raise
    _clear_project_cache()
    return get_project_record(slug) or {}


def update_project_record(slug: str, payload: dict) -> dict:
    slug = validate_project_slug(slug)
    if not isinstance(payload, dict):
        raise ValueError("项目参数格式无效")
    current = get_project_record(slug)
    if not current:
        raise ValueError("项目不存在")
    title = str(payload.get("title") or current["title"]).strip()[:120]
    status = str(payload.get("status") or current["status"]).strip().lower()
    stage = str(payload.get("current_stage") or current["current_stage"]).strip()[:80]
    novel_path = validate_novel_path(payload.get("novel_path")) if payload.get("novel_path") else Path(current["novel_path"] or "")
    config = validate_project_configuration(payload, current)
    if not title or status not in PROJECT_STATUSES:
        raise ValueError("项目状态或名称无效")
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with _project_db_connection() as connection:
        connection.execute(
            "UPDATE projects SET title = %s, novel_path = %s, source_type = %s, content_type = %s, planning_mode = %s, target_episode_count = %s, target_unit_duration_seconds = %s, aspect_ratio = %s, visual_style = %s, style_status = %s, status = %s, current_stage = %s, updated_at = %s WHERE slug = %s",
            (title, str(novel_path) if str(novel_path) != "." else "", config["source_type"], config["content_type"], config["planning_mode"], config["target_episode_count"], config["target_unit_duration_seconds"], config["aspect_ratio"], config["visual_style"], config["style_status"], status, stage, now, slug),
        )
    _clear_project_cache()
    return get_project_record(slug) or {}


def local_pipeline_projects() -> list[dict]:
    ensure_project_db()
    with _project_db_connection() as connection:
        rows = connection.execute(
            """
            SELECT project_slug, payload, updated_at
            FROM pipeline_manifests
            ORDER BY updated_at DESC, project_slug ASC
            """
        ).fetchall()
    return [
        {
            "slug": row["project_slug"],
            "title": row["payload"].get("project_title") or row["payload"].get("project", {}).get("title") or row["project_slug"],
            "updated": row["updated_at"].isoformat() if hasattr(row["updated_at"], "isoformat") else str(row["updated_at"]),
            "storage": "postgresql",
        }
        for row in rows
    ]


def local_pipeline_payload(project_slug: str = "") -> dict:
    slug = str(project_slug or "").strip().lower()
    if slug:
        slug = validate_project_slug(slug)
    projects = local_pipeline_projects()
    if not slug and projects:
        slug = projects[0]["slug"]
    if not slug:
        return {"exists": False, "manifest": None, "projects": projects, "registered_project": None}
    registered_project = get_project_record(slug)
    manifest, artifacts, artifact_records = load_pipeline_storage(slug)
    if not isinstance(manifest, dict):
        return {"exists": False, "manifest": None, "projects": projects, "project_slug": slug, "registered_project": registered_project}
    if isinstance(artifacts.get("asset_catalog"), dict):
        artifacts["asset_catalog"] = normalize_asset_catalog(artifacts["asset_catalog"])
    raw_stages = manifest.get("stages") if isinstance(manifest.get("stages"), dict) else {}
    records_by_stage = {item["stage"]: item for item in artifact_records}
    stage_items = {}
    stages = []
    for key, label in LOCAL_STAGE_LABELS.items():
        entry = raw_stages.get(key) if isinstance(raw_stages.get(key), dict) else {}
        artifact = artifacts.get(key) if isinstance(artifacts.get(key), dict) else {}
        record = records_by_stage.get(key, {})
        items = artifact.get("items") if isinstance(artifact, dict) else []
        stage_items[key] = items if isinstance(items, list) else []
        stages.append(
            {
                "key": key,
                "label": label,
                "status": record.get("status") or entry.get("status") or artifact.get("status") or "pending",
                "source": record.get("source") or entry.get("source") or artifact.get("source") or "",
                "model": record.get("model") or artifact.get("model") or "",
                "item_count": len(stage_items[key]),
                "updated_at": record.get("updated_at") or "",
                "storage": "postgresql" if record else "",
                "reason": artifact.get("reason") or "" if isinstance(artifact, dict) else "",
            }
        )
    shots = {}
    for item in stage_items.get("shot_table", []):
        if isinstance(item, dict) and item.get("shot_id"):
            shots[str(item["shot_id"])] = dict(item)
    stage_fields = {
        "image_prompts": ("image_prompt_record", None),
        "video_prompts": ("video_prompt_record", None),
        "model_match": ("model", "video_model"),
        "audio_design": ("audio_design", None),
    }
    for stage_key, (target, source) in stage_fields.items():
        for item in stage_items.get(stage_key, []):
            if isinstance(item, dict) and str(item.get("shot_id") or "") in shots:
                shots[str(item["shot_id"])][target] = dict(item) if source is None else item.get(source) or ""
    for shot in shots.values():
        image_record = shot.get("image_prompt_record") if isinstance(shot.get("image_prompt_record"), dict) else {}
        video_record = shot.get("video_prompt_record") if isinstance(shot.get("video_prompt_record"), dict) else {}
        shot["image_prompt"] = image_record.get("final_prompt") or image_record.get("prompt") or ""
        shot["video_prompt"] = video_record.get("final_prompt") or video_record.get("prompt") or ""
    for stage_key, output_key in (("image_generation", "image_output"), ("clip_generation", "video_output"), ("tts_generation", "audio_output"), ("audio_mix", "video_audio_output")):
        for item in stage_items.get(stage_key, []):
            if not isinstance(item, dict) or str(item.get("shot_id") or "") not in shots:
                continue
            shot = shots[str(item["shot_id"])]
            shot["status"] = item.get("status") or shot.get("status") or "waiting"
            source_key = "image_path" if stage_key == "image_generation" else ("video_path" if stage_key == "clip_generation" else ("audio_path" if stage_key == "tts_generation" else "video_with_audio_path"))
            shot[output_key] = item.get(source_key) or ""
            shot["image_workflow" if stage_key == "image_generation" else "video_workflow"] = item.get("workflow_path") or ""
    workflow_root = ROOT / "workflows" / "local_projects" / slug
    for shot in shots.values():
        shot_id = str(shot.get("shot_id") or "")
        shot.setdefault("title", str(shot.get("action") or shot_id)[:48])
        shot.setdefault("episode_id", f"EP{int(shot.get('episode') or 1):02d}")
        shot.setdefault("image_workflow", str(workflow_root / f"{shot_id}_image.json"))
        shot.setdefault("video_workflow", str(workflow_root / f"{shot_id}_video.json"))
        shot["image_media"] = file_info(shot.get("image_output"))
        shot["video_media"] = file_info(shot.get("video_output"))
        shot["audio_media"] = file_info(shot.get("audio_output"))
        shot["video_audio_media"] = file_info(shot.get("video_audio_output"))
        shot["image_workflow_file"] = file_info(shot.get("image_workflow"))
        shot["video_workflow_file"] = file_info(shot.get("video_workflow"))
    manifest["project_title"] = manifest.get("project_title") or slug.replace("-", " ").title()
    source_value = manifest.get("source")
    manifest["source_kind"] = source_value if isinstance(source_value, str) else manifest.get("source_kind") or ""
    manifest["project"] = {"slug": slug, "title": manifest["project_title"]}
    manifest["source"] = {
        "path": manifest.get("novel_path") or "",
        "novel_path": manifest.get("novel_path") or "",
        "source_type": manifest.get("source_type") or "novel",
    }
    manifest["production_units"] = stage_items.get("content_plan", [])
    manifest["story_bible"] = stage_items.get("story_bible", [])
    manifest["episodes"] = stage_items.get("episode_outline", []) or manifest["production_units"]
    manifest["assets"] = stage_items.get("asset_catalog", [])
    manifest["stages"] = stages
    manifest["shots"] = list(shots.values())
    image_settings = image_settings_payload()
    video_settings = video_settings_payload()
    manifest["models"] = manifest.get("models") or {
        "image": f"OpenAI API / {image_settings['model']}",
        "video": "MiniMax H3 FL2VA W4A8 + PDD 8-step" if video_settings["mode"] == "local" else f"MiniMax API / {video_settings['model']}",
        "video_spec": "736×416 · 24fps · 243 原始帧 / 精确 10 秒" if video_settings["mode"] == "local" else f"{video_settings['resolution']} · {video_settings['duration']} 秒",
    }
    return {
        "exists": True,
        "manifest": manifest,
        "projects": projects,
        "project_slug": slug,
        "registered_project": registered_project,
        "storage": "postgresql",
    }


def save_audio_design(payload: dict) -> dict:
    slug = validate_project_slug(payload.get("project_slug"))
    shot_id = validate_shot_id(payload.get("shot_id"))
    _, artifacts, _ = load_pipeline_storage(slug)
    manifest = artifacts.get("audio_design")
    if not isinstance(manifest, dict):
        raise ValueError("音频设计清单不存在")
    found = False
    for item in manifest.get("items", []):
        if str(item.get("shot_id")) == shot_id:
            for key in ("dialogue", "narration", "voice", "rate", "pitch"):
                if key in payload:
                    item[key] = str(payload.get(key) or "").strip()[:2000]
            found = True
            break
    if not found:
        raise ValueError("镜头不存在")
    manifest["updated_at"] = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    ensure_project_db()
    with _project_db_connection() as connection:
        _upsert_pipeline_artifact(connection, slug, "audio_design", manifest)
    return {"ok": True, "shot_id": shot_id}


def save_asset_scope(payload: dict) -> dict:
    slug = validate_project_slug(payload.get("project_slug"))
    asset_id = str(payload.get("asset_id") or "").strip()
    scope = str(payload.get("scope") or "").strip().lower()
    if not asset_id or len(asset_id) > 120 or scope not in {"shared", "episode"}:
        raise ValueError("素材标识或作用域无效")
    _, artifacts, _ = load_pipeline_storage(slug)
    catalog = normalize_asset_catalog(artifacts.get("asset_catalog") or {})
    episode_outline = artifacts.get("episode_outline") if isinstance(artifacts.get("episode_outline"), dict) else {}
    episode_ids = [normalize_episode_id(item.get("episode_id") or item.get("episode")) for item in episode_outline.get("items", []) if isinstance(item, dict)]
    episode_ids = [value for value in episode_ids if value]
    episode_id = normalize_episode_id(payload.get("episode_id")) if scope == "episode" else ""
    if scope == "episode" and not episode_id:
        episode_id = episode_ids[0] if episode_ids else "EP01"
    if scope == "episode" and episode_ids and episode_id not in episode_ids:
        raise ValueError("素材所属集不存在")
    asset = next((item for item in catalog["items"] if str(item.get("asset_id")) == asset_id), None)
    if asset is None:
        raise ValueError("素材不存在")
    asset["scope"] = scope
    asset["episode_id"] = episode_id
    catalog["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    ensure_project_db()
    with _project_db_connection() as connection:
        _upsert_pipeline_artifact(connection, slug, "asset_catalog", catalog)
    return {"ok": True, "asset": asset}


def save_prompt_review(payload: dict) -> dict:
    slug = validate_project_slug(payload.get("project_slug"))
    target_type = str(payload.get("target_type") or "").strip()
    targets = {
        "asset": ("asset_catalog", "asset_id"),
        "shot_image": ("image_prompts", "shot_id"),
        "shot_video": ("video_prompts", "shot_id"),
    }
    if target_type not in targets:
        raise ValueError("提示词目标类型无效")
    stage, id_key = targets[target_type]
    target_id = str(payload.get("target_id") or "").strip()
    if id_key == "shot_id":
        target_id = validate_shot_id(target_id)
    elif not target_id or len(target_id) > 120:
        raise ValueError("素材标识无效")
    review_status = str(payload.get("review_status") or "").strip()
    if review_status not in {"pending_review", "approved", "needs_revision"}:
        raise ValueError("提示词审核状态无效")
    final_prompt = str(payload.get("final_prompt") or "").strip()
    negative_prompt = str(payload.get("negative_prompt") or "").strip()
    if len(final_prompt) > 16000 or len(negative_prompt) > 4000:
        raise ValueError("提示词内容过长")
    if review_status == "approved" and not final_prompt:
        raise ValueError("审核通过前必须填写终稿提示词")

    _, artifacts, _ = load_pipeline_storage(slug)
    artifact = artifacts.get(stage)
    if not isinstance(artifact, dict):
        raise ValueError("提示词阶段产物不存在")
    prompt = next((item for item in artifact.get("items", []) if isinstance(item, dict) and str(item.get(id_key) or "") == target_id), None)
    if prompt is None:
        raise ValueError("提示词目标不存在")
    prompt.update(
        {
            "final_prompt": final_prompt,
            "prompt": final_prompt,
            "negative_prompt": negative_prompt,
            "review_status": review_status,
            "prompt_revision": int(prompt.get("prompt_revision") or 0) + 1,
            "prompt_updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )
    artifact["updated_at"] = prompt["prompt_updated_at"]
    ensure_project_db()
    with _project_db_connection() as connection:
        _upsert_pipeline_artifact(connection, slug, stage, artifact)
    return {"ok": True, "prompt": prompt}


def migrate_asset_scopes() -> dict:
    ensure_project_db()
    changed_projects = 0
    asset_count = 0
    with _project_db_connection() as connection:
        rows = connection.execute("SELECT project_slug, payload FROM pipeline_artifacts WHERE stage = 'asset_catalog' ORDER BY project_slug").fetchall()
        for row in rows:
            normalized = normalize_asset_catalog(row["payload"])
            asset_count += len(normalized["items"])
            if normalized != row["payload"]:
                _upsert_pipeline_artifact(connection, row["project_slug"], "asset_catalog", normalized)
                changed_projects += 1
    return {"projects": len(rows), "changed_projects": changed_projects, "assets": asset_count}


def local_pipeline_command(payload: dict) -> tuple[str, str, list[str], dict]:
    if not LOCAL_PIPELINE_SCRIPT.is_file():
        raise ValueError("本地电影流水线脚本不存在")
    action = str(payload.get("action") or "").strip()
    slug = validate_project_slug(payload.get("project_slug"))
    command = [sys.executable, str(LOCAL_PIPELINE_SCRIPT)]
    video_settings = video_settings_payload()
    labels = {
        "init": "导入内容并生成项目规划",
        "confirm_plan": "确认规划并展开生产单元",
        "build_workflows": "构建 API 图片与 H3 工作流",
        "generate_image": "生成 OpenAI 首帧资产",
        "generate_video": "生成本地 H3 视频片段" if video_settings["mode"] == "local" else "通过 API 生成视频片段",
        "generate_tts": "生成 Edge TTS 配音",
        "mix_audio": "合成视频音频",
    }
    if action not in labels:
        raise ValueError("未知的本地流水线任务")
    metadata = {"project_slug": slug, "shot_id": ""}
    if action == "init":
        novel = validate_novel_path(payload.get("novel_path"))
        title = str(payload.get("project_title") or novel.stem).strip()[:120]
        max_shots = max(1, min(int(payload.get("max_shots") or 4), 24))
        config = validate_project_configuration(payload)
        if config["style_status"] != "confirmed":
            raise ValueError("请先确认视频主体风格")
        register_project = {
            "slug": slug,
            "title": title,
            "novel_path": str(novel),
            **config,
        }
        if not get_project_record(slug):
            create_project_record(register_project)
        temp_root, _ = materialize_pipeline_workspace(slug, initialize=True)
        metadata["_pipeline_temp_root"] = str(temp_root)
        command += [
            "init",
            "--novel",
            str(novel),
            "--project-slug",
            slug,
            "--project-title",
            title,
            "--max-shots",
            str(max_shots),
            "--source-type",
            config["source_type"],
            "--content-type",
            config["content_type"],
            "--planning-mode",
            config["planning_mode"],
            "--target-unit-duration-seconds",
            str(config["target_unit_duration_seconds"]),
            "--aspect-ratio",
            config["aspect_ratio"],
            "--visual-style",
            config["visual_style"],
            "--style-status",
            "confirmed",
            "--plan-only",
            "--text-config",
            str(TEXT_SETTINGS_PATH),
            "--style-prompts-config",
            str(STYLE_PROMPTS_PATH),
            "--manifests-root",
            str(temp_root / "manifests"),
            "--workflows-root",
            str(ROOT / "workflows"),
        ]
        if config["target_episode_count"] is not None:
            command += ["--target-episode-count", str(config["target_episode_count"])]
    elif action == "confirm_plan":
        temp_root, manifest_path = materialize_pipeline_workspace(slug)
        metadata["_pipeline_temp_root"] = str(temp_root)
        command += [
            "confirm-plan",
            "--pipeline",
            str(manifest_path),
            "--text-config",
            str(TEXT_SETTINGS_PATH),
            "--workflows-root",
            str(ROOT / "workflows"),
        ]
    else:
        shot_id = ""
        if action in {"generate_image", "generate_video", "generate_tts", "mix_audio"}:
            shot_id = validate_shot_id(payload.get("shot_id"))
            metadata["shot_id"] = shot_id
        temp_root, manifest_path = materialize_pipeline_workspace(slug)
        metadata["_pipeline_temp_root"] = str(temp_root)
        command += [
            {"build_workflows": "build-workflows", "generate_image": "run-image", "generate_video": "run-video", "generate_tts": "run-tts", "mix_audio": "mix-audio"}[action],
            "--pipeline",
            str(manifest_path),
            "--workflows-root",
            str(ROOT / "workflows"),
        ]
        if shot_id:
            command += ["--shot-id", shot_id]
        if action == "generate_video":
            command += ["--video-config", str(VIDEO_SETTINGS_PATH)]
    return action, labels[action], command, metadata


ACTION_COMMANDS = {
    "refresh_status": {
        "label": "刷新流水线状态",
        "command": ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPTS / "build_ai_short_drama_status_report.ps1")],
    },
    "check_i2v_contract": {
        "label": "检查 I2V 合约",
        "command": ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPTS / "test_i2v_contract.ps1")],
    },
    "check_secret_hygiene": {
        "label": "检查密钥安全",
        "command": ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPTS / "test_prompt_secret_hygiene.ps1"), "-AllowBusyQueue"],
    },
    "refresh_ep01_review": {
        "label": "刷新 EP01 审核看板",
        "command": ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPTS / "build_ep01_human_review_dashboard.ps1")],
    },
}


class JobStore:
    def __init__(self):
        self._lock = threading.Lock()
        self._jobs: dict[str, dict] = {}

    def list(self) -> list[dict]:
        with self._lock:
            return sorted((self._public_job(item) for item in self._jobs.values()), key=lambda item: item["created"], reverse=True)

    def get(self, job_id: str) -> dict | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return self._public_job(job) if job else None

    @staticmethod
    def _public_job(job: dict) -> dict:
        return {key: value for key, value in job.items() if not key.startswith("_")}

    def start(self, action: str) -> dict:
        definition = ACTION_COMMANDS.get(action)
        if not definition:
            raise ValueError("未知任务")
        return self.start_command(action, definition["label"], definition["command"])

    def start_command(
        self,
        action: str,
        label: str,
        command: list[str],
        metadata: dict | None = None,
    ) -> dict:
        job_id = uuid.uuid4().hex[:12]
        job = {
            "id": job_id,
            "action": action,
            "label": label,
            "status": "queued",
            "created": datetime.now().isoformat(timespec="seconds"),
            "started": "",
            "finished": "",
            "exit_code": None,
            "output": "",
            **(metadata or {}),
        }
        with self._lock:
            self._jobs[job_id] = job
        threading.Thread(target=self._run, args=(job_id, command), daemon=True).start()
        return self._public_job(job)

    def _run(self, job_id: str, command: list[str]) -> None:
        with self._lock:
            job = self._jobs[job_id]
            job["status"] = "running"
            job["started"] = datetime.now().isoformat(timespec="seconds")
        try:
            process = subprocess.run(
                command,
                cwd=ROOT,
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                timeout=900,
                check=False,
            )
            output = "\n".join(part.strip() for part in (process.stdout, process.stderr) if part.strip())
            with self._lock:
                pipeline_temp_root = self._jobs[job_id].get("_pipeline_temp_root")
                project_slug = self._jobs[job_id].get("project_slug")
            if process.returncode == 0 and pipeline_temp_root and project_slug:
                synced = sync_pipeline_workspace(project_slug, pipeline_temp_root)
                output = "\n".join(part for part in (output, f"已回写 PostgreSQL：{synced['artifact_count']} 个阶段产物") if part)
            with self._lock:
                job = self._jobs[job_id]
                job["exit_code"] = process.returncode
                job["status"] = "completed" if process.returncode == 0 else "failed"
                job["output"] = output[-40000:]
        except Exception as exc:
            with self._lock:
                job = self._jobs[job_id]
                job["status"] = "failed"
                job["output"] = str(exc)
        finally:
            with self._lock:
                pipeline_temp_root = self._jobs[job_id].get("_pipeline_temp_root")
            if pipeline_temp_root:
                shutil.rmtree(pipeline_temp_root, ignore_errors=True)
            with self._lock:
                self._jobs[job_id]["finished"] = datetime.now().isoformat(timespec="seconds")


JOBS = JobStore()


def is_allowed_media(path: Path) -> bool:
    try:
        resolved = runtime_path(path).resolve(strict=True)
    except OSError:
        return False
    if resolved.suffix.lower() not in SAFE_MEDIA_SUFFIXES:
        return False
    roots = [ROOT.resolve(), OUTPUT_ROOT.resolve(), LOCAL_OUTPUT_ROOT.resolve()]
    return any(resolved == root or root in resolved.parents for root in roots)


class ConsoleHandler(BaseHTTPRequestHandler):
    server_version = "MoviePipelineConsole/1.0"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}", flush=True)

    def send_json(self, payload, status=HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json_download(self, payload: dict, filename: str) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_static(self, path: Path) -> None:
        try:
            data = path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8" if content_type.startswith("text/") else content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_media(self, path: Path) -> None:
        path = runtime_path(path)
        if not is_allowed_media(path):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        size = path.stat().st_size
        start, end = 0, size - 1
        range_header = self.headers.get("Range", "")
        if range_header.startswith("bytes="):
            value = range_header[6:].split(",", 1)[0]
            left, _, right = value.partition("-")
            if left:
                start = max(0, min(int(left), size - 1))
            if right:
                end = max(start, min(int(right), size - 1))
        length = end - start + 1
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.PARTIAL_CONTENT if range_header else HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if range_header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with path.open("rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining:
                chunk = handle.read(min(1024 * 256, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def send_video_frame(self, path: Path, seconds: float) -> None:
        path = runtime_path(path)
        if not is_allowed_media(path) or path.suffix.lower() not in {".mp4", ".webm"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            import cv2

            capture = cv2.VideoCapture(str(path))
            if not capture.isOpened():
                raise RuntimeError("无法打开视频")
            fps = max(capture.get(cv2.CAP_PROP_FPS), 1.0)
            frame_count = max(int(capture.get(cv2.CAP_PROP_FRAME_COUNT)), 1)
            target_frame = min(max(int(seconds * fps), 0), frame_count - 1)
            capture.set(cv2.CAP_PROP_POS_FRAMES, target_frame)
            ok, frame = capture.read()
            if not ok and target_frame > 0:
                capture.set(cv2.CAP_PROP_POS_FRAMES, max(0, target_frame - 2))
                ok, frame = capture.read()
            capture.release()
            if not ok:
                raise RuntimeError("无法读取视频帧")
            encoded, buffer = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), 86])
            if not encoded:
                raise RuntimeError("无法编码视频帧")
            data = buffer.tobytes()
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/health":
            storage = storage_health()
            self.send_json({"ok": storage["postgres"], "service": "movie-generation-console", "storage": storage}, HTTPStatus.OK if storage["postgres"] else HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/projects":
            try:
                self.send_json({"items": list_project_records()})
            except RuntimeError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path.startswith("/api/projects/"):
            slug = unquote(path.rsplit("/", 1)[-1])
            try:
                project = get_project_record(slug)
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except RuntimeError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.SERVICE_UNAVAILABLE)
                return
            if not project:
                self.send_json({"ok": False, "error": "项目不存在"}, HTTPStatus.NOT_FOUND)
            else:
                self.send_json(project)
            return
        if path == "/favicon.ico":
            self.send_response(HTTPStatus.NO_CONTENT)
            self.end_headers()
            return
        if path == "/api/status":
            self.send_json(load_status_payload())
            return
        if path == "/api/scenes":
            status = load_status_payload()
            self.send_json({"items": status["scenes"], "summary": status["summary"]})
            return
        if path.startswith("/api/scenes/"):
            scene_id = path.rsplit("/", 1)[-1].upper()
            status = load_status_payload()
            scene = next((item for item in status["scenes"] if item["id"] == scene_id), None)
            if not scene:
                self.send_json({"ok": False, "error": "场景不存在"}, HTTPStatus.NOT_FOUND)
            else:
                self.send_json(scene)
            return
        if path == "/api/reviews":
            self.send_json(review_queue(load_status_payload()))
            return
        if path == "/api/local-pipeline":
            values = parse_qs(parsed.query)
            try:
                self.send_json(local_pipeline_payload((values.get("project_slug") or [""])[0]))
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except RuntimeError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/local-pipeline/export":
            values = parse_qs(parsed.query)
            try:
                slug = validate_project_slug((values.get("project_slug") or [""])[0])
                self.send_json_download(pipeline_export_bundle(slug), f"{slug}-pipeline.json")
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except RuntimeError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/text-settings":
            try:
                self.send_json(text_settings_payload())
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        if path == "/api/image-settings":
            try:
                self.send_json(image_settings_payload())
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        if path == "/api/video-settings":
            try:
                self.send_json(video_settings_payload())
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        if path == "/api/audio-settings":
            try:
                self.send_json(audio_settings_payload())
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        if path == "/api/style-prompts":
            try:
                self.send_json(style_prompts_payload())
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        if path == "/api/jobs":
            self.send_json({"items": JOBS.list(), "actions": ACTION_COMMANDS})
            return
        if path.startswith("/api/jobs/"):
            job = JOBS.get(path.rsplit("/", 1)[-1])
            self.send_json(job or {"ok": False, "error": "任务不存在"}, HTTPStatus.OK if job else HTTPStatus.NOT_FOUND)
            return
        if path == "/media":
            values = parse_qs(parsed.query).get("path") or []
            if not values:
                self.send_error(HTTPStatus.BAD_REQUEST)
                return
            self.send_media(Path(unquote(values[0])))
            return
        if path == "/video-frame":
            values = parse_qs(parsed.query)
            media_paths = values.get("path") or []
            if not media_paths:
                self.send_error(HTTPStatus.BAD_REQUEST)
                return
            try:
                seconds = float((values.get("time") or ["0"])[0])
            except ValueError:
                seconds = 0
            self.send_video_frame(Path(unquote(media_paths[0])), seconds)
            return
        if path in {"/", "/index.html"}:
            self.send_static(STATIC / "index.html")
            return
        if path.startswith("/static/"):
            name = Path(path).name
            if name not in {"app.js", "styles.css"}:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            self.send_static(STATIC / name)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path not in {"/api/jobs", "/api/local-pipeline/jobs", "/api/local-pipeline/import", "/api/projects", "/api/style-prompts/reset"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
            if parsed.path == "/api/style-prompts/reset":
                self.send_json(reset_style_prompts_settings())
                return
            if parsed.path == "/api/projects":
                self.send_json(create_project_record(payload), HTTPStatus.CREATED)
                return
            if parsed.path == "/api/local-pipeline/import":
                self.send_json(import_pipeline_bundle(payload), HTTPStatus.CREATED)
                return
            if parsed.path == "/api/local-pipeline/jobs":
                action, label, command, metadata = local_pipeline_command(payload)
                job = JOBS.start_command(action, label, command, metadata)
            else:
                job = JOBS.start(str(payload.get("action") or ""))
            self.send_json(job, HTTPStatus.ACCEPTED)
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
        except RuntimeError as exc:
            self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.SERVICE_UNAVAILABLE)

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        if not (parsed.path in {"/api/text-settings", "/api/image-settings", "/api/video-settings", "/api/audio-settings", "/api/style-prompts", "/api/local-pipeline/audio-design", "/api/local-pipeline/asset-scope", "/api/local-pipeline/prompt-review"} or parsed.path.startswith("/api/projects/")):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
            if parsed.path.startswith("/api/projects/"):
                result = update_project_record(unquote(parsed.path.rsplit("/", 1)[-1]), payload)
            elif parsed.path == "/api/text-settings":
                result = save_text_settings(payload)
            elif parsed.path == "/api/image-settings":
                result = save_image_settings(payload)
            elif parsed.path == "/api/video-settings":
                result = save_video_settings(payload)
            elif parsed.path == "/api/audio-settings":
                result = save_audio_settings(payload)
            elif parsed.path == "/api/style-prompts":
                result = save_style_prompts_settings(payload)
            elif parsed.path == "/api/local-pipeline/asset-scope":
                result = save_asset_scope(payload)
            elif parsed.path == "/api/local-pipeline/prompt-review":
                result = save_prompt_review(payload)
            else:
                result = save_audio_design(payload)
            self.send_json(result)
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
        except RuntimeError as exc:
            self.send_json({"ok": False, "error": str(exc)}, HTTPStatus.SERVICE_UNAVAILABLE)


def create_server(host: str, port: int) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), ConsoleHandler)


def main() -> None:
    parser = argparse.ArgumentParser(description="Movie Generation pipeline console")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8200)
    parser.add_argument("--migrate-pipeline-storage", action="store_true")
    parser.add_argument("--remove-legacy-json", action="store_true")
    parser.add_argument("--migrate-asset-scopes", action="store_true")
    args = parser.parse_args()
    if args.migrate_pipeline_storage:
        print(json.dumps(migrate_legacy_pipeline_storage(remove_files=args.remove_legacy_json), ensure_ascii=False, indent=2))
        return
    if args.migrate_asset_scopes:
        print(json.dumps(migrate_asset_scopes(), ensure_ascii=False, indent=2))
        return
    server = create_server(args.host, args.port)
    print(f"Movie Pipeline Console: http://{args.host}:{args.port}", flush=True)
    print(f"Project root: {ROOT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
