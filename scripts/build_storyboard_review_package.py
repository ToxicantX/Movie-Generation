import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

from PIL import Image


DEFAULT_REVIEW = Path(r"E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json")
DEFAULT_OUTPUT_DIR = Path(r"G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD")
DEFAULT_MANIFEST = Path(r"E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review_package.json")


def main() -> int:
    review_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REVIEW
    output_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUTPUT_DIR
    manifest_path = Path(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_MANIFEST

    review = read_json(review_path)
    output_dir.mkdir(parents=True, exist_ok=True)

    shots = []
    ok = True
    for shot in review.get("shots", []):
        shot_result = package_shot(shot, output_dir)
        shots.append(shot_result)
        ok = ok and shot_result["ok"]

    markdown_path = output_dir / "human_review.md"
    markdown_path.write_text(build_markdown(review, shots), encoding="utf-8")

    manifest = {
        "ok": ok,
        "updated": datetime.now().isoformat(timespec="seconds"),
        "review_path": str(review_path),
        "output_dir": str(output_dir),
        "markdown_path": str(markdown_path),
        "shots": shots,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0 if ok else 1


def package_shot(shot: dict, output_dir: Path) -> dict:
    shot_id = shot.get("shot_id") or "UNKNOWN_SHOT"
    storyboard_path = Path(str(shot.get("storyboard_path") or ""))
    shot_dir = output_dir / shot_id
    if shot_dir.is_dir():
        for old_file in shot_dir.glob("*"):
            if old_file.is_file():
                old_file.unlink()
    shot_dir.mkdir(parents=True, exist_ok=True)

    result = {
        "shot_id": shot_id,
        "ok": False,
        "storyboard_path": str(storyboard_path),
        "packaged_storyboard": None,
        "technical": {},
        "error": None,
    }
    try:
        if not storyboard_path.is_file():
            raise RuntimeError(f"Storyboard not found: {storyboard_path}")
        packaged = shot_dir / f"{shot_id}_storyboard.png"
        shutil.copy2(storyboard_path, packaged)
        with Image.open(storyboard_path) as img:
            width, height = img.size
        result.update(
            {
                "ok": True,
                "packaged_storyboard": str(packaged),
                "technical": {
                    "width": width,
                    "height": height,
                    "bytes": storyboard_path.stat().st_size,
                },
            }
        )
    except Exception as exc:
        result["error"] = str(exc)
    return result


def build_markdown(review: dict, shots: list[dict]) -> str:
    segment_id = review.get("segment_id") or "SEGMENT"
    lines = [
        f"# {segment_id} Storyboard Review",
        "",
        f"- Updated: {datetime.now().isoformat(timespec='seconds')}",
        f"- Source: {review.get('source', '')}",
        f"- Beat: {review.get('beat_id', '')}",
        f"- Title: {review.get('title', '')}",
        f"- Global decision: {review.get('global_decision', '')}",
        "",
        "## Gate",
        "",
        "Approve storyboards before running I2V. If a shot fails identity, prop, location, safety, or composition checks, regenerate the storyboard first.",
        "",
    ]
    for packaged in shots:
        source = matching_review_shot(review, packaged["shot_id"])
        lines.extend(
            [
                f"## {packaged['shot_id']}",
                "",
                f"- Title: `{source.get('title', '')}`",
                f"- Status: `{source.get('status', '')}`",
                f"- Storyboard: `{packaged['storyboard_path']}`",
                f"- Storyboard workflow: `{source.get('storyboard_workflow', '')}`",
                f"- I2V workflow after approval: `{source.get('video_workflow', '')}`",
                f"- Technical: `{json.dumps(packaged.get('technical', {}), ensure_ascii=False)}`",
                f"- Machine package OK: `{packaged['ok']}`",
                "",
            ]
        )
        if packaged.get("packaged_storyboard"):
            lines.append(f"![storyboard]({Path(packaged['packaged_storyboard']).as_posix()})")
            lines.append("")
        lines.extend(
            [
                "Human decision:",
                "",
                "- [ ] pass_storyboard",
                "- [ ] needs_storyboard_regeneration",
                "- [ ] blocked",
                "",
                "Notes:",
                "",
                "",
            ]
        )
    return "\n".join(lines)


def matching_review_shot(review: dict, shot_id: str) -> dict:
    for shot in review.get("shots", []):
        if shot.get("shot_id") == shot_id:
            return shot
    return {}


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


if __name__ == "__main__":
    raise SystemExit(main())
