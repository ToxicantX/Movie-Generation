import argparse
import json
import mimetypes
import subprocess
from datetime import datetime
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
MANIFESTS = ROOT / "manifests"
DEFAULT_REVIEW_PACKAGES = Path(r"G:\ComfyUI\output\AIShortDrama\review_packages")
ALLOWED_ASSET_ROOTS = [
    Path(r"G:\ComfyUI\output\AIShortDrama").resolve(),
]
ALLOWED_ASSET_SUFFIXES = {
    ".jpg",
    ".jpeg",
    ".png",
    ".webp",
    ".gif",
    ".mp4",
    ".webm",
    ".mov",
}


def run_ps(script: Path, *args: str, allow_nonzero: bool = False) -> dict:
    cmd = [
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        *args,
    ]
    completed = subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    stdout = completed.stdout.strip()
    parsed = None
    if stdout:
        try:
            parsed = json.loads(stdout)
        except json.JSONDecodeError:
            parsed = None
    return {
        "ok": completed.returncode == 0 or allow_nonzero,
        "exit_code": completed.returncode,
        "stdout": stdout,
        "stderr": completed.stderr.strip(),
        "json": parsed,
        "command": cmd,
    }


def read_json(path: str | Path):
    path = Path(path)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def summarize_step(result: dict) -> dict:
    payload = result.get("json") if isinstance(result.get("json"), dict) else {}
    summary = {
        "ok": result.get("ok"),
        "exit_code": result.get("exit_code"),
        "stderr": result.get("stderr", "")[-1000:],
    }
    for key in ("updated", "state", "ok", "queue_count", "failure_count", "invalid_count", "missing_count", "stale_count", "unsafe_pass_count"):
        if key in payload:
            summary[key] = payload[key]
    if "counts" in payload:
        summary["counts"] = payload["counts"]
    if "summary" in payload:
        summary["summary"] = payload["summary"]
    return summary


def summarize_precheck(data):
    if not isinstance(data, dict):
        return None
    return {
        "ok": data.get("ok"),
        "counts": data.get("counts"),
        "invalid_count": data.get("invalid_count"),
        "missing_count": data.get("missing_count"),
        "stale_count": data.get("stale_count"),
        "unsafe_pass_count": data.get("unsafe_pass_count"),
        "warning_count": data.get("warning_count"),
        "ready_for_apply": data.get("ready_for_apply"),
        "formal_segments_all_marked_pass": data.get("formal_segments_all_marked_pass"),
    }


def summarize_queue(data):
    if not isinstance(data, dict):
        return None
    return {
        "ok": data.get("ok"),
        "queue_count": data.get("queue_count"),
        "summary": data.get("summary"),
        "runs_ready": len(data.get("queue", []) or []),
    }


def summarize_queue_run(data):
    if not isinstance(data, dict):
        return None
    return {
        "ok": data.get("ok"),
        "dry_run": data.get("dry_run"),
        "runs": len(data.get("runs", []) or []),
        "skipped": len(data.get("skipped", []) or []),
    }


def summarize_gate(data):
    if not isinstance(data, dict):
        return None
    return {
        "ok": data.get("ok"),
        "failure_count": data.get("failure_count"),
        "skipped_segment_cut_checks": data.get("skipped_segment_cut_checks"),
    }


def is_allowed_asset(path: Path) -> bool:
    try:
        resolved = path.resolve()
    except Exception:
        return False
    if resolved.suffix.lower() not in ALLOWED_ASSET_SUFFIXES:
        return False
    return any(resolved == root or root in resolved.parents for root in ALLOWED_ASSET_ROOTS)


