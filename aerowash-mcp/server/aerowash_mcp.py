"""AeroWash Vision MCP server.

Local stdio server that reads frames published by AeroWash Vision.
It does not open or control the webcam or drone.
"""
from pathlib import Path
import time

import cv2
import numpy as np
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.types import Image

ROOT = Path(__file__).resolve().parents[2]
BRIDGE_DIR = ROOT / "dataset" / "connector"
PROCESSED_IMAGE = BRIDGE_DIR / "latest.jpg"
RAW_IMAGE = BRIDGE_DIR / "latest_raw.jpg"

mcp = FastMCP("AeroWash Vision Connector")


def _image_age(path: Path):
    if not path.exists():
        return None
    return round(max(0.0, time.time() - path.stat().st_mtime), 2)


def _load_image(path: Path) -> Image:
    if not path.exists():
        raise ValueError(
            "No capture yet. Start AeroWash Vision and keep the camera active."
        )
    age = _image_age(path)
    if age is not None and age > 15:
        raise ValueError(
            f"The last capture is {age} seconds old. Check AeroWash Vision is running."
        )
    data = path.read_bytes()
    if not data:
        raise ValueError("The capture file is empty; try again.")
    return Image(data=data, format="jpeg")


@mcp.tool()
def aerowash_status() -> dict:
    """Check whether AeroWash Vision is publishing recent frames."""
    age = _image_age(PROCESSED_IMAGE)
    return {
        "project": "AeroWash Vision",
        "bridge_directory": str(BRIDGE_DIR),
        "vision_running_or_recent": age is not None and age <= 15,
        "seconds_since_last_frame": age,
        "processed_frame_exists": PROCESSED_IMAGE.exists(),
        "raw_frame_exists": RAW_IMAGE.exists(),
        "note": "This connector reads frames; it does not control the camera or drone.",
    }


@mcp.tool()
def get_latest_frame() -> Image:
    """Return the latest processed color image with overlays."""
    return _load_image(PROCESSED_IMAGE)


@mcp.tool()
def get_latest_raw_frame() -> Image:
    """Return the latest raw camera image without overlays."""
    return _load_image(RAW_IMAGE)


@mcp.tool()
def analyze_latest_frame() -> dict:
    """Calculate brightness, contrast and edge ratio; does not identify dirt."""
    if not PROCESSED_IMAGE.exists():
        raise ValueError("No capture yet. Start AeroWash Vision first.")
    frame = cv2.imread(str(PROCESSED_IMAGE))
    if frame is None:
        raise ValueError("Could not read the latest capture.")
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(cv2.GaussianBlur(gray, (5, 5), 1.2), 40, 80)
    height, width = gray.shape
    return {
        "width": int(width),
        "height": int(height),
        "mean_brightness_0_255": round(float(np.mean(gray)), 2),
        "contrast_stddev": round(float(np.std(gray)), 2),
        "edge_pixel_percent": round(float(np.count_nonzero(edges)) * 100 / edges.size, 2),
        "seconds_since_last_frame": _image_age(PROCESSED_IMAGE),
        "warning": "These metrics do not detect or identify dirt; that requires a trained and validated model.",
    }


if __name__ == "__main__":
    mcp.run(transport="stdio")
