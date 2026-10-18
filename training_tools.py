"""Training snapshot and edge-mask tools for the hosted AeroWash MCP server."""
import json
import re
import shutil
import time
import uuid
from pathlib import Path

import cv2
import numpy as np
from mcp.server.fastmcp.utilities.types import Image


def register_training_tools(mcp, data_dir: Path, raw_path: Path):
    root = data_dir / "ai_edges"
    pending = root / "pending"
    images = root / "images"
    masks = root / "masks"
    annotations = root / "annotations"
    for folder in (pending, images, masks, annotations):
        folder.mkdir(parents=True, exist_ok=True)

    @mcp.tool()
    def create_training_capture() -> dict:
        """Freeze the latest fresh raw camera frame as a training example awaiting a human/AI edge correction."""
        if not raw_path.exists():
            raise ValueError("No raw frame available; start the local camera bridge first.")
        age = time.time() - raw_path.stat().st_mtime
        if age > 30:
            raise ValueError(f"Raw frame is stale ({age:.1f}s). Start the camera bridge and retry.")
        frame = cv2.imread(str(raw_path))
        if frame is None:
            raise ValueError("Could not decode latest raw frame.")
        capture_id = time.strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:8]
        path = pending / f"{capture_id}.jpg"
        if not cv2.imwrite(str(path), frame, [int(cv2.IMWRITE_JPEG_QUALITY), 95]):
            raise ValueError("Could not save capture.")
        h, w = frame.shape[:2]
        return {"capture_id": capture_id, "width": int(w), "height": int(h), "image_tool": "get_training_capture_image", "note": "Inspect the returned image and call save_edge_correction with normalized polylines (x/y from 0 to 1000)."}

    @mcp.tool()
    def get_training_capture_image(capture_id: str) -> Image:
        """Return an immutable captured image for visual edge annotation."""
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", capture_id):
            raise ValueError("Invalid capture_id.")
        path = pending / f"{capture_id}.jpg"
        if not path.exists():
            raise ValueError("Capture not found or already saved.")
        return Image(data=path.read_bytes(), format="jpeg")

    @mcp.tool()
    def save_edge_correction(capture_id: str, polylines_json: str, min_confidence: float = 0.35, thickness: int = 2) -> dict:
        """Save the original and a binary edge mask. polylines_json is a JSON list of {confidence, points:[[x,y],...]} with normalized x/y in 0..1000. Only include visually supported edge lines."""
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", capture_id):
            raise ValueError("Invalid capture_id.")
        if not 0 <= min_confidence <= 1 or not 1 <= thickness <= 20:
            raise ValueError("min_confidence must be 0..1 and thickness 1..20.")
        source = pending / f"{capture_id}.jpg"
        if not source.exists():
            raise ValueError("Pending capture not found.")
        try:
            lines = json.loads(polylines_json)
        except Exception as exc:
            raise ValueError("polylines_json must be valid JSON.") from exc
        if not isinstance(lines, list):
            raise ValueError("Expected a JSON list of polylines.")
        frame = cv2.imread(str(source))
        if frame is None:
            raise ValueError("Could not decode captured image.")
        h, w = frame.shape[:2]
        mask = np.zeros((h, w), dtype=np.uint8)
        saved_lines = []
        for line in lines:
            if not isinstance(line, dict):
                continue
            confidence = float(line.get("confidence", 1.0))
            pts = line.get("points", [])
            if confidence < min_confidence or not isinstance(pts, list) or len(pts) < 2:
                continue
            coords = []
            for p in pts:
                if not isinstance(p, (list, tuple)) or len(p) != 2:
                    continue
                x = max(0, min(w - 1, round(float(p[0]) * (w - 1) / 1000)))
                y = max(0, min(h - 1, round(float(p[1]) * (h - 1) / 1000)))
                coords.append([x, y])
            if len(coords) >= 2:
                cv2.polylines(mask, [np.asarray(coords, dtype=np.int32)], False, 255, thickness=thickness, lineType=cv2.LINE_AA)
                saved_lines.append({"confidence": confidence, "points": pts})
        cv2.imwrite(str(images / f"{capture_id}.jpg"), frame, [int(cv2.IMWRITE_JPEG_QUALITY), 95])
        cv2.imwrite(str(masks / f"{capture_id}.png"), mask)
        (annotations / f"{capture_id}.json").write_text(json.dumps({"capture_id": capture_id, "width": w, "height": h, "min_confidence": min_confidence, "thickness": thickness, "polylines": saved_lines}, indent=2), encoding="utf-8")
        source.unlink(missing_ok=True)
        return {"ok": True, "capture_id": capture_id, "image_path": str(images / f"{capture_id}.jpg"), "mask_path": str(masks / f"{capture_id}.png"), "annotation_path": str(annotations / f"{capture_id}.json"), "edge_pixels": int(np.count_nonzero(mask)), "lines_saved": len(saved_lines), "note": "Mask is a binary edge target; it is not a magenta overlay preview."}

    return {"pending": pending, "images": images, "masks": masks, "annotations": annotations}
