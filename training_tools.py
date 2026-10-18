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
    def get_edge_instruction() -> dict:
        """Return the exact vision instruction to apply to the newest raw AeroWash frame."""
        return {
            "prompt": "delinea todos los bordes por minimo q sean de todos los objetos y pintalos de morado intenso",
            "input_image_tool": "get_latest_raw_frame",
            "generated_preview_tool": "get_latest_edge_overlay",
            "note": "This MCP tool provides the prompt and image tools to the connected assistant when called; it cannot proactively send messages into a ChatGPT conversation."
        }

    def _compute_edges():
        """Return raw BGR frame, binary edge mask and magenta overlay."""
        if not raw_path.exists():
            raise ValueError("No raw frame uploaded yet. Start the local AeroWash bridge.")
        age = time.time() - raw_path.stat().st_mtime
        if age > 240:
            raise ValueError(f"Raw frame is stale ({age:.1f}s); check the local bridge.")
        frame = cv2.imread(str(raw_path))
        if frame is None:
            raise ValueError("Could not decode latest raw frame.")
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        # Boost local contrast for dim camera scenes without changing the original.
        clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8))
        enhanced = clahe.apply(gray)
        denoised = cv2.bilateralFilter(enhanced, 5, 35, 35)
        # Low and high thresholds retain finer and stronger edges; combine both scales.
        edges_fine = cv2.Canny(denoised, 18, 48, L2gradient=True)
        edges_coarse = cv2.Canny(denoised, 45, 110, L2gradient=True)
        edges = cv2.bitwise_or(edges_fine, edges_coarse)
        # Remove isolated speckle while keeping thin boundaries.
        count, labels, stats, _ = cv2.connectedComponentsWithStats((edges > 0).astype(np.uint8), 8)
        cleaned = np.zeros_like(edges)
        for idx in range(1, count):
            if stats[idx, cv2.CC_STAT_AREA] >= 2:
                cleaned[labels == idx] = 255
        overlay = frame.copy()
        # Blend bright magenta with the source so lines remain visible but image context survives.
        magenta = np.zeros_like(frame)
        magenta[:] = (255, 0, 255)  # OpenCV BGR
        active = cleaned > 0
        overlay[active] = cv2.addWeighted(frame, 0.15, magenta, 0.85, 0)[active]
        return frame, cleaned, overlay

    @mcp.tool()
    def get_latest_edge_overlay() -> Image:
        """Generate and return the latest RAW frame with fine and coarse detected edges in intense magenta. Enhances low-light contrast first."""
        _, mask, overlay = _compute_edges()
        overlay_path = data_dir / "latest_edges_overlay.jpg"
        if not cv2.imwrite(str(overlay_path), overlay, [int(cv2.IMWRITE_JPEG_QUALITY), 95]):
            raise ValueError("Could not save edge overlay.")
        ok, encoded = cv2.imencode(".jpg", overlay, [int(cv2.IMWRITE_JPEG_QUALITY), 95])
        if not ok:
            raise ValueError("Could not encode edge overlay.")
        return Image(data=encoded.tobytes(), format="jpeg")

    @mcp.tool()
    def process_latest_edges() -> dict:
        """Run edge detection on the latest RAW image, save the magenta overlay and binary mask, and report detected edge coverage."""
        frame, mask, overlay = _compute_edges()
        overlay_path = data_dir / "latest_edges_overlay.jpg"
        mask_path = data_dir / "latest_edges_mask.png"
        if not cv2.imwrite(str(overlay_path), overlay, [int(cv2.IMWRITE_JPEG_QUALITY), 95]):
            raise ValueError("Could not save edge overlay.")
        if not cv2.imwrite(str(mask_path), mask):
            raise ValueError("Could not save edge mask.")
        h, w = mask.shape
        edge_pixels = int(np.count_nonzero(mask))
        return {
            "ok": True,
            "prompt": "delinea todos los bordes por minimo q sean de todos los objetos y pintalos de morado intenso",
            "source": str(raw_path),
            "overlay_path": str(overlay_path),
            "mask_path": str(mask_path),
            "width": int(w),
            "height": int(h),
            "edge_pixels": edge_pixels,
            "edge_pixel_percent": round(edge_pixels * 100 / (w * h), 2),
            "overlay_tool": "get_latest_edge_overlay",
            "note": "The overlay and mask are computed from the actual RAW frame using OpenCV. This is classical edge detection, not semantic AI."
        }

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