class ReviewHandler(SimpleHTTPRequestHandler):
    server_version = "EP01HumanReviewServer/1.0"

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            return self.write_json(self.server.build_status())
        if parsed.path == "/api/asset":
            return self.serve_asset(parsed)
        if parsed.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        return super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/decision":
            self.send_error(404, "Not found")
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:
            self.write_json({"ok": False, "error": f"Invalid JSON: {exc}"}, 400)
            return

        shot_id = str(payload.get("shot_id", "")).strip()
        decision = str(payload.get("decision", "")).strip()
        reason = str(payload.get("reason", "")).strip()
        notes = str(payload.get("notes", "")).strip()
        scope = str(payload.get("regeneration_scope", "")).strip()
        if decision not in {"pending", "pass", "needs_regeneration", "blocked"}:
            self.write_json({"ok": False, "error": "Invalid decision."}, 400)
            return
        if scope and scope not in {"storyboard", "video", "segment", "episode"}:
            self.write_json({"ok": False, "error": "Invalid regeneration_scope."}, 400)
            return
        if not shot_id:
            self.write_json({"ok": False, "error": "Missing shot_id."}, 400)
            return

        result = self.server.set_decision(shot_id, decision, scope, reason, notes)
        status = 200 if result.get("ok") else 500
        self.write_json(result, status)

    def serve_asset(self, parsed):
        values = parse_qs(parsed.query).get("path", [])
        if not values:
            self.send_error(400, "Missing path")
            return
        asset_path = Path(values[0])
        if not asset_path.exists() or not asset_path.is_file() or not is_allowed_asset(asset_path):
            self.send_error(404, "Asset not found")
            return

        mime_type = mimetypes.guess_type(str(asset_path))[0] or "application/octet-stream"
        try:
            stat = asset_path.stat()
            start = 0
            end = stat.st_size - 1
            range_header = self.headers.get("Range", "")
            if range_header.startswith("bytes="):
                range_value = range_header.split("=", 1)[1].split(",", 1)[0].strip()
                if "-" in range_value:
                    start_text, end_text = range_value.split("-", 1)
                    if start_text:
                        start = int(start_text)
                    if end_text:
                        end = int(end_text)
                if start < 0 or end < start or start >= stat.st_size:
                    self.send_error(416, "Requested Range Not Satisfiable")
                    return
                end = min(end, stat.st_size - 1)
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{stat.st_size}")
            else:
                self.send_response(200)
            content_length = end - start + 1
            self.send_header("Content-Type", mime_type)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(content_length))
            self.end_headers()
            with asset_path.open("rb") as handle:
                handle.seek(start)
                remaining = content_length
                while True:
                    chunk = handle.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
                    if remaining <= 0:
                        break
        except BrokenPipeError:
            pass

    def write_json(self, payload: dict, status: int = 200):
        data = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ReviewServer(ThreadingHTTPServer):
    def __init__(self, server_address, handler_cls, args):
        super().__init__(server_address, handler_cls)
        self.args = args

    def set_decision(self, shot_id: str, decision: str, scope: str, reason: str, notes: str) -> dict:
        set_args = [
            "-DecisionPath",
            self.args.decision_path,
            "-ShotId",
            shot_id,
            "-Decision",
            decision,
            "-ResultPath",
            self.args.set_result_path,
        ]
        if scope:
            set_args += ["-RegenerationScope", scope]
        if reason:
            set_args += ["-Reason", reason]
        if notes:
            set_args += ["-Notes", notes]
        set_result = run_ps(SCRIPTS / "set_ep01_human_review_decision.ps1", *set_args)
        if not set_result["ok"]:
            return {"ok": False, "stage": "set_decision", "result": set_result}

        driver_result = self.run_driver()
        dashboard_result = self.build_dashboard()
        status = self.build_status()
        ok = bool(dashboard_result.get("ok") and driver_result.get("ok"))
        return {
            "ok": ok,
            "set_decision": set_result.get("json") or set_result,
            "dashboard": dashboard_result,
            "driver": driver_result,
            "status": status,
        }

    def build_dashboard(self) -> dict:
        result = run_ps(
            SCRIPTS / "build_ep01_human_review_dashboard.ps1",
            "-DecisionPath",
            self.args.decision_path,
            "-OutputPath",
            self.args.dashboard_path,
            "-ResultPath",
            self.args.dashboard_result_path,
            "-ApiBaseUrl",
            self.args.api_base_url,
        )
        return result.get("json") or result

    def run_driver(self) -> dict:
        steps = []

        precheck = run_ps(
            SCRIPTS / "test_ep01_human_review_decisions.ps1",
            "-DecisionPath",
            self.args.decision_path,
            "-ResultPath",
            self.args.precheck_result_path,
            allow_nonzero=True,
        )
        steps.append({"name": "precheck_decisions", "result": precheck})

        queue = run_ps(
            SCRIPTS / "build_human_review_regeneration_queue.ps1",
            "-DecisionPath",
            self.args.decision_path,
            "-QueuePath",
            self.args.queue_path,
            "-IncludeTechnicalFallback",
        )
        steps.append({"name": "build_regeneration_queue", "result": queue})

        queue_data = read_json(self.args.queue_path)
        queue_count = int(queue_data.get("queue_count", 0)) if isinstance(queue_data, dict) else 0
        if queue_count > 0:
            queue_run = run_ps(
                SCRIPTS / "run_regeneration_queue.ps1",
                "-QueuePath",
                self.args.queue_path,
                "-ResultPath",
                self.args.queue_run_result_path,
                "-DryRun",
                allow_nonzero=True,
            )
            steps.append({"name": "run_regeneration_queue_dry_run", "result": queue_run})

        gate = run_ps(
            SCRIPTS / "test_ep01_formal_cut_gate.ps1",
            "-ResultPath",
            self.args.formal_gate_result_path,
            "-SkipSegmentCutChecks",
            allow_nonzero=True,
        )
        steps.append({"name": "formal_cut_gate_dry_check", "result": gate})

        precheck_data = read_json(self.args.precheck_result_path)
        queue_data = read_json(self.args.queue_path)
        queue_run_data = read_json(self.args.queue_run_result_path)
        gate_data = read_json(self.args.formal_gate_result_path)

        driver = {
            "updated": datetime.now().isoformat(timespec="seconds"),
            "decision_path": self.args.decision_path,
            "precheck_result_path": self.args.precheck_result_path,
            "queue_path": self.args.queue_path,
            "queue_run_result_path": self.args.queue_run_result_path,
            "formal_gate_result_path": self.args.formal_gate_result_path,
            "steps": [{"name": step["name"], "result": summarize_step(step["result"])} for step in steps],
            "precheck": summarize_precheck(precheck_data),
            "regeneration_queue": summarize_queue(queue_data),
            "queue_run": summarize_queue_run(queue_run_data),
            "formal_gate": summarize_gate(gate_data),
        }
        driver["ok"] = bool(precheck["ok"] and queue["ok"])
        counts = (driver.get("precheck") or {}).get("counts") or {}
        pending = int(counts.get("pending", 0))
        queue_summary = driver.get("regeneration_queue") or {}
        gate_summary = driver.get("formal_gate") or {}
        if queue_summary.get("queue_count", 0) > 0:
            driver["state"] = "regeneration_queue_ready_dry_run_verified"
        elif gate_summary.get("ok"):
            driver["state"] = "formal_cut_ready_to_build"
        elif pending > 0:
            driver["state"] = "awaiting_human_review"
        else:
            driver["state"] = "human_decisions_recorded_pending_formal_gate"

        Path(self.args.driver_result_path).parent.mkdir(parents=True, exist_ok=True)
        Path(self.args.driver_result_path).write_text(
            json.dumps(driver, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        return driver

    def build_status(self) -> dict:
        decision_path = Path(self.args.decision_path)
        payload = {
            "ok": True,
            "kind": "ep01_human_review",
            "decision_path": str(decision_path),
            "dashboard_path": self.args.dashboard_path,
            "driver_result_path": self.args.driver_result_path,
        }
        for key, path in {
            "driver": self.args.driver_result_path,
            "dashboard": self.args.dashboard_result_path,
            "decisions": decision_path,
            "precheck": self.args.precheck_result_path,
            "queue": self.args.queue_path,
            "formal_gate": self.args.formal_gate_result_path,
        }.items():
            payload[key] = read_json(path)
        return payload


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8097)
    parser.add_argument("--directory", default=str(DEFAULT_REVIEW_PACKAGES))
    parser.add_argument("--decision-path", default=str(MANIFESTS / "human_review_decisions_ep01.json"))
    parser.add_argument("--dashboard-path", default=str(DEFAULT_REVIEW_PACKAGES / "SSJ_EP01_HUMAN_REVIEW_DASHBOARD.html"))
    parser.add_argument("--dashboard-result-path", default=str(MANIFESTS / "ep01_human_review_dashboard_result.json"))
    parser.add_argument("--set-result-path", default=str(MANIFESTS / "ep01_human_review_decision_set_result.json"))
    parser.add_argument("--precheck-result-path", default=str(MANIFESTS / "human_review_decisions_ep01_precheck.json"))
    parser.add_argument("--queue-path", default=str(MANIFESTS / "regeneration_queue_ep01.json"))
    parser.add_argument("--queue-run-result-path", default=str(MANIFESTS / "regeneration_queue_ep01_dry_run_result.json"))
    parser.add_argument("--formal-gate-result-path", default=str(MANIFESTS / "ep01_formal_cut_gate_check.json"))
    parser.add_argument("--driver-result-path", default=str(MANIFESTS / "ep01_human_review_click_driver_result.json"))
    args = parser.parse_args()
    args.api_base_url = f"http://{args.host}:{args.port}"
    return args


def main():
    args = parse_args()
    directory = Path(args.directory)
    directory.mkdir(parents=True, exist_ok=True)
    handler_cls = lambda *handler_args, **kwargs: ReviewHandler(
        *handler_args, directory=str(directory), **kwargs
    )
    server = ReviewServer((args.host, args.port), handler_cls, args)
    server.build_dashboard()
    print(f"EP01 human review server: http://{args.host}:{args.port}/SSJ_EP01_HUMAN_REVIEW_DASHBOARD.html", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
