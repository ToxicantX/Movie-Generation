import importlib.util
import json
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("movie_console_server_local_pipeline", ROOT / "console" / "server.py")
SERVER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(SERVER)


class LocalValidationTests(unittest.TestCase):
    def test_console_layout_contract_covers_all_modules_and_viewports(self):
        html = (ROOT / "console" / "static" / "index.html").read_text(encoding="utf-8")
        styles = (ROOT / "console" / "static" / "styles.css").read_text(encoding="utf-8")

        self.assertIn('class="layout-v7"', html)
        self.assertIn("styles.css?v=20260903-prompt-review", html)
        for module in ("home", "projects", "production", "scenes", "reviews", "tasks"):
            self.assertIn(f'data-module-view="{module}"', html)
        self.assertIn('id="pipelineUnitFilter"', html)
        self.assertIn('id="pipelineStyleForm"', html)
        self.assertIn('id="pipelinePrimaryStyle"', html)
        self.assertIn('<option value="真人影视">真人影视</option>', html)
        self.assertIn('<option value="二维动漫">二维动漫</option>', html)
        self.assertIn('<option value="三维动画">三维动画</option>', html)
        self.assertNotIn('id="pipelineStyleText"', html)
        self.assertNotIn('id="pipelineColorLanguage"', html)
        self.assertNotIn('id="pipelineCameraLanguage"', html)
        self.assertIn('id="pipelineStoryBible"', html)
        self.assertIn('id="stylePromptsForm"', html)
        self.assertIn('data-style-prompt-style="真人影视"', html)
        self.assertIn('data-style-prompt-style="二维动漫"', html)
        self.assertIn('data-style-prompt-style="三维动画"', html)
        self.assertIn('id="styleImagePrompt"', html)
        self.assertIn('id="styleVideoPrompt"', html)
        self.assertIn('id="styleNegativePrompt"', html)
        self.assertIn('id="resetStylePrompts"', html)
        self.assertIn('id="pipelineAssetPromptEditor"', html)
        self.assertIn('id="selectedImagePromptReview"', html)
        self.assertIn('id="selectedVideoPromptReview"', html)
        self.assertIn('data-save-prompt-review', html)
        self.assertIn('基础风格提示词', html)
        self.assertNotIn('id="projectCreateVisualStyle"', html)
        self.assertIn("/* Layout v7: unified responsive console */", styles)
        self.assertIn("#reviewList { min-height: 0; overflow: auto; }", styles)
        self.assertIn("scroll-snap-type: x mandatory;", styles)
        self.assertIn("grid-template-columns: 216px minmax(0, 1fr);", styles)
        self.assertIn("grid-template-columns: none;", styles)
        self.assertIn(".layout-v7 .scene-detail { display: block;", styles)

    def test_media_quick_preview_exposes_sources_without_cropping_video(self):
        app = (ROOT / "console" / "static" / "app.js").read_text(encoding="utf-8")
        styles = (ROOT / "console" / "static" / "styles.css").read_text(encoding="utf-8")

        self.assertIn("查看原图", app)
        self.assertIn("打开原视频", app)
        self.assertIn(".pipeline-shot-media video {", styles)
        self.assertIn(".shot-card video {", styles)
        self.assertIn("object-fit: contain;", styles)
        self.assertNotIn(".pipeline-shot-media img, .pipeline-shot-media video { width: 100%; height: 100%; display: block; object-fit: cover; }", styles)
        self.assertNotIn(".shot-card img, .shot-card video { width: 100%; aspect-ratio: 16 / 9; display: block; object-fit: cover;", styles)

    def test_project_slug_is_normalized_and_rejects_unsafe_values(self):
        self.assertEqual("demo_project", SERVER.validate_project_slug(" Demo_Project "))
        for value in ("", "a", "../escape", "bad slug", "-bad", "a" * 65):
            with self.subTest(value=value), self.assertRaises(ValueError):
                SERVER.validate_project_slug(value)

    def test_shot_id_accepts_safe_ids_and_rejects_paths(self):
        self.assertEqual("SSJ_EP02_SC01_SH01", SERVER.validate_shot_id("SSJ_EP02_SC01_SH01"))
        for value in ("", "../escape", "shot/id", "a" * 97):
            with self.subTest(value=value), self.assertRaises(ValueError):
                SERVER.validate_shot_id(value)

    def test_novel_path_must_be_a_supported_file_in_the_workspace(self):
        with tempfile.TemporaryDirectory(dir=SERVER.ROOT.parent) as workspace_temp:
            novel = Path(workspace_temp) / "story.txt"
            novel.write_text("Chapter 1\nOpening", encoding="utf-8")
            self.assertEqual(novel.resolve(), SERVER.validate_novel_path(str(novel)))

        with tempfile.TemporaryDirectory() as outside_temp:
            outside = Path(outside_temp) / "story.txt"
            outside.write_text("outside", encoding="utf-8")
            with self.assertRaises(ValueError):
                SERVER.validate_novel_path(str(outside))

        with tempfile.TemporaryDirectory(dir=SERVER.ROOT.parent) as workspace_temp:
            unsupported = Path(workspace_temp) / "story.py"
            unsupported.write_text("print('no')", encoding="utf-8")
            with self.assertRaises(ValueError):
                SERVER.validate_novel_path(str(unsupported))

    def test_pipeline_manifest_normalization_removes_temporary_paths(self):
        manifest = {
            "project_slug": "demo-project",
            "pipeline_path": "/tmp/demo/pipeline.json",
            "stages": {"concept": {"path": "/tmp/demo/concept.json", "status": "passed"}},
        }
        normalized = SERVER._normalize_pipeline_manifest(manifest)
        self.assertNotIn("pipeline_path", normalized)
        self.assertNotIn("path", normalized["stages"]["concept"])

    def test_pipeline_workspace_is_materialized_only_in_a_temporary_directory(self):
        manifest = {"project_slug": "demo-project", "project_title": "Demo", "stages": {"concept": {"status": "passed"}}}
        artifacts = {"concept": {"status": "passed", "items": [{"title": "Concept"}]}}
        with patch.object(SERVER, "load_pipeline_storage", return_value=(manifest, artifacts, [])):
            temp_root, pipeline_path = SERVER.materialize_pipeline_workspace("demo-project")
        try:
            materialized = json.loads(pipeline_path.read_text(encoding="utf-8"))
            stage_path = Path(materialized["stages"]["concept"]["path"])
            self.assertTrue(stage_path.is_file())
            self.assertIn(temp_root, stage_path.parents)
            self.assertEqual(artifacts["concept"], json.loads(stage_path.read_text(encoding="utf-8")))
        finally:
            shutil.rmtree(temp_root, ignore_errors=True)

    def test_pipeline_import_rejects_non_exchange_json(self):
        with self.assertRaisesRegex(ValueError, "交换文件"):
            SERVER.import_pipeline_bundle({"manifest": {}, "artifacts": {}})

    def test_asset_catalog_normalizes_legacy_project_and_episode_assets(self):
        catalog = SERVER.normalize_asset_catalog(
            {
                "items": [
                    {"asset_id": "character-1", "name": "Lead"},
                    {"asset_id": "prop-1", "name": "Episode prop", "episode_id": "ep-2"},
                ]
            }
        )
        self.assertEqual(("shared", ""), (catalog["items"][0]["scope"], catalog["items"][0]["episode_id"]))
        self.assertEqual(("episode", "EP02"), (catalog["items"][1]["scope"], catalog["items"][1]["episode_id"]))
        self.assertEqual(1, catalog["asset_scope_version"])


