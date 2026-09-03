import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from urllib.error import HTTPError


ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "scripts"))

from video_api_client import VideoAPIConfig, VideoAPIError, VideoApiClient  # noqa: E402


class VideoAPIClientTests(unittest.TestCase):
    @staticmethod
    def _response(payload):
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
        return response

    def test_minimax_i2v_submits_polls_and_downloads_without_exposing_secret(self):
        secret = "video-secret-never-return"
        opener = Mock()
        opener.side_effect = [
            self._response({"task_id": "task-1", "base_resp": {"status_code": 0}}),
            self._response({"status": "Processing"}),
            self._response({"status": "Success", "file_id": "file-1"}),
            self._response({"file": {"download_url": "https://media.example/video.mp4"}}),
            self._response(b"video-bytes"),
        ]
        client = VideoApiClient(
            VideoAPIConfig(
                mode="api",
                api_key=secret,
                base_url="https://api.minimax.io",
                model="MiniMax-Hailuo-02",
                duration=10,
                resolution="768P",
                poll_interval=0,
            ),
            opener=opener,
        )
        with tempfile.TemporaryDirectory() as directory:
            frame = Path(directory) / "frame.png"
            output = Path(directory) / "clip.mp4"
            frame.write_bytes(b"png")
            result = client.generate("Move naturally", frame, output)

            self.assertEqual(b"video-bytes", output.read_bytes())
            self.assertEqual("passed", result["status"])
            self.assertEqual("task-1", result["task_id"])
            self.assertNotIn(secret, json.dumps(result))
            submit = opener.call_args_list[0].args[0]
            self.assertTrue(submit.full_url.endswith("/v1/video_generation"))
            self.assertEqual("Bearer " + secret, submit.headers["Authorization"])
            body = json.loads(submit.data.decode("utf-8"))
            self.assertTrue(body["first_frame_image"].startswith("data:image/png;base64,"))
            self.assertEqual(10, body["duration"])

    def test_missing_key_is_not_configured(self):
        client = VideoApiClient(VideoAPIConfig(mode="api"))
        self.assertFalse(client.configured)
        with tempfile.TemporaryDirectory() as directory:
            frame = Path(directory) / "frame.png"
            frame.write_bytes(b"png")
            with self.assertRaises(VideoAPIError):
                client.generate("prompt", frame, Path(directory) / "clip.mp4")

    def test_http_error_reports_safe_detail(self):
        response = Mock()
        response.read.return_value = json.dumps({"base_resp": {"status_msg": "quota exhausted"}}).encode("utf-8")
        opener = Mock(side_effect=HTTPError("https://api.example", 429, "rate limited", {}, response))
        client = VideoApiClient(VideoAPIConfig(mode="api", api_key="secret", base_url="https://api.example"), opener=opener)
        with tempfile.TemporaryDirectory() as directory:
            frame = Path(directory) / "frame.png"
            frame.write_bytes(b"png")
            with self.assertRaisesRegex(VideoAPIError, "HTTP 429: quota exhausted"):
                client.generate("prompt", frame, Path(directory) / "clip.mp4")


if __name__ == "__main__":
    unittest.main()
