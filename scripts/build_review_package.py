import json
import sys
from datetime import datetime
from pathlib import Path

import cv2


DEFAULT_REVIEW = Path(r"E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json")
DEFAULT_SCHEMA = Path(r"E:\workspace\ComfyUIProjects\Movie-Generation\manifests\consistency_review_schema.json")
DEFAULT_OUTPUT_DIR = Path(r"G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_SC01")
DEFAULT_MANIFEST = Path(r"E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_review_package.json")


def main() -> int:
    review_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REVIEW
    output_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUTPUT_DIR
    manifest_path = Path(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_MANIFEST

    review = read_json(review_path)
    schema = read_json(DEFAULT_SCHEMA) if DEFAULT_SCHEMA.is_file() else {"required_checks": []}
    output_dir.mkdir(parents=True, exist_ok=True)

    shots = []
    ok = True
    for shot in review.get("shots", []):
        shot_result = build_shot_review(shot, output_dir)
        shots.append(shot_result)
        ok = ok and shot_result["ok"]

    markdown_path = output_dir / "human_review.md"
    markdown_path.write_text(build_markdown(review, schema, shots), encoding="utf-8")

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


def build_shot_review(shot: dict, output_dir: Path) -> dict:
    shot_id = shot.get("shot_id") or "UNKNOWN_SHOT"
    video_path = Path(shot.get("video_path") or "")
    storyboard_path = Path(shot.get("storyboard_path") or "")
    shot_dir = output_dir / shot_id
    if shot_dir.is_dir():
        for old_file in shot_dir.glob("*"):
            if old_file.is_file():
                old_file.unlink()
    shot_dir.mkdir(parents=True, exist_ok=True)

    result = {
        "shot_id": shot_id,
        "ok": False,
        "video_path": str(video_path),
        "storyboard_path": str(storyboard_path),
        "frames": {},
        "contact_sheet": None,
        "storyboard_compare": None,
        "technical": {},
        "error": None,
    }

    try:
        cap = cv2.VideoCapture(str(video_path))
        if not cap.isOpened():
            raise RuntimeError(f"Could not open video: {video_path}")
        fps = cap.get(cv2.CAP_PROP_FPS) or 24
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        if width <= 0 or height <= 0 or frame_count <= 0:
            raise RuntimeError("Video has invalid dimensions or frame count.")

        frame_indices = {
            "first": 0,
            "middle": max(0, frame_count // 2),
            "last": max(0, frame_count - 1),
        }
        frames = {}
        for label, index in frame_indices.items():
            frame = read_frame(cap, index)
            frame_path = shot_dir / f"{shot_id}_{label}.jpg"
            cv2.imwrite(str(frame_path), frame, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
            frames[label] = {"path": str(frame_path), "frame": index}
        cap.release()

        contact_path = shot_dir / f"{shot_id}_contact_sheet.jpg"
        write_contact_sheet([Path(frames[label]["path"]) for label in ("first", "middle", "last")], contact_path)

        compare_path = None
        if storyboard_path.is_file():
            compare_path = shot_dir / f"{shot_id}_storyboard_compare.jpg"
            write_storyboard_compare(storyboard_path, Path(frames["middle"]["path"]), compare_path)

        result.update(
            {
                "ok": True,
                "frames": frames,
                "contact_sheet": str(contact_path),
                "storyboard_compare": str(compare_path) if compare_path else None,
                "technical": {
                    "fps": fps,
                    "width": width,
                    "height": height,
                    "frame_count": frame_count,
                    "duration_seconds": round(frame_count / fps, 3) if fps else None,
                    "bytes": video_path.stat().st_size if video_path.is_file() else 0,
                },
            }
        )
    except Exception as exc:
        result["error"] = str(exc)
    return result


def read_frame(cap, index: int):
    cap.set(cv2.CAP_PROP_POS_FRAMES, index)
    ok, frame = cap.read()
    if not ok:
        raise RuntimeError(f"Could not read frame {index}.")
    return frame


def write_contact_sheet(frame_paths: list[Path], output_path: Path) -> None:
    images = [cv2.imread(str(path)) for path in frame_paths]
    images = [image for image in images if image is not None]
    if not images:
        raise RuntimeError("No frames available for contact sheet.")
    target_h = 360
    resized = [resize_to_height(image, target_h) for image in images]
    sheet = cv2.hconcat(resized)
    cv2.imwrite(str(output_path), sheet, [int(cv2.IMWRITE_JPEG_QUALITY), 92])


def write_storyboard_compare(storyboard_path: Path, frame_path: Path, output_path: Path) -> None:
    storyboard = cv2.imread(str(storyboard_path))
    frame = cv2.imread(str(frame_path))
    if storyboard is None or frame is None:
        raise RuntimeError("Could not read storyboard or frame for comparison.")
    target_h = 480
    left = resize_to_height(storyboard, target_h)
    right = resize_to_height(frame, target_h)
    if left.shape[0] != right.shape[0]:
        right = cv2.resize(right, (right.shape[1], left.shape[0]), interpolation=cv2.INTER_AREA)
    compare = cv2.hconcat([left, right])
    cv2.imwrite(str(output_path), compare, [int(cv2.IMWRITE_JPEG_QUALITY), 92])


def resize_to_height(image, height: int):
    scale = height / image.shape[0]
    width = max(1, int(image.shape[1] * scale))
    return cv2.resize(image, (width, height), interpolation=cv2.INTER_AREA)


def build_markdown(review: dict, schema: dict, shots: list[dict]) -> str:
    segment_id = review.get("segment_id") or "SSJ EP01 SC01"
    title = review.get("title") or "Human Review"
    lines = [
        f"# {segment_id} Human Review",
        "",
        f"- Updated: {datetime.now().isoformat(timespec='seconds')}",
        f"- Source: {review.get('source', '')}",
        f"- Beat: {review.get('beat_id', '')}",
        f"- Title: {title}",
        f"- Global decision: {review.get('global_decision', '')}",
        "",
        "## Review Checks",
        "",
    ]
    for check in schema.get("required_checks", []):
        lines.append(f"- {check.get('id')}: {check.get('criteria')}")
    lines.append("")

    for shot in shots:
        lines.extend(
            [
                f"## {shot['shot_id']}",
                "",
                f"- Video: `{shot['video_path']}`",
                f"- Storyboard: `{shot['storyboard_path']}`",
                f"- Title: `{matching_review_shot(review, shot['shot_id']).get('title', '')}`",
                f"- Technical: `{json.dumps(shot.get('technical', {}), ensure_ascii=False)}`",
                f"- Machine package OK: `{shot['ok']}`",
                "",
            ]
        )
        if shot.get("contact_sheet"):
            lines.append(f"![contact sheet]({Path(shot['contact_sheet']).as_posix()})")
            lines.append("")
        if shot.get("storyboard_compare"):
            lines.append(f"![storyboard compare]({Path(shot['storyboard_compare']).as_posix()})")
            lines.append("")
        lines.extend(
            [
                "Human decision:",
                "",
                "- [ ] pass",
                "- [ ] needs_regeneration",
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
