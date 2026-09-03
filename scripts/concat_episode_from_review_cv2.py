import json
import sys
from pathlib import Path

import cv2


DEFAULT_REVIEW = Path(r"E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json")
DEFAULT_OUTPUT = Path(r"G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC01_test_cv2_v001.mp4")
DEFAULT_MANIFEST = Path(r"E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_episode_cut_result.json")


def main() -> int:
    review_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REVIEW
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUTPUT
    manifest_path = Path(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_MANIFEST

    review = json.loads(review_path.read_text(encoding="utf-8-sig"))
    if review.get("global_decision") not in {
        "pending_human_consistency_review",
        "approved_for_episode_cut",
    }:
        write_manifest(
            manifest_path,
            {
                "ok": False,
                "reason": "Review is not ready for episode cut.",
                "global_decision": review.get("global_decision"),
                "review_path": str(review_path),
            },
        )
        return 1

    video_paths = []
    for shot in review.get("shots", []):
        path = shot.get("video_path")
        if not path:
            write_manifest(
                manifest_path,
                {
                    "ok": False,
                    "reason": f"Missing video_path for {shot.get('shot_id')}",
                    "review_path": str(review_path),
                },
            )
            return 1
        video_path = Path(path)
        if not video_path.is_file():
            write_manifest(
                manifest_path,
                {
                    "ok": False,
                    "reason": f"Video file not found: {video_path}",
                    "review_path": str(review_path),
                },
            )
            return 1
        video_paths.append(video_path)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    writer = None
    target_size = None
    target_fps = None
    total_frames = 0
    sources = []

    try:
        for video_path in video_paths:
            cap = cv2.VideoCapture(str(video_path))
            if not cap.isOpened():
                raise RuntimeError(f"Could not open video: {video_path}")
            fps = cap.get(cv2.CAP_PROP_FPS) or 24
            width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
            height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
            frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
            if width <= 0 or height <= 0:
                raise RuntimeError(f"Invalid video dimensions: {video_path}")
            if writer is None:
                target_fps = fps if fps > 1 else 24
                target_size = (width, height)
                fourcc = cv2.VideoWriter_fourcc(*"mp4v")
                writer = cv2.VideoWriter(str(output_path), fourcc, target_fps, target_size)
                if not writer.isOpened():
                    raise RuntimeError(f"Could not open output writer: {output_path}")
            sources.append(
                {
                    "path": str(video_path),
                    "fps": fps,
                    "width": width,
                    "height": height,
                    "frame_count": frame_count,
                }
            )
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                if (frame.shape[1], frame.shape[0]) != target_size:
                    frame = cv2.resize(frame, target_size, interpolation=cv2.INTER_AREA)
                writer.write(frame)
                total_frames += 1
            cap.release()
    except Exception as exc:
        if writer is not None:
            writer.release()
        write_manifest(
            manifest_path,
            {
                "ok": False,
                "reason": str(exc),
                "review_path": str(review_path),
                "output_path": str(output_path),
                "sources": sources,
            },
        )
        return 1
    finally:
        if writer is not None:
            writer.release()

    output_exists = output_path.is_file() and output_path.stat().st_size > 0
    write_manifest(
        manifest_path,
        {
            "ok": output_exists,
            "review_path": str(review_path),
            "output_path": str(output_path),
            "sources": sources,
            "frame_count": total_frames,
            "fps": target_fps,
            "size": list(target_size) if target_size else None,
            "bytes": output_path.stat().st_size if output_path.is_file() else 0,
        },
    )
    return 0 if output_exists else 1


def write_manifest(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    raise SystemExit(main())
