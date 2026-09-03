import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from local_movie_pipeline import (  # noqa: E402
    STAGES,
    _normalize_items,
    _update_shot_status,
    build_image_api_request,
    build_minimax_h3_workflow,
    build_pipeline,
    build_workflows,
    confirm_pipeline_plan,
    generate_edge_tts,
    mix_video_audio,
    read_novel_text,
    run_shot,
    stable_image_prompt,
    stable_video_prompt,
    submit_workflow_and_wait,
    valid_h3_length,
)
from style_presets import DEFAULT_STYLE_PROMPTS  # noqa: E402
from text_model_client import TextModelClient, TextModelConfig  # noqa: E402


class LocalMoviePipelineTests(unittest.TestCase):
    def test_style_presets_are_applied_without_story_specific_assumptions(self):
        prompts = {}
        for style in ("真人影视", "二维动漫", "三维动画"):
            preset = DEFAULT_STYLE_PROMPTS[style]
            shot = {"action": "A traveler enters the station", "visual_style": style, "style_preset_snapshot": preset}
            image_prompt = stable_image_prompt(shot)
            video_prompt = stable_video_prompt(shot)
            prompts[style] = (image_prompt, video_prompt)
            self.assertIn(preset["image_prompt"], image_prompt)
            self.assertIn(preset["video_prompt"], video_prompt)
            self.assertNotIn("ancient Chinese mythology", image_prompt)
        self.assertEqual(3, len({value[0] for value in prompts.values()}))
        self.assertEqual(3, len({value[1] for value in prompts.values()}))

    def test_pipeline_captures_custom_style_preset_for_later_stages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "story.txt"
            source.write_text("A traveler enters a station.", encoding="utf-8")
            presets = json.loads(json.dumps(DEFAULT_STYLE_PROMPTS, ensure_ascii=False))
            presets["三维动画"]["image_prompt"] = "Custom miniature 3D style"
            index = build_pipeline(
                source,
                manifests_root=root / "manifests",
                visual_style="三维动画",
                style_presets=presets,
                max_shots=1,
                plan_only=True,
            )
            self.assertEqual("Custom miniature 3D style", index["style_prompt_snapshot"]["image_prompt"])
            confirmed = confirm_pipeline_plan(index["pipeline_path"])
            prompts = json.loads(Path(confirmed["stages"]["image_prompts"]["path"]).read_text(encoding="utf-8"))
            self.assertIn("Custom miniature 3D style", prompts["items"][0]["prompt"])
            self.assertEqual("Custom miniature 3D style", prompts["items"][0]["style_preset_snapshot"]["image_prompt"])

    def test_ai_prompts_keep_primary_production_medium(self):
        for stage in ("image_prompts", "video_prompts"):
            with self.subTest(stage=stage):
                normalized = _normalize_items(
                    stage,
                    [{"shot_id": "shot-01", "prompt": "A character crosses the courtyard."}],
                    [{"shot_id": "shot-01", "prompt": "fallback", "visual_style": "三维动画"}],
                )
                self.assertIn("Primary production medium: 三维动画.", normalized[0]["base_prompt"])
                self.assertEqual("A character crosses the courtyard.", normalized[0]["draft_prompt"])
                self.assertEqual("pending_review", normalized[0]["review_status"])

    def test_plan_only_creates_fixed_series_production_units(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "series.txt"
            source.write_text(
                "Chapter 1\nOpening.\nChapter 2\nConflict.\nChapter 3\nChoice.",
                encoding="utf-8",
            )
            index = build_pipeline(
                source,
                manifests_root=root / "manifests",
                source_type="screenplay",
                content_type="series",
                planning_mode="fixed",
                target_episode_count=3,
                target_unit_duration_seconds=120,
                aspect_ratio="9:16",
                visual_style="二维动漫",
                max_shots=1,
                plan_only=True,
            )

            self.assertEqual(["concept", "story_bible", "content_plan"], list(index["stages"]))
            self.assertEqual("pending_confirmation", index["planning_status"])
            self.assertNotIn("shots", index)
            story_bible = json.loads(Path(index["stages"]["story_bible"]["path"]).read_text(encoding="utf-8"))
            self.assertTrue({"world_rule", "style_rule", "character"}.issubset({item["item_type"] for item in story_bible["items"]}))
            self.assertEqual("二维动漫", next(item for item in story_bible["items"] if item["item_type"] == "style_rule")["description"])
            plan = json.loads(Path(index["stages"]["content_plan"]["path"]).read_text(encoding="utf-8"))
            self.assertEqual(3, len(plan["items"]))
            self.assertEqual(["unit-01", "unit-02", "unit-03"], [item["unit_id"] for item in plan["items"]])
            self.assertEqual(["EP01", "EP02", "EP03"], [item["episode_id"] for item in plan["items"]])
            self.assertEqual("9:16", plan["aspect_ratio"])
            self.assertEqual("二维动漫", plan["visual_style"])

            confirmed = confirm_pipeline_plan(index["pipeline_path"])
            self.assertEqual("confirmed", confirmed["planning_status"])
            self.assertEqual(tuple(confirmed["stages"]), STAGES)
            self.assertEqual(3, len(confirmed["shots"]))
            self.assertEqual({1, 2, 3}, {shot["episode"] for shot in confirmed["shots"]})
            assets = json.loads(Path(confirmed["stages"]["asset_catalog"]["path"]).read_text(encoding="utf-8"))
            self.assertTrue(any(item["kind"] == "character" for item in assets["items"]))
            image_prompts = json.loads(Path(confirmed["stages"]["image_prompts"]["path"]).read_text(encoding="utf-8"))
            video_prompts = json.loads(Path(confirmed["stages"]["video_prompts"]["path"]).read_text(encoding="utf-8"))
            self.assertIn("二维动漫", image_prompts["items"][0]["prompt"])
            self.assertIn("二维动漫", video_prompts["items"][0]["prompt"])
            self.assertEqual(DEFAULT_STYLE_PROMPTS["二维动漫"], confirmed["style_prompt_snapshot"])
            self.assertEqual(DEFAULT_STYLE_PROMPTS["二维动漫"], image_prompts["items"][0]["style_preset_snapshot"])
            self.assertEqual(DEFAULT_STYLE_PROMPTS["二维动漫"]["negative_prompt"], image_prompts["items"][0]["negative_prompt"])
            for item in (assets["items"][0], image_prompts["items"][0], video_prompts["items"][0]):
                self.assertTrue(item["base_prompt"])
                self.assertTrue(item["draft_prompt"])
                self.assertEqual(item["draft_prompt"], item["final_prompt"])
                self.assertEqual("pending_review", item["review_status"])
                self.assertIn("style_preset_snapshot", item)
            self.assertIn("asset_ids", image_prompts["items"][0]["context_snapshot"])
            self.assertIn("story_bible_item_ids", video_prompts["items"][0]["context_snapshot"])

    def test_single_video_plan_always_has_one_production_unit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "movie.txt"
            source.write_text("A complete short film.", encoding="utf-8")
            index = build_pipeline(
                source,
                manifests_root=root / "manifests",
                content_type="single",
                planning_mode="fixed",
                target_episode_count=8,
                target_unit_duration_seconds=600,
                plan_only=True,
            )
            plan = json.loads(Path(index["stages"]["content_plan"]["path"]).read_text(encoding="utf-8"))
            self.assertEqual(1, index["target_episode_count"])
            self.assertEqual(1, len(plan["items"]))

    def test_ai_story_bible_extracts_project_level_settings(self):
        class StoryBibleClient:
            configured = True

            def request_json(self, prompt, schema):
                if "story_bible" in prompt:
                    return {
                        "items": [
                            {"item_type": "world_rule", "name": "灵潮规则", "description": "灵潮每十年回归。", "importance": "core"},
                            {"item_type": "character", "name": "阿岚", "description": "守潮人。", "visual_prompt": "青衣、银色短发", "importance": "core"},
                            {"item_type": "location", "name": "潮生城", "description": "临海古城。", "importance": "high"},
                        ]
                    }, {"model": "text-model"}
                if "content_plan" in prompt:
                    return {"items": [{"title": "潮起", "summary": "阿岚守城。", "source_chapter_ids": ["ch01"]}]}, {"model": "text-model"}
                return {"items": [{"concept_id": "concept-001", "title": "潮起"}]}, {"model": "text-model"}

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "story.txt"
            source.write_text("Chapter 1\n阿岚在潮生城等待灵潮。", encoding="utf-8")
            index = build_pipeline(source, manifests_root=root / "manifests", client=StoryBibleClient(), plan_only=True)
            story_bible = json.loads(Path(index["stages"]["story_bible"]["path"]).read_text(encoding="utf-8"))
            self.assertEqual("ai", story_bible["source"])
            self.assertEqual(["灵潮规则", "阿岚", "潮生城"], [item["name"] for item in story_bible["items"]])
            self.assertTrue(all(item["review_status"] == "pending_review" for item in story_bible["items"]))

    def test_asset_catalog_normalizes_shared_and_episode_scopes(self):
        items = [
            {"asset_id": "character-1", "kind": "character", "name": "Lead"},
            {"asset_id": "prop-1", "kind": "prop", "name": "Episode prop", "episode": 2},
            {"asset_id": "location-1", "kind": "location", "name": "Set", "scope": "episode"},
        ]
        normalized = _normalize_items("asset_catalog", items, [])
        self.assertEqual(("shared", ""), (normalized[0]["scope"], normalized[0]["episode_id"]))
        self.assertEqual(("episode", "EP02"), (normalized[1]["scope"], normalized[1]["episode_id"]))
        self.assertEqual(("episode", "EP01"), (normalized[2]["scope"], normalized[2]["episode_id"]))

    def test_prompt_stage_ai_context_includes_style_bible_assets_and_shots(self):
        class RecordingClient:
            configured = True

            def __init__(self):
                self.prompts = []

            def request_json(self, prompt, schema):
                self.prompts.append(prompt)
                raise ValueError("use fallback after recording")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "story.txt"
            source.write_text("A traveler carries a brass compass through the station.", encoding="utf-8")
            client = RecordingClient()
            build_pipeline(source, manifests_root=root / "manifests", client=client, max_shots=1)

        image_context = next(prompt for prompt in client.prompts if "Create the image_prompts stage" in prompt)
        video_context = next(prompt for prompt in client.prompts if "Create the video_prompts stage" in prompt)
        for prompt in (image_context, video_context):
            self.assertIn('"style_prompt_snapshot"', prompt)
            self.assertIn('"story_bible"', prompt)
            self.assertIn('"asset_catalog"', prompt)
            self.assertIn('"shot_table"', prompt)

    def test_audio_helpers_build_safe_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "voice.mp3"
            with patch("local_movie_pipeline.subprocess.run") as run:
                run.return_value = Mock()
                result = generate_edge_tts("你好", output, voice="zh-CN-YunxiNeural")
                self.assertEqual("passed", result["status"])
                self.assertIn("--write-media", run.call_args.args[0])
                result = mix_video_audio(Path(directory) / "video.mp4", output, Path(directory) / "mixed.mp4")
                self.assertEqual("passed", result["status"])
                self.assertIn("-shortest", run.call_args.args[0])

    def test_reads_utf8_and_gb18030_novels(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            utf8 = root / "utf8.txt"
            legacy = root / "legacy.txt"
            utf8.write_text("第一章 开端", encoding="utf-8-sig")
            legacy.write_bytes("第二章 继续".encode("gb18030"))
            self.assertEqual(read_novel_text(utf8), "第一章 开端")
            self.assertEqual(read_novel_text(legacy), "第二章 继续")

    def test_fallback_creates_all_stages_and_workflows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "Novel.txt"
            novel.write_text("Chapter 1\nA traveler enters the valley.\nChapter 2\nA difficult choice follows.", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", client=TextModelClient(TextModelConfig()))
            self.assertEqual(tuple(index["stages"]), STAGES)
            self.assertIsNone(index["max_shots"])
            for stage in STAGES:
                manifest = json.loads(Path(index["stages"][stage]["path"]).read_text(encoding="utf-8"))
                self.assertEqual(manifest["source"], "fallback")
                self.assertEqual(manifest["status"], "draft")
            paths = build_workflows(index, workflows_root=root / "workflows")
            self.assertTrue(paths)
            self.assertTrue(all(Path(path).exists() for path in paths))

    def test_ai_metadata_and_malformed_response_fallback(self):
        client = Mock()
        client.configured = True
        client.request_json.return_value = ({"items": [{"custom": "value"}]}, {"model": "test-model"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "novel.txt"
            novel.write_text("A short story", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", client=client)
            concept = json.loads(Path(index["stages"]["concept"]["path"]).read_text(encoding="utf-8"))
            self.assertEqual(concept["source"], "ai")
            self.assertEqual(concept["model"], "test-model")
        client.request_json.side_effect = ValueError("bad json")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "novel.txt"
            novel.write_text("A short story", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", client=client)
            concept = json.loads(Path(index["stages"]["concept"]["path"]).read_text(encoding="utf-8"))
            self.assertEqual(concept["source"], "fallback")
            self.assertTrue(concept["reason"].startswith("ai_error:"))

    def test_shot_limit_is_applied_before_ai_validation(self):
        client = Mock()
        client.configured = True
        client.request_json.return_value = ({"items": [{}]}, {"model": "test-model"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "novel.txt"
            novel.write_text("Chapter 1\nOpening\nChapter 2\nContinuation", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", max_shots=1, client=client)
            for stage in ("shot_table", "image_prompts", "video_prompts", "model_match"):
                manifest = json.loads(Path(index["stages"][stage]["path"]).read_text(encoding="utf-8"))
                self.assertEqual(manifest["source"], "ai")
                self.assertEqual(1, len(manifest["items"]))
            for stage in ("image_generation", "clip_generation"):
                manifest = json.loads(Path(index["stages"][stage]["path"]).read_text(encoding="utf-8"))
                self.assertEqual("managed_by_local_comfyui", manifest["reason"])

    def test_workflow_contracts(self):
        image = build_image_api_request({"shot_id": "shot-1", "prompt": "A valley"})
        self.assertEqual("gpt-image-api", image["provider"])
        self.assertIn("exactly one clearly visible adult protagonist", image["prompt"])
        video = build_minimax_h3_workflow({"shot_id": "shot-1"})
        self.assertEqual(video["prompt"]["1"]["class_type"], "LoadImageOutput")
        self.assertEqual(video["prompt"]["7"]["inputs"]["first_frame"], ["1", 0])
        self.assertNotIn("last_frame", video["prompt"]["7"]["inputs"])
        classes = {node["class_type"] for node in video["prompt"].values()}
        self.assertTrue({"UNETLoader", "LoraLoaderModelOnly", "MiniMaxH3ImageToVideo", "RandomNoise", "BasicGuider", "KSamplerSelect", "BasicScheduler", "SamplerCustomAdvanced", "VAEDecodeAudio", "CreateVideo", "Video Slice"}.issubset(classes))
        minimax_node = next(node for node in video["prompt"].values() if node["class_type"] == "MiniMaxH3ImageToVideo")
        values = minimax_node["inputs"]
        self.assertEqual((values["width"], values["height"]), (736, 416))
        self.assertEqual(next(node for node in video["prompt"].values() if node["class_type"] == "CreateVideo")["inputs"]["fps"], 24.0)
        self.assertEqual((video["metadata"]["quantization"], video["metadata"]["lora"], values["length"]), ("W4A8", "PDD LoRA", 243))
        self.assertEqual(next(node for node in video["prompt"].values() if node["class_type"] == "BasicScheduler")["inputs"]["steps"], 8)
        slice_inputs = next(node for node in video["prompt"].values() if node["class_type"] == "Video Slice")["inputs"]
        self.assertEqual(slice_inputs, {"video": ["15", 0], "start_time": 0.0, "duration": 10.0, "strict_duration": True})
        self.assertEqual(video["prompt"]["17"]["inputs"]["video"], ["16", 0])
        self.assertTrue(valid_h3_length(values["length"]))

    def test_stability_prompts_and_default_duration(self):
        image_prompt = stable_image_prompt({"action": "A swordsman watches the sea"})
        video_prompt = stable_video_prompt({"action": "He turns toward the sea"})
        self.assertIn("exactly one clearly visible adult protagonist", image_prompt)
        self.assertIn("No other people", image_prompt)
        self.assertIn("normal real-time speed", video_prompt)
        self.assertIn("No slow motion", video_prompt)
        self.assertIn("No face change", video_prompt)

        legacy = stable_video_prompt({"prompt": "One continuous 10-second cinematic shot. Old constraints. Shot direction: He raises one hand."})
        self.assertIn("Shot direction: He raises one hand.", legacy)
        self.assertNotIn("Old constraints", legacy)
        with tempfile.TemporaryDirectory() as directory:
            novel = Path(directory) / "story.txt"
            novel.write_text("A beginning", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=Path(directory) / "manifests", max_shots=1)
            self.assertEqual(index["shots"][0]["duration_seconds"], 10)

    def test_run_image_uses_api_and_writes_manifest(self):
        class FakeImageClient:
            configured = True

            def __init__(self):
                self.prompt = ""

            def generate(self, prompt, output_path):
                self.prompt = prompt
                return {
                    "status": "passed",
                    "provider": "api.example",
                    "model": "gpt-image-2",
                    "outputs": [{"filename": Path(output_path).name, "path": str(output_path), "annotated_path": None}],
                }

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "story.txt"
            novel.write_text("A lone traveler enters the valley", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", max_shots=1)
            shot_id = index["shots"][0]["shot_id"]
            client = FakeImageClient()
            blocked = run_shot("image_generation", shot_id, index["pipeline_path"], base_url="http://unused", timeout=1, poll_interval=0, image_client=client)
            self.assertEqual("prompt_not_approved", blocked["reason"])
            self.assertEqual("", client.prompt)

            prompt_path = Path(index["stages"]["image_prompts"]["path"])
            prompt_stage = json.loads(prompt_path.read_text(encoding="utf-8"))
            prompt_stage["items"][0].update({"review_status": "approved", "final_prompt": "APPROVED IMAGE PROMPT", "prompt": "APPROVED IMAGE PROMPT"})
            prompt_path.write_text(json.dumps(prompt_stage), encoding="utf-8")
            result = run_shot("image_generation", shot_id, index["pipeline_path"], base_url="http://unused", timeout=1, poll_interval=0, image_client=client)
            self.assertEqual("passed", result["status"])
            self.assertEqual("APPROVED IMAGE PROMPT", client.prompt)
            stage = json.loads(Path(index["stages"]["image_generation"]["path"]).read_text(encoding="utf-8"))
            self.assertTrue(stage["items"][0]["image_path"].endswith("_gpt_image.png"))
            self.assertTrue(stage["items"][0]["image_input"].endswith(" [output]"))

    def test_run_video_uses_api_mode_and_writes_same_clip_manifest(self):
        class FakeVideoClient:
            configured = True
            config = SimpleNamespace(mode="api", provider="minimax", model="MiniMax-Hailuo-02")

            def __init__(self):
                self.prompt = ""
                self.frame = None

            def generate(self, prompt, first_frame, output_path):
                self.prompt = prompt
                self.frame = Path(first_frame)
                return {
                    "status": "passed",
                    "provider": "api.example",
                    "model": "MiniMax-Hailuo-02",
                    "outputs": [{"filename": Path(output_path).name, "path": str(output_path)}],
                }

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "story.txt"
            novel.write_text("A lone traveler enters the valley", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", max_shots=1)
            shot_id = index["shots"][0]["shot_id"]
            frame = root / "frame.png"
            frame.write_bytes(b"png")
            image_stage_path = Path(index["stages"]["image_generation"]["path"])
            image_stage = json.loads(image_stage_path.read_text(encoding="utf-8"))
            image_stage["items"][0]["image_path"] = str(frame)
            image_stage_path.write_text(json.dumps(image_stage), encoding="utf-8")

            client = FakeVideoClient()
            blocked = run_shot(
                "clip_generation",
                shot_id,
                index["pipeline_path"],
                base_url="http://unused",
                timeout=1,
                poll_interval=0,
                video_client=client,
            )
            self.assertEqual("prompt_not_approved", blocked["reason"])
            self.assertEqual("", client.prompt)

            prompt_path = Path(index["stages"]["video_prompts"]["path"])
            prompt_stage = json.loads(prompt_path.read_text(encoding="utf-8"))
            prompt_stage["items"][0].update({"review_status": "approved", "final_prompt": "APPROVED VIDEO PROMPT", "prompt": "APPROVED VIDEO PROMPT"})
            prompt_path.write_text(json.dumps(prompt_stage), encoding="utf-8")
            result = run_shot(
                "clip_generation",
                shot_id,
                index["pipeline_path"],
                base_url="http://unused",
                timeout=1,
                poll_interval=0,
                video_client=client,
            )

            self.assertEqual("passed", result["status"])
            self.assertEqual(frame, client.frame)
            self.assertEqual("APPROVED VIDEO PROMPT", client.prompt)
            clip_stage = json.loads(Path(index["stages"]["clip_generation"]["path"]).read_text(encoding="utf-8"))
            self.assertTrue(clip_stage["items"][0]["video_path"].endswith("_minimax_api.mp4"))

    def test_legacy_prompt_without_review_fields_remains_compatible(self):
        class FakeImageClient:
            configured = True

            def __init__(self):
                self.prompt = ""

            def generate(self, prompt, output_path):
                self.prompt = prompt
                return {"status": "passed", "outputs": []}

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "story.txt"
            novel.write_text("A lone traveler enters the valley", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", max_shots=1)
            shot_id = index["shots"][0]["shot_id"]
            path = Path(index["stages"]["image_prompts"]["path"])
            stage = json.loads(path.read_text(encoding="utf-8"))
            stage["items"][0] = {"shot_id": shot_id, "prompt": "legacy valley prompt"}
            path.write_text(json.dumps(stage), encoding="utf-8")
            client = FakeImageClient()

            result = run_shot("image_generation", shot_id, index["pipeline_path"], base_url="http://unused", timeout=1, poll_interval=0, image_client=client)

            self.assertEqual("passed", result["status"])
            self.assertIn("legacy valley prompt", client.prompt)
            self.assertIn("exactly one clearly visible adult protagonist", client.prompt)

    def test_comfy_history_outputs_are_returned_and_written_back(self):
        responses = [
            {"queue_running": [], "queue_pending": []},
            {"prompt_id": "prompt-1"},
            {
                "prompt-1": {
                    "status": {"status_str": "success", "completed": True},
                    "outputs": {"7": {"images": [{"filename": "shot.png", "subfolder": "local_projects", "type": "output"}]}},
                }
            },
        ]
        opener = Mock()
        opener.side_effect = [self._json_response(payload) for payload in responses]
        result = submit_workflow_and_wait({"prompt": {}}, opener=opener, poll_interval=0)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["outputs"][0]["annotated_path"], "local_projects/shot.png [output]")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "story.txt"
            novel.write_text("A beginning", encoding="utf-8")
            index = build_pipeline(novel, manifests_root=root / "manifests", max_shots=1)
            _update_shot_status(index, "image_generation", index["shots"][0]["shot_id"], result)
            stage = json.loads(Path(index["stages"]["image_generation"]["path"]).read_text(encoding="utf-8"))
            self.assertEqual(stage["items"][0]["image_input"], "local_projects/shot.png [output]")
            self.assertTrue(stage["items"][0]["image_path"].endswith("local_projects\\shot.png"))

    @staticmethod
    def _json_response(payload):
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        return response

    def test_busy_queue_does_not_submit(self):
        opener = Mock()
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps({"queue_running": [{"prompt_id": "other"}]}).encode()
        opener.return_value = response
        result = submit_workflow_and_wait({"prompt": {}}, opener=opener)
        self.assertEqual(result["status"], "waiting")
        self.assertEqual(opener.call_count, 1)

    def test_cli_init_show_and_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            novel = root / "story.txt"
            novel.write_text("A beginning", encoding="utf-8")
            script = ROOT / "scripts" / "local_movie_pipeline.py"
            env = os.environ.copy()
            init = subprocess.run([sys.executable, str(script), "init", str(novel), "--manifests-root", str(root / "manifests"), "--workflows-root", str(root / "workflows"), "--no-ai"], capture_output=True, text=True, check=True)
            info = json.loads(init.stdout)
            self.assertTrue(Path(info["pipeline"]).exists())
            shown = subprocess.run([sys.executable, str(script), "show", "--pipeline", info["pipeline"]], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(shown.stdout)["project_slug"], "story")
            built = subprocess.run([sys.executable, str(script), "build-workflows", "--pipeline", info["pipeline"], "--workflows-root", str(root / "workflows2")], capture_output=True, text=True, check=True)
            self.assertGreater(json.loads(built.stdout)["workflow_count"], 0)


if __name__ == "__main__":
    unittest.main()
