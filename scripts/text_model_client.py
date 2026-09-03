"""Small OpenAI-compatible JSON client used by the local movie pipeline."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping
from urllib import request


@dataclass(frozen=True)
class TextModelConfig:
    api_key: str = ""
    base_url: str = "http://127.0.0.1:11434/v1"
    model: str = ""
    timeout: float = 120.0

    @property
    def configured(self) -> bool:
        return bool(self.api_key and self.model)


def _read_file_config(config_path: str | os.PathLike[str] | None) -> dict[str, Any]:
    if not config_path:
        return {}
    path = Path(config_path)
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("text model configuration could not be read") from exc
    settings = value.get("text_api", value) if isinstance(value, dict) else {}
    if not isinstance(settings, dict):
        raise ValueError("text model configuration is invalid")
    return settings


def get_config(environ: Mapping[str, str] | None = None, config_path: str | os.PathLike[str] | None = None) -> TextModelConfig:
    env = os.environ if environ is None else environ
    file_values = _read_file_config(config_path)
    try:
        timeout = float(env.get("MOVIE_PIPELINE_TEXT_TIMEOUT") or file_values.get("timeout") or 120)
    except (TypeError, ValueError):
        timeout = 120.0
    return TextModelConfig(
        api_key=str(env.get("MOVIE_PIPELINE_TEXT_API_KEY") or file_values.get("api_key") or "").strip(),
        base_url=str(env.get("MOVIE_PIPELINE_TEXT_BASE_URL") or file_values.get("base_url") or "http://127.0.0.1:11434/v1").strip().rstrip("/"),
        model=str(env.get("MOVIE_PIPELINE_TEXT_MODEL") or file_values.get("model") or "").strip(),
        timeout=max(1.0, timeout),
    )


def is_configured(environ: Mapping[str, str] | None = None) -> bool:
    return get_config(environ).configured


def extract_json(value: Any) -> Any:
    """Extract JSON from a model response, including markdown fenced output."""
    if isinstance(value, (dict, list)):
        return value
    text = str(value or "").strip()
    fenced = re.search(r"```(?:json)?\s*(.*?)\s*```", text, flags=re.I | re.S)
    candidates = [fenced.group(1)] if fenced else []
    candidates.append(text)
    for candidate in candidates:
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass
        for opener, closer in (("{", "}"), ("[", "]")):
            start, end = candidate.find(opener), candidate.rfind(closer)
            if start >= 0 and end > start:
                try:
                    return json.loads(candidate[start : end + 1])
                except json.JSONDecodeError:
                    continue
    raise ValueError("text model response did not contain valid JSON")


def request_json(
    prompt: str,
    *,
    system: str = "Return only valid JSON.",
    required_schema: Mapping[str, Any] | None = None,
    config: TextModelConfig | None = None,
    opener: Any = request.urlopen,
) -> tuple[Any, dict[str, Any]]:
    """Call /chat/completions and return (JSON payload, auditable metadata)."""
    cfg = config or get_config()
    if not cfg.configured:
        return None, {"configured": False, "used": False, "reason": "not_configured"}
    messages = [{"role": "system", "content": system}, {"role": "user", "content": prompt}]
    if required_schema:
        messages[0]["content"] += "\nRequired JSON shape:\n" + json.dumps(required_schema, ensure_ascii=True)
    body = json.dumps({"model": cfg.model, "messages": messages, "temperature": 0.2}).encode("utf-8")
    endpoint = cfg.base_url + ("" if cfg.base_url.endswith("/chat/completions") else "/chat/completions")
    req = request.Request(endpoint, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer " + cfg.api_key,
    })
    with opener(req, timeout=cfg.timeout) as response:
        raw = response.read().decode("utf-8")
    envelope = json.loads(raw)
    content = envelope.get("choices", [{}])[0].get("message", {}).get("content", "")
    return extract_json(content), {"configured": True, "used": True, "model": cfg.model, "base_url": cfg.base_url}


class TextModelClient:
    """Injectable facade that keeps pipeline tests independent from the network."""

    def __init__(self, config: TextModelConfig | None = None, opener: Any = request.urlopen, config_path: str | os.PathLike[str] | None = None):
        self.config = config or get_config(config_path=config_path)
        self.opener = opener

    @property
    def configured(self) -> bool:
        return self.config.configured

    def request_json(self, prompt: str, required_schema: Mapping[str, Any] | None = None) -> tuple[Any, dict[str, Any]]:
        return request_json(prompt, required_schema=required_schema, config=self.config, opener=self.opener)
