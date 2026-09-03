"""Minimal OpenAI-compatible image generation client.

The client deliberately returns only non-sensitive metadata. API responses are
decoded or downloaded directly to a caller-supplied path.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping
from urllib import error, request
from urllib.parse import urlparse


class ImageAPIError(RuntimeError):
    """Raised when image generation or response handling fails."""


USER_AGENT = "Movie-Generation/1.0"


@dataclass(frozen=True)
class ImageAPIConfig:
    api_key: str = ""
    base_url: str = "https://api.openai.com"
    model: str = "gpt-image-2"
    size: str = "1536x1024"
    quality: str = "high"
    timeout: float = 120.0

    @property
    def configured(self) -> bool:
        return bool(self.api_key)


def get_config(environ: Mapping[str, str] | None = None, config_path: str | Path | None = None) -> ImageAPIConfig:
    env = os.environ if environ is None else environ
    file_values: dict[str, Any] = {}
    private_path = config_path or env.get("MOVIE_IMAGE_API_CONFIG_PATH") or env.get("MOVIE_IMAGE_API_CONFIG")
    if private_path:
        try:
            raw = json.loads(Path(private_path).read_text(encoding="utf-8"))
            file_values = raw.get("image_api", raw) if isinstance(raw, dict) else {}
            if not isinstance(file_values, dict):
                file_values = {}
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ImageAPIError("image API config could not be read") from exc
    raw_timeout = env.get("MOVIE_IMAGE_API_TIMEOUT") or env.get("MOVIE_PIPELINE_IMAGE_TIMEOUT") or file_values.get("timeout") or "120"
    try:
        timeout = max(1.0, float(raw_timeout))
    except (TypeError, ValueError):
        timeout = 120.0
    return ImageAPIConfig(
        api_key=(env.get("MOVIE_IMAGE_API_KEY") or env.get("MOVIE_PIPELINE_IMAGE_API_KEY") or env.get("IMAGE_API_KEY") or env.get("OPENAI_API_KEY") or file_values.get("api_key") or file_values.get("apiKey") or "").strip(),
        base_url=(env.get("MOVIE_IMAGE_API_BASE_URL") or env.get("MOVIE_PIPELINE_IMAGE_BASE_URL") or env.get("MOVIE_PIPELINE_IMAGE_API_BASE_URL") or env.get("IMAGE_API_BASE_URL") or env.get("OPENAI_BASE_URL") or file_values.get("base_url") or file_values.get("baseUrl") or "https://api.openai.com").strip().rstrip("/"),
        model=(env.get("MOVIE_IMAGE_API_MODEL") or env.get("MOVIE_PIPELINE_IMAGE_MODEL") or env.get("IMAGE_API_MODEL") or file_values.get("model") or "gpt-image-2").strip() or "gpt-image-2",
        size=str(file_values.get("size") or "1536x1024"),
        quality=str(file_values.get("quality") or "high"),
        timeout=timeout,
    )


def is_configured(environ: Mapping[str, str] | None = None, config_path: str | Path | None = None) -> bool:
    return get_config(environ, config_path=config_path).configured


def _endpoint(base_url: str) -> str:
    base = base_url.rstrip("/")
    if base.endswith("/v1"):
        return base + "/images/generations"
    return base + "/v1/images/generations"


def _read_response(response: Any) -> bytes:
    try:
        return response.read()
    except Exception as exc:
        raise ImageAPIError("image API returned an unreadable response") from exc


def _request_json(opener: Any, req: request.Request, timeout: float) -> Any:
    try:
        with opener(req, timeout=timeout) as response:
            raw = _read_response(response)
    except error.HTTPError as exc:
        detail = ""
        try:
            payload = json.loads(exc.read().decode("utf-8"))
            candidate = payload.get("detail") if isinstance(payload, dict) else None
            if not candidate and isinstance(payload, dict) and isinstance(payload.get("error"), dict):
                candidate = payload["error"].get("message")
            if isinstance(candidate, str):
                detail = " ".join(candidate.split())[:240]
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            pass
        suffix = f": {detail}" if detail else ""
        raise ImageAPIError(f"image API request failed with HTTP {exc.code}{suffix}") from exc
    except ImageAPIError:
        raise
    except Exception as exc:
        raise ImageAPIError("image API request failed") from exc
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ImageAPIError("image API returned invalid JSON") from exc
    if not isinstance(payload, dict):
        raise ImageAPIError("image API returned an invalid payload")
    if payload.get("error"):
        raise ImageAPIError("image API returned an error")
    return payload


def _download(opener: Any, url: str, timeout: float) -> bytes:
    req = request.Request(url, method="GET", headers={"User-Agent": USER_AGENT})
    try:
        with opener(req, timeout=timeout) as response:
            return _read_response(response)
    except ImageAPIError:
        raise
    except Exception as exc:
        raise ImageAPIError("image URL download failed") from exc


def _decode_b64(value: str) -> bytes:
    encoded = value.split(",", 1)[1] if value.startswith("data:") and "," in value else value
    try:
        return base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ImageAPIError("image API returned invalid b64_json") from exc


def generate_image(
    prompt: str,
    output_path: str | Path,
    *,
    size: str | None = None,
    quality: str | None = None,
    model: str | None = None,
    response_format: str = "b64_json",
    n: int = 1,
    config: ImageAPIConfig | None = None,
    opener: Any = request.urlopen,
) -> dict[str, Any]:
    """Generate one image and save it to ``output_path``.

    The returned dictionary contains no API key or response headers. A missing
    API key is explicit and never represented as a successful local image.
    """
    cfg = config or get_config()
    if not cfg.configured:
        raise ImageAPIError("image API is not configured")
    if not prompt or not str(prompt).strip():
        raise ValueError("prompt must not be empty")
    if n != 1:
        raise ValueError("exactly one image is required for a single output path")
    body = {
        "model": model or cfg.model,
        "prompt": prompt,
        "size": size or cfg.size,
        "quality": quality or cfg.quality,
        "n": n,
        "response_format": response_format,
    }
    headers = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
    if cfg.api_key:
        headers["Authorization"] = "Bearer " + cfg.api_key
    req = request.Request(
        _endpoint(cfg.base_url),
        data=json.dumps(body, ensure_ascii=True).encode("utf-8"),
        method="POST",
        headers=headers,
    )
    payload = _request_json(opener, req, cfg.timeout)
    data = payload.get("data")
    if not isinstance(data, list) or not data or not isinstance(data[0], dict):
        raise ImageAPIError("image API response contained no image")
    item = data[0]
    if item.get("b64_json"):
        content = _decode_b64(str(item["b64_json"]))
        source_format = "b64_json"
    elif item.get("url"):
        content = _download(opener, str(item["url"]), cfg.timeout)
        source_format = "url"
    else:
        raise ImageAPIError("image API response contained neither b64_json nor url")
    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)
    return {
        "status": "passed",
        "path": str(destination),
        "format": source_format,
        "model": model or cfg.model,
        "provider": urlparse(cfg.base_url).netloc or "openai-compatible",
        "request_id": payload.get("id"),
        "outputs": [{"filename": destination.name, "path": str(destination), "annotated_path": None}],
    }


class ImageApiClient:
    """Injectable facade for callers and unit tests."""

    def __init__(self, config: ImageAPIConfig | None = None, opener: Any = request.urlopen):
        self.config = config or get_config()
        self.opener = opener

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None, opener: Any = request.urlopen, config_path: str | Path | None = None, config_file: str | Path | None = None) -> "ImageApiClient":
        if config_path or config_file:
            source = dict(os.environ if environ is None else environ)
            source["MOVIE_IMAGE_API_CONFIG_PATH"] = str(config_path or config_file)
            environ = source
        return cls(get_config(environ), opener=opener)

    @property
    def configured(self) -> bool:
        return self.config.configured

    def generate_image(self, prompt: str, output_path: str | Path, **kwargs: Any) -> dict[str, Any]:
        return generate_image(prompt, output_path, config=self.config, opener=self.opener, **kwargs)

    def generate(self, prompt: str, output_path: str | Path, *, size: str | None = None, quality: str | None = None) -> dict[str, Any]:
        return self.generate_image(prompt, output_path, size=size, quality=quality)


ImageAPIClient = ImageApiClient


def generate(prompt: str, output_path: str | Path, *, size: str = "1536x1024", **kwargs: Any) -> dict[str, Any]:
    return generate_image(prompt, output_path, size=size, **kwargs)
