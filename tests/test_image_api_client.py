import base64
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from urllib import error

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from image_api_client import ImageAPIConfig, ImageAPIError, ImageApiClient, generate_image  # noqa: E402


class _Response:
    def __init__(self, content):
        self.content = content

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self.content


class ImageAPIClientTests(unittest.TestCase):
    def test_b64_json_posts_expected_endpoint_and_saves_without_secret(self):
        secret = "test-secret-do-not-return"
        image = b"fake-png"
        opener = Mock(return_value=_Response(json.dumps({"data": [{"b64_json": base64.b64encode(image).decode()}]}).encode()))
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "nested" / "image.png"
            result = generate_image("A quiet valley", destination, config=ImageAPIConfig(api_key=secret, base_url="https://api.openai.com"), opener=opener)
            self.assertEqual(destination.read_bytes(), image)
            self.assertEqual(result["format"], "b64_json")
            self.assertNotIn(secret, json.dumps(result))
            req = opener.call_args.args[0]
            self.assertEqual(req.full_url, "https://api.openai.com/v1/images/generations")
            request_body = json.loads(req.data)
            self.assertEqual(request_body["prompt"], "A quiet valley")
            self.assertEqual(request_body["model"], "gpt-image-2")
            self.assertEqual(req.get_header("Authorization"), "Bearer " + secret)
            self.assertEqual(req.get_header("User-agent"), "Movie-Generation/1.0")

    def test_url_response_is_downloaded(self):
        opener = Mock(side_effect=[_Response(json.dumps({"data": [{"url": "https://cdn.example/image.png"}]}).encode()), _Response(b"url-image")])
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "image.png"
            result = generate_image("A boat", destination, response_format="url", config=ImageAPIConfig(api_key="key"), opener=opener)
            self.assertEqual(destination.read_bytes(), b"url-image")
            self.assertEqual(result["format"], "url")
            self.assertEqual(opener.call_args_list[1].args[0].full_url, "https://cdn.example/image.png")
            self.assertEqual(opener.call_args_list[1].args[0].get_header("User-agent"), "Movie-Generation/1.0")

    def test_missing_configuration_is_explicit(self):
        with self.assertRaisesRegex(ImageAPIError, "not configured"):
            generate_image("A prompt", "unused.png", config=ImageAPIConfig(base_url="https://api.openai.com"))

    def test_invalid_response_does_not_create_file(self):
        opener = Mock(return_value=_Response(json.dumps({"data": []}).encode()))
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "image.png"
            with self.assertRaises(ImageAPIError):
                generate_image("A prompt", destination, config=ImageAPIConfig(api_key="key"), opener=opener)
            self.assertFalse(destination.exists())

    def test_http_error_reports_status_and_safe_detail(self):
        body = json.dumps({"error": {"message": "No image provider account is available."}}).encode()
        failure = error.HTTPError("https://api.example/v1/images/generations", 503, "Unavailable", {}, io.BytesIO(body))
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "image.png"
            with self.assertRaisesRegex(ImageAPIError, r"HTTP 503: No image provider account is available"):
                generate_image("A prompt", destination, config=ImageAPIConfig(api_key="key", base_url="https://api.example"), opener=Mock(side_effect=failure))
            self.assertFalse(destination.exists())

    def test_from_env_reads_private_json_config_without_returning_key(self):
        secret = "private-key"
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "image.json"
            config_path.write_text(json.dumps({"api_key": secret, "base_url": "https://api.example", "model": "image-model"}), encoding="utf-8")
            client = ImageApiClient.from_env({}, config_path=config_path)
            self.assertTrue(client.configured)
            self.assertEqual(client.config.base_url, "https://api.example")
            self.assertEqual(client.config.model, "image-model")
            self.assertNotIn(secret, json.dumps({"configured": client.configured}))


if __name__ == "__main__":
    unittest.main()
