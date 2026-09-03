import argparse
import json
import subprocess
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
MANIFESTS = ROOT / "manifests"
DEFAULT_REVIEW_PACKAGES = Path(r"G:\ComfyUI\output\AIShortDrama\review_packages")


def run_ps(script: Path, *args: str) -> dict:
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
        "ok": completed.returncode == 0,
        "exit_code": completed.returncode,
        "stdout": stdout,
        "stderr": completed.stderr.strip(),
        "json": parsed,
        "command": cmd,
    }


class ReviewHandler(SimpleHTTPRequestHandler):
    server_version = "StoryboardReviewServer/1.0"

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            return self.write_json(self.server.build_status())
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
        if decision not in {"pending", "pass", "needs_regeneration", "blocked"}:
            self.write_json({"ok": False, "error": "Invalid decision."}, 400)
            return
        if not shot_id:
            self.write_json({"ok": False, "error": "Missing shot_id."}, 400)
            return

        result = self.server.set_decision(shot_id, decision, reason, notes)
        status = 200 if result.get("ok") else 500
        self.write_json(result, status)

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

    def set_decision(self, shot_id: str, decision: str, reason: str, notes: str) -> dict:
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
        if reason:
            set_args += ["-Reason", reason]
        if notes:
            set_args += ["-Notes", notes]
        set_result = run_ps(SCRIPTS / "set_storyboard_review_decision.ps1", *set_args)
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
            SCRIPTS / "build_storyboard_review_dashboard.ps1",
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
        result = run_ps(
            SCRIPTS / "run_ep02_sc01_storyboard_to_i2v_pipeline.ps1",
            "-DecisionPath",
            self.args.decision_path,
            "-QueuePath",
            self.args.queue_path,
            "-CycleResultPath",
            self.args.cycle_result_path,
            "-PrecheckResultPath",
            self.args.precheck_result_path,
            "-QueueRunResultPath",
            self.args.queue_run_result_path,
            "-DashboardOutputPath",
            self.args.dashboard_path,
            "-DashboardResultPath",
            self.args.dashboard_result_path,
            "-ResultPath",
            self.args.driver_result_path,
            "-SkipMarkdownImport",
        )
        return result.get("json") or result

    def build_status(self) -> dict:
        driver_path = Path(self.args.driver_result_path)
        dashboard_result_path = Path(self.args.dashboard_result_path)
        decision_path = Path(self.args.decision_path)
        payload = {
            "ok": True,
            "decision_path": str(decision_path),
            "dashboard_path": self.args.dashboard_path,
            "driver_result_path": str(driver_path),
        }
        for key, path in {
            "driver": driver_path,
            "dashboard": dashboard_result_path,
            "decisions": decision_path,
        }.items():
            if path.exists():
                try:
                    payload[key] = json.loads(path.read_text(encoding="utf-8-sig"))
                except Exception as exc:
                    payload[key] = {"ok": False, "error": str(exc)}
            else:
                payload[key] = None
        return payload


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8098)
    parser.add_argument("--directory", default=str(DEFAULT_REVIEW_PACKAGES))
    parser.add_argument("--decision-path", default=str(MANIFESTS / "storyboard_review_decisions_ep02_sc01.json"))
    parser.add_argument("--dashboard-path", default=str(DEFAULT_REVIEW_PACKAGES / "SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html"))
    parser.add_argument("--dashboard-result-path", default=str(MANIFESTS / "storyboard_review_dashboard_ep02_sc01_result.json"))
    parser.add_argument("--set-result-path", default=str(MANIFESTS / "storyboard_review_decision_set_result.json"))
    parser.add_argument("--queue-path", default=str(MANIFESTS / "storyboard_i2v_queue_ep02_sc01.json"))
    parser.add_argument("--cycle-result-path", default=str(MANIFESTS / "storyboard_review_cycle_ep02_sc01_result.json"))
    parser.add_argument("--precheck-result-path", default=str(MANIFESTS / "storyboard_review_decisions_ep02_sc01_precheck.json"))
    parser.add_argument("--queue-run-result-path", default=str(MANIFESTS / "storyboard_i2v_queue_ep02_sc01_run_result.json"))
    parser.add_argument("--driver-result-path", default=str(MANIFESTS / "ep02_sc01_storyboard_to_i2v_pipeline_result.json"))
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
    print(f"Storyboard review server: http://{args.host}:{args.port}/SSJ_EP02_SC01_STORYBOARD_DASHBOARD.html", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
