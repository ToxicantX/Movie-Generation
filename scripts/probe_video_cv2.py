import json
import sys
from pathlib import Path

import cv2


def probe(path_text: str) -> dict:
    path = Path(path_text)
    result = {
        "path": str(path),
        "exists": path.is_file(),
        "ok": False,
        "error": "",
        "fps": 0,
        "width": 0,
        "height": 0,
        "frame_count": 0,
        "bytes": path.stat().st_size if path.is_file() else 0,
    }
    try:
        if not path.is_file():
            result["error"] = "file_not_found"
            return result
        if path.stat().st_size < 64:
            result["error"] = "file_too_small"
            return result

        cap = cv2.VideoCapture(str(path))
        if not cap.isOpened():
            result["error"] = "opencv_open_failed"
            return result

        try:
            fps = cap.get(cv2.CAP_PROP_FPS) or 0
            width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
            height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
            frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
            ok, _frame = cap.read()
        finally:
            cap.release()

        result.update(
            {
                "fps": fps,
                "width": width,
                "height": height,
                "frame_count": frame_count,
            }
        )
        if not ok:
            result["error"] = "first_frame_decode_failed"
        elif width <= 0 or height <= 0:
            result["error"] = "invalid_dimensions"
        elif frame_count <= 0:
            result["error"] = "empty_video"
        else:
            result["ok"] = True
        return result
    except Exception as exc:
        result["error"] = str(exc)
        return result


def main() -> int:
    if len(sys.argv) != 2:
        print(
            json.dumps(
                {"ok": False, "error": "usage: probe_video_cv2.py <video_path>"},
                ensure_ascii=False,
            )
        )
        return 2
    result = probe(sys.argv[1])
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