class LocalPipelineHttpTests(unittest.TestCase):
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

    def post_json(self, path, payload):
        request = Request(
            self.base_url + path,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        return urlopen(request, timeout=10)

    def put_json(self, path, payload):
        request = Request(
            self.base_url + path,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="PUT",
        )
        return urlopen(request, timeout=10)

    def test_image_settings_are_saved_without_returning_the_api_key(self):
        original_path = SERVER.IMAGE_SETTINGS_PATH
        secret = "test-secret-never-return"
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.IMAGE_SETTINGS_PATH = Path(root) / "image_api.local.json"
                with self.put_json(
                    "/api/image-settings",
                    {
                        "base_url": "https://api.openai.com/v1",
                        "model": "gpt-image-2",
                        "size": "1536x1024",
                        "quality": "high",
                        "api_key": secret,
                    },
                ) as response:
                    saved = json.loads(response.read().decode("utf-8"))
                self.assertTrue(saved["api_key_configured"])
                self.assertEqual("GPT Image API", saved["provider"])
                self.assertEqual("gpt-image-2", saved["model"])
                self.assertNotIn(secret, json.dumps(saved))

                with self.put_json("/api/image-settings", {"quality": "medium", "api_key": ""}) as response:
                    updated = json.loads(response.read().decode("utf-8"))
                self.assertEqual("medium", updated["quality"])
                stored = json.loads(SERVER.IMAGE_SETTINGS_PATH.read_text(encoding="utf-8"))["image_api"]
                self.assertEqual(secret, stored["api_key"])

                status, loaded = self.get_json("/api/image-settings")
                self.assertEqual(200, status)
                self.assertTrue(loaded["api_key_configured"])
                self.assertNotIn("api_key", loaded)
        finally:
            SERVER.IMAGE_SETTINGS_PATH = original_path

    def test_style_prompts_have_defaults_and_support_save_and_reset(self):
        original_path = SERVER.STYLE_PROMPTS_PATH
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.STYLE_PROMPTS_PATH = Path(root) / "style_prompts.local.json"
                status, defaults = self.get_json("/api/style-prompts")
                self.assertEqual(200, status)
                self.assertEqual({"真人影视", "二维动漫", "三维动画"}, set(defaults["presets"]))
                self.assertEqual("default", defaults["source"])

                presets = json.loads(json.dumps(defaults["presets"], ensure_ascii=False))
                presets["二维动漫"]["image_prompt"] = "custom cel animation preset"
                with self.put_json("/api/style-prompts", {"presets": presets}) as response:
                    saved = json.loads(response.read().decode("utf-8"))
                self.assertEqual("custom cel animation preset", saved["presets"]["二维动漫"]["image_prompt"])
                self.assertEqual("custom", saved["source"])

                with self.post_json("/api/style-prompts/reset", {}) as response:
                    reset = json.loads(response.read().decode("utf-8"))
                self.assertEqual("default", reset["source"])
                self.assertNotEqual("custom cel animation preset", reset["presets"]["二维动漫"]["image_prompt"])
                self.assertFalse(SERVER.STYLE_PROMPTS_PATH.exists())
        finally:
            SERVER.STYLE_PROMPTS_PATH = original_path

    def test_style_prompts_reject_invalid_structure_and_oversized_values(self):
        original_path = SERVER.STYLE_PROMPTS_PATH
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.STYLE_PROMPTS_PATH = Path(root) / "style_prompts.local.json"
                status, defaults = self.get_json("/api/style-prompts")
                self.assertEqual(200, status)
                invalid_payloads = [
                    {"presets": {"真人影视": defaults["presets"]["真人影视"]}},
                    {"presets": {**defaults["presets"], "水墨": defaults["presets"]["真人影视"]}},
                    {"presets": {**defaults["presets"], "真人影视": {**defaults["presets"]["真人影视"], "image_prompt": "x" * 4001}}},
                    {"presets": {**defaults["presets"], "真人影视": {"image_prompt": "only one field"}}},
                ]
                for payload in invalid_payloads:
                    with self.subTest(payload=list(payload["presets"])), self.assertRaises(HTTPError) as error:
                        self.put_json("/api/style-prompts", payload)
                    self.assertEqual(400, error.exception.code)
        finally:
            SERVER.STYLE_PROMPTS_PATH = original_path

    def test_text_settings_are_saved_without_returning_the_api_key(self):
        original_path = SERVER.TEXT_SETTINGS_PATH
        secret = "text-secret-never-return"
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.TEXT_SETTINGS_PATH = Path(root) / "text_api.local.json"
                with self.put_json(
                    "/api/text-settings",
                    {
                        "base_url": "https://api.openai.com/v1",
                        "model": "gpt-5.2",
                        "timeout": 180,
                        "api_key": secret,
                    },
                ) as response:
                    saved = json.loads(response.read().decode("utf-8"))
                self.assertTrue(saved["configured"])
                self.assertEqual("gpt-5.2", saved["model"])
                self.assertNotIn(secret, json.dumps(saved))

                with self.put_json("/api/text-settings", {"model": "gpt-5.2-mini", "api_key": ""}) as response:
                    updated = json.loads(response.read().decode("utf-8"))
                self.assertEqual("gpt-5.2-mini", updated["model"])
                stored = json.loads(SERVER.TEXT_SETTINGS_PATH.read_text(encoding="utf-8"))["text_api"]
                self.assertEqual(secret, stored["api_key"])

                status, loaded = self.get_json("/api/text-settings")
                self.assertEqual(200, status)
                self.assertTrue(loaded["api_key_configured"])
                self.assertNotIn("api_key", loaded)
        finally:
            SERVER.TEXT_SETTINGS_PATH = original_path

    def test_text_settings_reject_credentials_in_base_url(self):
        original_path = SERVER.TEXT_SETTINGS_PATH
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.TEXT_SETTINGS_PATH = Path(root) / "text_api.local.json"
                with self.assertRaises(HTTPError) as error:
                    self.put_json("/api/text-settings", {"base_url": "https://user:secret@example.com", "model": "gpt-5.2"})
                self.assertEqual(400, error.exception.code)
        finally:
            SERVER.TEXT_SETTINGS_PATH = original_path

    def test_image_settings_reject_credentials_in_base_url(self):
        original_path = SERVER.IMAGE_SETTINGS_PATH
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.IMAGE_SETTINGS_PATH = Path(root) / "image_api.local.json"
                with self.assertRaises(HTTPError) as error:
                    self.put_json("/api/image-settings", {"base_url": "https://user:secret@example.com"})
                self.assertEqual(400, error.exception.code)
        finally:
            SERVER.IMAGE_SETTINGS_PATH = original_path

    def test_video_settings_switch_modes_without_returning_the_api_key(self):
        original_path = SERVER.VIDEO_SETTINGS_PATH
        secret = "video-secret-never-return"
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.VIDEO_SETTINGS_PATH = Path(root) / "video_api.local.json"
                with self.put_json(
                    "/api/video-settings",
                    {
                        "mode": "api",
                        "base_url": "https://api.minimax.io",
                        "model": "MiniMax-Hailuo-02",
                        "duration": 10,
                        "resolution": "768P",
                        "api_key": secret,
                    },
                ) as response:
                    saved = json.loads(response.read().decode("utf-8"))
                self.assertEqual("api", saved["mode"])
                self.assertTrue(saved["api_key_configured"])
                self.assertNotIn(secret, json.dumps(saved))

                with self.put_json("/api/video-settings", {"mode": "local", "api_key": ""}) as response:
                    local = json.loads(response.read().decode("utf-8"))
                self.assertEqual("local", local["mode"])
                stored = json.loads(SERVER.VIDEO_SETTINGS_PATH.read_text(encoding="utf-8"))["video_api"]
                self.assertEqual(secret, stored["api_key"])

                status, loaded = self.get_json("/api/video-settings")
                self.assertEqual(200, status)
                self.assertNotIn("api_key", loaded)
        finally:
            SERVER.VIDEO_SETTINGS_PATH = original_path

    def test_video_settings_reject_credentials_in_base_url(self):
        original_path = SERVER.VIDEO_SETTINGS_PATH
        try:
            with tempfile.TemporaryDirectory() as root:
                SERVER.VIDEO_SETTINGS_PATH = Path(root) / "video_api.local.json"
                with self.assertRaises(HTTPError) as error:
                    self.put_json("/api/video-settings", {"base_url": "https://user:secret@example.com"})
                self.assertEqual(400, error.exception.code)
        finally:
            SERVER.VIDEO_SETTINGS_PATH = original_path

    def test_empty_local_pipeline_endpoint(self):
        with patch.object(SERVER, "local_pipeline_projects", return_value=[]):
            status, payload = self.get_json("/api/local-pipeline")
        self.assertEqual(200, status)
        self.assertFalse(payload["exists"])
        self.assertIsNone(payload["manifest"])
        self.assertEqual([], payload["projects"])

    def test_project_api_lists_and_creates_projects(self):
        created_project = {"slug": "api-project", "title": "API Project", "status": "draft"}
        active_project = {**created_project, "status": "active"}
        with patch.object(SERVER, "create_project_record", return_value=created_project), patch.object(SERVER, "update_project_record", return_value=active_project), patch.object(SERVER, "list_project_records", return_value=[active_project]):
            with self.post_json("/api/projects", {"slug": "api-project", "title": "API Project"}) as response:
                created = json.loads(response.read().decode("utf-8"))
                self.assertEqual(201, response.status)
            self.assertEqual("api-project", created["slug"])
            with self.put_json("/api/projects/api-project", {"status": "active"}) as response:
                updated = json.loads(response.read().decode("utf-8"))
            self.assertEqual("active", updated["status"])
            status, payload = self.get_json("/api/projects")
            self.assertEqual(200, status)
            self.assertEqual(["api-project"], [item["slug"] for item in payload["items"]])

    def test_project_planning_configuration_is_validated(self):
        single = SERVER.validate_project_configuration(
            {
                "source_type": "screenplay",
                "content_type": "single",
                "planning_mode": "fixed",
                "target_episode_count": 9,
                "target_unit_duration_seconds": 600,
                "aspect_ratio": "16:9",
                "visual_style": "真人影视",
            }
        )
        self.assertEqual(1, single["target_episode_count"])
        self.assertEqual("screenplay", single["source_type"])
        with self.assertRaisesRegex(ValueError, "集数"):
            SERVER.validate_project_configuration(
                {"content_type": "series", "planning_mode": "fixed", "target_episode_count": 0}
            )
        with self.assertRaisesRegex(ValueError, "画幅"):
            SERVER.validate_project_configuration({"aspect_ratio": "21:9"})

    def test_project_style_is_a_post_creation_gate(self):
        pending = SERVER.validate_project_configuration({"style_status": "pending", "visual_style": ""})
        self.assertEqual("pending", pending["style_status"])
        self.assertEqual("", pending["visual_style"])
        with self.assertRaisesRegex(ValueError, "视觉风格"):
            SERVER.validate_project_configuration({"style_status": "confirmed", "visual_style": ""})
        for style in ("真人影视", "二维动漫", "三维动画"):
            with self.subTest(style=style):
                confirmed = SERVER.validate_project_configuration({"style_status": "confirmed", "visual_style": style})
                self.assertEqual(style, confirmed["visual_style"])
        with self.assertRaisesRegex(ValueError, "主体风格"):
            SERVER.validate_project_configuration({"style_status": "confirmed", "visual_style": "东方奇幻电影写实"})
        legacy = SERVER.validate_project_configuration(
            {"status": "active"},
            {"visual_style": "东方奇幻电影写实", "style_status": "confirmed"},
        )
        self.assertEqual("东方奇幻电影写实", legacy["visual_style"])

    def test_asset_scope_endpoint_updates_one_asset(self):
        expected = {"ok": True, "asset": {"asset_id": "asset-1", "scope": "episode", "episode_id": "EP01"}}
        with patch.object(SERVER, "save_asset_scope", return_value=expected) as save:
            with self.put_json("/api/local-pipeline/asset-scope", {"project_slug": "demo-project", "asset_id": "asset-1", "scope": "episode", "episode_id": "EP01"}) as response:
                payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(expected, payload)
        save.assert_called_once()

    def test_prompt_review_endpoint_updates_one_prompt(self):
        expected = {"ok": True, "prompt": {"shot_id": "shot-1", "review_status": "approved", "final_prompt": "approved prompt"}}
        request = {
            "project_slug": "demo-project",
            "target_type": "shot_image",
            "target_id": "shot-1",
            "final_prompt": "approved prompt",
            "negative_prompt": "bad anatomy",
            "review_status": "approved",
        }
        with patch.object(SERVER, "save_prompt_review", return_value=expected) as save:
            with self.put_json("/api/local-pipeline/prompt-review", request) as response:
                payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(expected, payload)
        save.assert_called_once_with(request)

    def test_save_prompt_review_validates_and_persists_revision(self):
        artifact = {"items": [{"shot_id": "shot-1", "draft_prompt": "draft", "final_prompt": "draft", "review_status": "pending_review", "prompt_revision": 0}]}
        connection = Mock()
        context = Mock()
        context.__enter__ = Mock(return_value=connection)
        context.__exit__ = Mock(return_value=False)
        with patch.object(SERVER, "load_pipeline_storage", return_value=({}, {"image_prompts": artifact}, [])), patch.object(SERVER, "ensure_project_db"), patch.object(SERVER, "_project_db_connection", return_value=context), patch.object(SERVER, "_upsert_pipeline_artifact") as upsert:
            result = SERVER.save_prompt_review({"project_slug": "demo-project", "target_type": "shot_image", "target_id": "shot-1", "final_prompt": " approved prompt ", "negative_prompt": " bad anatomy ", "review_status": "approved"})
        self.assertEqual("approved", result["prompt"]["review_status"])
        self.assertEqual("approved prompt", result["prompt"]["prompt"])
        self.assertEqual(1, result["prompt"]["prompt_revision"])
        upsert.assert_called_once()
        with self.assertRaisesRegex(ValueError, "审核状态"):
            SERVER.save_prompt_review({"project_slug": "demo-project", "target_type": "shot_image", "target_id": "shot-1", "final_prompt": "x", "review_status": "invalid"})

    def test_invalid_project_slug_query_is_rejected(self):
        with self.assertRaises(HTTPError) as error:
            urlopen(self.base_url + "/api/local-pipeline?project_slug=../bad", timeout=10)
        self.assertEqual(400, error.exception.code)

    def test_local_pipeline_job_rejects_invalid_action(self):
        original_script = SERVER.LOCAL_PIPELINE_SCRIPT
        try:
            SERVER.LOCAL_PIPELINE_SCRIPT = Path(sys.executable)
            with self.assertRaises(HTTPError) as error:
                self.post_json(
                    "/api/local-pipeline/jobs",
                    {"action": "delete_everything", "project_slug": "demo_project"},
                )
            self.assertEqual(400, error.exception.code)
        finally:
            SERVER.LOCAL_PIPELINE_SCRIPT = original_script

    def test_local_pipeline_job_rejects_invalid_slug_and_novel_path(self):
        original_script = SERVER.LOCAL_PIPELINE_SCRIPT
        try:
            SERVER.LOCAL_PIPELINE_SCRIPT = Path(sys.executable)
            cases = (
                {"action": "init", "project_slug": "../escape", "novel_path": "story.txt"},
                {"action": "init", "project_slug": "demo_project", "novel_path": "missing.txt"},
            )
            for payload in cases:
                with self.subTest(payload=payload), self.assertRaises(HTTPError) as error:
                    self.post_json("/api/local-pipeline/jobs", payload)
                self.assertEqual(400, error.exception.code)
        finally:
            SERVER.LOCAL_PIPELINE_SCRIPT = original_script

    def test_local_pipeline_init_uses_text_settings_file(self):
        with tempfile.TemporaryDirectory(dir=SERVER.ROOT.parent) as workspace_temp:
            novel = Path(workspace_temp) / "story.txt"
            novel.write_text("Chapter 1\nOpening", encoding="utf-8")
            with patch.object(SERVER, "get_project_record", return_value={"slug": "demo-project"}), patch.object(SERVER, "video_settings_payload", return_value={"mode": "local"}):
                action, _, command, metadata = SERVER.local_pipeline_command(
                    {
                        "action": "init",
                        "project_slug": "demo-project",
                        "project_title": "Demo Project",
                        "novel_path": str(novel),
                        "max_shots": 2,
                        "source_type": "screenplay",
                        "content_type": "series",
                        "planning_mode": "fixed",
                        "target_episode_count": 3,
                        "target_unit_duration_seconds": 120,
                        "aspect_ratio": "9:16",
                        "visual_style": "二维动漫",
                    }
                )
                shutil.rmtree(metadata["_pipeline_temp_root"], ignore_errors=True)
        self.assertEqual("init", action)
        index = command.index("--text-config")
        self.assertEqual(str(SERVER.TEXT_SETTINGS_PATH), command[index + 1])
        self.assertIn("--plan-only", command)
        for option, value in (
            ("--source-type", "screenplay"),
            ("--content-type", "series"),
            ("--planning-mode", "fixed"),
            ("--target-episode-count", "3"),
            ("--target-unit-duration-seconds", "120"),
            ("--aspect-ratio", "9:16"),
            ("--visual-style", "二维动漫"),
        ):
            self.assertEqual(value, command[command.index(option) + 1])

    def test_manifest_listing_adds_media_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            project_dir = Path(root)
            image = project_dir / "shot.png"
            video = project_dir / "shot.mp4"
            image_workflow = project_dir / "shot_image.json"
            video_workflow = project_dir / "shot_video.json"
            image.write_bytes(b"image")
            video.write_bytes(b"video")
            image_workflow.write_text("{}", encoding="utf-8")
            video_workflow.write_text("{}", encoding="utf-8")
            shot_id = "demo_ep01_sc01_sh01"
            stage_files = {
                "shot_table": {"items": [{"shot_id": shot_id, "episode": 1, "action": "Opening"}]},
                "episode_outline": {"items": [{"episode_id": "ep01", "title": "Opening"}]},
                "asset_catalog": {"items": [{"asset_id": "character-1", "kind": "character", "name": "Lead"}, {"asset_id": "prop-1", "kind": "prop", "name": "Episode prop", "episode_id": "EP01"}]},
                "image_prompts": {"items": [{"shot_id": shot_id, "prompt": "image", "final_prompt": "image", "review_status": "approved"}]},
                "video_prompts": {"items": [{"shot_id": shot_id, "prompt": "video", "final_prompt": "video", "review_status": "pending_review"}]},
                "image_generation": {"items": [{"shot_id": shot_id, "status": "passed", "image_path": str(image), "workflow_path": str(image_workflow)}]},
                "clip_generation": {"items": [{"shot_id": shot_id, "status": "passed", "video_path": str(video), "workflow_path": str(video_workflow)}]},
            }
            manifest = {
                "project_slug": "demo-project",
                "project_title": "Demo Project",
                "updated": "2026-09-01T00:00:00Z",
                "stages": {stage: {"status": "passed"} for stage in stage_files},
            }
            records = [{"stage": stage, "status": "passed", "source": "test", "model": "", "item_count": len(value["items"]), "updated_at": "2026-09-01T00:00:00+00:00"} for stage, value in stage_files.items()]
            projects = [{"slug": "demo-project", "title": "Demo Project", "updated": "2026-09-01T00:00:00+00:00", "storage": "postgresql"}]
            with patch.object(SERVER, "local_pipeline_projects", return_value=projects), patch.object(SERVER, "load_pipeline_storage", return_value=(manifest, stage_files, records)), patch.object(SERVER, "get_project_record", return_value=None):
                status, payload = self.get_json("/api/local-pipeline?project_slug=demo-project")

            self.assertEqual(200, status)
            self.assertTrue(payload["exists"])
            self.assertEqual("Demo Project", payload["projects"][0]["title"])
            self.assertEqual({"slug": "demo-project", "title": "Demo Project"}, payload["manifest"]["project"])
            self.assertEqual("", payload["manifest"]["source"]["novel_path"])
            self.assertEqual(1, len(payload["manifest"]["episodes"]))
            self.assertEqual(7, sum(stage["storage"] == "postgresql" for stage in payload["manifest"]["stages"]))
            self.assertEqual(["shared", "episode"], [asset["scope"] for asset in payload["manifest"]["assets"]])
            shot = payload["manifest"]["shots"][0]
            self.assertEqual("approved", shot["image_prompt_record"]["review_status"])
            self.assertEqual("pending_review", shot["video_prompt_record"]["review_status"])
            for key, expected_size in (
                ("image_media", 5),
                ("video_media", 5),
                ("image_workflow_file", 2),
                ("video_workflow_file", 2),
            ):
                with self.subTest(key=key):
                    self.assertTrue(shot[key]["exists"])
                    self.assertEqual(expected_size, shot[key]["size"])
                    self.assertTrue(shot[key]["url"].startswith("/media?path="))


if __name__ == "__main__":
    unittest.main()
