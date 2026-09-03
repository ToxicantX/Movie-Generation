import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from text_model_client import TextModelClient, get_config  # noqa: E402


class TextModelConfigTests(unittest.TestCase):
    def test_reads_local_json_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "text_api.local.json"
            path.write_text(
                json.dumps({"text_api": {"api_key": "secret", "base_url": "https://api.example/v1/", "model": "text-model", "timeout": 90}}),
                encoding="utf-8",
            )
            config = get_config({}, path)
            self.assertTrue(config.configured)
            self.assertEqual("https://api.example/v1", config.base_url)
            self.assertEqual("text-model", config.model)
            self.assertEqual(90, config.timeout)
            self.assertTrue(TextModelClient(config_path=path).configured)

    def test_environment_overrides_local_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "text_api.local.json"
            path.write_text(json.dumps({"text_api": {"api_key": "file-key", "model": "file-model"}}), encoding="utf-8")
            config = get_config(
                {
                    "MOVIE_PIPELINE_TEXT_API_KEY": "env-key",
                    "MOVIE_PIPELINE_TEXT_BASE_URL": "https://env.example/v1",
                    "MOVIE_PIPELINE_TEXT_MODEL": "env-model",
                    "MOVIE_PIPELINE_TEXT_TIMEOUT": "45",
                },
                path,
            )
            self.assertEqual(("env-key", "https://env.example/v1", "env-model", 45), (config.api_key, config.base_url, config.model, config.timeout))


if __name__ == "__main__":
    unittest.main()
