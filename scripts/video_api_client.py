"""MiniMax-compatible image-to-video API client."""

from __future__ import annotations

import base64
import json
import mimetypes
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping
from urllib import error, request
from urllib.parse import urlencode, urlparse


class VideoAPIError(RuntimeError):
    """Raised when video generation or download fails."""


USER_AGENT = "Movie-Generation/1.0"


@dataclass(frozen=True)
class VideoAPIConfig:
    mode: str = "local"
    provider: str = "minimax"
    api_key: str = ""
    base_url: str = "https://api.minimax.io"
    model: str = "MiniMax-Hailuo-02"
    duration: int = 10
    resolution: str = "768P"
    timeout: float = 1800.0
    poll_interval: float = 5.0

    @property
    def configured(self) -> bool:
        return self.mode == "local" or bool(self.api_key)


def get_config(environ: Mapping[str, str] | None = None, config_path: str | Path | None = None) -> VideoAPIConfig:
    env = os.environ if environ is None else environ
    file_values: dict[str, Any] = {}
    private_path = config_path or env.get("MOVIE_VIDEO_API_CONFIG_PATH") or env.get("MOVIE_VIDEO_API_CONFIG")
    if private_path:
        try:
            raw = json.loads(Path(private_path).read_text(encoding="utf-8"))
            file_values = raw.get("video_api", raw) if isinstance(raw, dict) else {}
            if not isinstance(file_values, dict):
                file_values = {}
        except FileNotFoundError:
            file_values = {}
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise VideoAPIError("video API config could not be read") from exc

    def number(name: str, fallback: float) -> float:
        try:
            return max(0.0, float(env.get(name) or file_values.get(name.removeprefix("MOVIE_VIDEO_API_").lower()) or fallback))
        except (TypeError, ValueError):
            return fallback

    try:
        duration = int(env.get("MOVIE_VIDEO_API_DURATION") or file_values.get("duration") or 10)
    except (TypeError, ValueError):
        duration = 10
    return VideoAPIConfig(
        mode=str(env.get("MOVIE_VIDEO_MODE") or file_values.get("mode") or "local").strip().lower(),
        provider=str(env.get("MOVIE_VIDEO_API_PROVIDER") or file_values.get("provider") or "minimax").strip().lower(),
        api_key=str(env.get("MOVIE_VIDEO_API_KEY") or file_values.get("api_key") or "").strip(),
        base_url=str(env.get("MOVIE_VIDEO_API_BASE_URL") or file_values.get("base_url") or "https://api.minimax.io").strip().rstrip("/"),
        model=str(env.get("MOVIE_VIDEO_API_MODEL") or file_values.get("model") or "MiniMax-Hailuo-02").strip(),
        duration=duration,
        resolution=str(env.get("MOVIE_VIDEO_API_RESOLUTION") or file_values.get("resolution") or "768P").strip(),
        timeout=max(1.0, number("MOVIE_VIDEO_API_TIMEOUT", 1800.0)),
        poll_interval=number("MOVIE_VIDEO_API_POLL_INTERVAL", 5.0),
    )


def _endpoint(base_url: str, path: str) -> str:
    base = base_url.rstrip("/")
    suffix = path.removeprefix("/v1") if base.endswith("/v1") else path
    return base + suffix


def _safe_detail(payload: Any) -> str:
    if not isinstance(payload, dict):
        return ""
    candidates = [
        payload.get("detail"),
        payload.get("message"),
        (payload.get("error") or {}).get("message") if isinstance(payload.get("error"), dict) else None,
        (payload.get("base_resp") or {}).get("status_msg") if isinstance(payload.get("base_resp"), dict) else None,
    ]
    return next((" ".join(value.split())[:240] for value in candidates if isinstance(value, str) and value.strip()), "")


def _read(opener: Any, req: request.Request, timeout: float) -> bytes:
    try:
        with opener(req, timeout=timeout) as response:
            return response.read()
    except error.HTTPError as exc:
        detail = ""
        try:
            detail = _safe_detail(json.loads(exc.read().decode("utf-8")))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            pass
        raise VideoAPIError(f"video API request failed with HTTP {exc.code}{': ' + detail if detail else ''}") from exc
    except Exception as exc:
        raise VideoAPIError("video API request failed") from exc


