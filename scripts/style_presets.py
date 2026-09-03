from __future__ import annotations

import copy
import json
import os
from pathlib import Path
from typing import Any, Mapping


STYLE_NAMES = ("真人影视", "二维动漫", "三维动画")
PROMPT_FIELDS = ("image_prompt", "video_prompt", "negative_prompt")
MAX_PROMPT_LENGTH = 4000

DEFAULT_STYLE_PROMPTS = {
    "真人影视": {
        "image_prompt": "Photorealistic live-action cinema, natural skin and material texture, physically plausible lighting, realistic lens rendering and production design.",
        "video_prompt": "Live-action cinematic motion with natural body mechanics, realistic secondary motion, physically plausible lighting and camera behavior.",
        "negative_prompt": "anime, illustration, toon shading, obvious CGI, plastic skin, extra people, duplicate person, child, extra limbs, fused hands, distorted face, text, watermark, logo",
    },
    "二维动漫": {
        "image_prompt": "Polished 2D animation frame, clean expressive linework, controlled cel shading, coherent painted background and consistent character design.",
        "video_prompt": "Fluid 2D animation with consistent linework, stable cel shading, intentional key poses, clean in-between motion and coherent background movement.",
        "negative_prompt": "photorealistic rendering, live-action texture, 3D plastic look, broken linework, flickering colors, extra people, duplicate person, child, extra limbs, fused hands, distorted face, text, watermark, logo",
    },
    "三维动画": {
        "image_prompt": "High-quality 3D animated film frame, refined character modeling, coherent materials, cinematic lighting and production-ready environment detail.",
        "video_prompt": "Polished 3D animation with stable models and materials, natural rigged motion, coherent simulation, cinematic lighting and controlled camera movement.",
        "negative_prompt": "live-action footage, flat 2D linework, low-poly artifacts, broken rig, texture flicker, extra people, duplicate person, child, extra limbs, fused hands, distorted face, text, watermark, logo",
    },
}


def default_style_prompts() -> dict[str, dict[str, str]]:
    return copy.deepcopy(DEFAULT_STYLE_PROMPTS)


def validate_style_prompts(value: Any) -> dict[str, dict[str, str]]:
    if not isinstance(value, Mapping) or set(value) != set(STYLE_NAMES):
        raise ValueError("风格提示词必须完整包含真人影视、二维动漫和三维动画")
    normalized: dict[str, dict[str, str]] = {}
    for style in STYLE_NAMES:
        preset = value.get(style)
        if not isinstance(preset, Mapping) or set(preset) != set(PROMPT_FIELDS):
            raise ValueError(f"{style} 必须包含图片、视频和负向提示词")
        normalized[style] = {}
        for field in PROMPT_FIELDS:
            prompt = preset.get(field)
            if not isinstance(prompt, str) or not prompt.strip():
                raise ValueError(f"{style} 的提示词不能为空")
            prompt = prompt.strip()
            if len(prompt) > MAX_PROMPT_LENGTH:
                raise ValueError(f"{style} 的提示词不能超过 {MAX_PROMPT_LENGTH} 个字符")
            normalized[style][field] = prompt
    return normalized


def load_style_prompts(path: str | Path) -> dict[str, dict[str, str]]:
    config_path = Path(path)
    if not config_path.is_file():
        return default_style_prompts()
    try:
        payload = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("风格提示词配置无法读取") from exc
    presets = payload.get("presets") if isinstance(payload, Mapping) else None
    return validate_style_prompts(presets)


def save_style_prompts(path: str | Path, value: Any) -> dict[str, dict[str, str]]:
    presets = validate_style_prompts(value)
    config_path = Path(path)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = config_path.with_suffix(config_path.suffix + ".tmp")
    temporary.write_text(json.dumps({"version": 1, "presets": presets}, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, config_path)
    return presets


def selected_style_preset(style: str, presets: Mapping[str, Any] | None = None) -> dict[str, str]:
    available = validate_style_prompts(presets) if presets is not None else default_style_prompts()
    return copy.deepcopy(available.get(str(style).strip()) or available["真人影视"])
