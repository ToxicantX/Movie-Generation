import importlib.util
import json
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("movie_console_server", ROOT / "console" / "server.py")
SERVER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(SERVER)


class ConsoleDataTests(unittest.TestCase):
    def test_status_uses_real_scene_manifests(self):
        payload = SERVER.load_status_payload()
        self.assertEqual("AI短剧生成工厂", payload["project"])
        self.assertGreaterEqual(payload["summary"]["completed_scenes"], 46)
        self.assertEqual("SC47", payload["summary"]["next_scene"])
        self.assertEqual("SC46", payload["scenes"][-1]["id"])
        self.assertGreaterEqual(payload["scenes"][-1]["shot_count"], 4)

    def test_media_access_rejects_paths_outside_project_and_output(self):
        outside = Path(Path(__file__).resolve().anchor) / "Windows" / "System32" / "drivers" / "etc" / "hosts"
        self.assertFalse(SERVER.is_allowed_media(outside))
        self.assertTrue(SERVER.is_allowed_media(ROOT / "README.md"))
        local_output = SERVER.LOCAL_OUTPUT_ROOT / "media-allowlist-test.mp4"
        local_output.parent.mkdir(parents=True, exist_ok=True)
        local_output.write_bytes(b"test")
        try:
            self.assertTrue(SERVER.is_allowed_media(local_output))
        finally:
            local_output.unlink(missing_ok=True)


class ConsoleHttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = SERVER.create_server("127.0.0.1", 0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def get_json(self, path):
        with urlopen(self.base_url + path, timeout=10) as response:
            return response.status, json.loads(response.read().decode("utf-8"))

    def test_status_endpoint(self):
        status, payload = self.get_json("/api/status")
        self.assertEqual(200, status)
        self.assertEqual("SC47", payload["summary"]["next_scene"])

    def test_scene_detail_endpoint(self):
        status, payload = self.get_json("/api/scenes/SC46")
        self.assertEqual(200, status)
        self.assertEqual("SC46", payload["id"])
        self.assertEqual(4, len(payload["shots"]))

    def test_video_frame_endpoint(self):
        scene_status, scene = self.get_json("/api/scenes/SC46")
        self.assertEqual(200, scene_status)
        media_path = scene["formal_cut"]["file"]["path"]
        from urllib.parse import quote

        with urlopen(f"{self.base_url}/video-frame?path={quote(media_path, safe='')}&time=40", timeout=15) as response:
            data = response.read()
            self.assertEqual(200, response.status)
            self.assertEqual("image/jpeg", response.headers.get_content_type())
            self.assertGreater(len(data), 1000)

    def test_unknown_action_is_rejected(self):
        request = Request(
            self.base_url + "/api/jobs",
            data=json.dumps({"action": "delete_everything"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(HTTPError) as error:
            urlopen(request, timeout=10)
        self.assertEqual(400, error.exception.code)


if __name__ == "__main__":
    unittest.main()