def _json_request(opener: Any, req: request.Request, timeout: float) -> dict[str, Any]:
    raw = _read(opener, req, timeout)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise VideoAPIError("video API returned invalid JSON") from exc
    if not isinstance(payload, dict):
        raise VideoAPIError("video API returned an invalid payload")
    base_resp = payload.get("base_resp")
    if isinstance(base_resp, dict) and int(base_resp.get("status_code") or 0) != 0:
        raise VideoAPIError("video API returned an error" + (f": {_safe_detail(payload)}" if _safe_detail(payload) else ""))
    return payload


def _auth_headers(api_key: str, *, json_body: bool = False) -> dict[str, str]:
    headers = {"Authorization": "Bearer " + api_key, "User-Agent": USER_AGENT}
    if json_body:
        headers["Content-Type"] = "application/json"
    return headers


def _first_frame_data(path: Path) -> str:
    if not path.is_file():
        raise VideoAPIError("video first frame does not exist")
    mime = mimetypes.guess_type(path.name)[0] or "image/png"
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode("ascii")


class VideoApiClient:
    def __init__(self, config: VideoAPIConfig | None = None, opener: Any = request.urlopen):
        self.config = config or get_config()
        self.opener = opener

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None, opener: Any = request.urlopen, config_path: str | Path | None = None) -> "VideoApiClient":
        return cls(get_config(environ, config_path=config_path), opener=opener)

    @property
    def configured(self) -> bool:
        return self.config.configured

    def generate(self, prompt: str, first_frame: str | Path, output_path: str | Path) -> dict[str, Any]:
        cfg = self.config
        if cfg.mode != "api" or not cfg.api_key:
            raise VideoAPIError("video API is not configured")
        if cfg.provider != "minimax":
            raise VideoAPIError("unsupported video API provider")
        if not str(prompt or "").strip():
            raise ValueError("prompt must not be empty")
        body = {
            "model": cfg.model,
            "prompt": str(prompt).strip(),
            "first_frame_image": _first_frame_data(Path(first_frame)),
            "duration": cfg.duration,
            "resolution": cfg.resolution,
            "prompt_optimizer": True,
        }
        submit = request.Request(
            _endpoint(cfg.base_url, "/v1/video_generation"),
            data=json.dumps(body, ensure_ascii=True).encode("utf-8"),
            method="POST",
            headers=_auth_headers(cfg.api_key, json_body=True),
        )
        payload = _json_request(self.opener, submit, min(cfg.timeout, 120))
        task_id = str(payload.get("task_id") or "").strip()
        if not task_id:
            raise VideoAPIError("video API response contained no task_id")
        deadline = time.monotonic() + cfg.timeout
        file_id = ""
        while time.monotonic() <= deadline:
            query_url = _endpoint(cfg.base_url, "/v1/query/video_generation") + "?" + urlencode({"task_id": task_id})
            status_payload = _json_request(
                self.opener,
                request.Request(query_url, method="GET", headers=_auth_headers(cfg.api_key)),
                min(cfg.timeout, 60),
            )
            status = str(status_payload.get("status") or "").strip().lower()
            if status == "success":
                file_id = str(status_payload.get("file_id") or "").strip()
                break
            if status in {"fail", "failed", "error"}:
                raise VideoAPIError("video API generation failed" + (f": {_safe_detail(status_payload)}" if _safe_detail(status_payload) else ""))
            if cfg.poll_interval > 0:
                time.sleep(min(cfg.poll_interval, max(0, deadline - time.monotonic())))
            else:
                continue
        if not file_id:
            raise VideoAPIError("video API generation timed out or returned no file_id")
        file_url = _endpoint(cfg.base_url, "/v1/files/retrieve") + "?" + urlencode({"file_id": file_id})
        file_payload = _json_request(
            self.opener,
            request.Request(file_url, method="GET", headers=_auth_headers(cfg.api_key)),
            min(cfg.timeout, 60),
        )
        file_data = file_payload.get("file") if isinstance(file_payload.get("file"), dict) else {}
        download_url = str(file_data.get("download_url") or "").strip()
        if not download_url:
            raise VideoAPIError("video API response contained no download URL")
        content = _read(
            self.opener,
            request.Request(download_url, method="GET", headers=_auth_headers(cfg.api_key)),
            cfg.timeout,
        )
        destination = Path(output_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        return {
            "status": "passed",
            "provider": urlparse(cfg.base_url).netloc or "minimax-compatible",
            "model": cfg.model,
            "task_id": task_id,
            "file_id": file_id,
            "outputs": [{"filename": destination.name, "path": str(destination)}],
        }


VideoAPIClient = VideoApiClient
