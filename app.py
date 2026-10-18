"""Hosted HTTP MCP server for AeroWash Vision.
Receives JPEG frames from the user's local Mac bridge and exposes read-only tools.
It does not control a drone or open a camera.
"""
import os
import time
from pathlib import Path

import cv2
import numpy as np
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from starlette.routing import Route
from starlette.requests import Request
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.types import Image

DATA_DIR = Path(os.environ.get("AEROWASH_DATA_DIR", "/tmp/aerowash-frames"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
PROCESSED = DATA_DIR / "latest.jpg"
RAW = DATA_DIR / "latest_raw.jpg"
TOKEN = os.environ.get("AEROWASH_TOKEN", "")

mcp = FastMCP("AeroWash Vision Connector")

def image_age(path):
    if not path.exists():
        return None
    return round(max(0.0, time.time() - path.stat().st_mtime), 2)

def load_image(path):
    if not path.exists():
        raise ValueError("No frame uploaded yet. Start the local AeroWash bridge.")
    age = image_age(path)
    if age is not None and age > 30:
        raise ValueError(f"Last frame is {age} seconds old; check the local bridge.")
    data = path.read_bytes()
    if not data:
        raise ValueError("Frame file is empty.")
    return Image(data=data, format="jpeg")

@mcp.tool()
def aerowash_status() -> dict:
    """Check whether recent AeroWash Vision frames are reaching the hosted server."""
    age = image_age(PROCESSED)
    return {"project":"AeroWash Vision", "recent_frame": age is not None and age <= 30,
            "seconds_since_last_frame":age, "processed_frame_exists":PROCESSED.exists(),
            "raw_frame_exists":RAW.exists(),
            "note":"Read-only vision connector; does not control the camera or drone."}

@mcp.tool()
def get_latest_frame() -> Image:
    """Return the latest processed camera image with overlays."""
    return load_image(PROCESSED)

@mcp.tool()
def get_latest_raw_frame() -> Image:
    """Return the latest raw camera image without overlays."""
    return load_image(RAW)

@mcp.tool()
def analyze_latest_frame() -> dict:
    """Measure brightness, contrast and edge ratio; does not identify dirt."""
    if not PROCESSED.exists():
        raise ValueError("No frame uploaded yet.")
    frame = cv2.imread(str(PROCESSED))
    if frame is None:
        raise ValueError("Could not decode latest frame.")
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(cv2.GaussianBlur(gray, (5, 5), 1.2), 40, 80)
    h, w = gray.shape
    return {"width":int(w), "height":int(h),
            "mean_brightness_0_255":round(float(np.mean(gray)),2),
            "contrast_stddev":round(float(np.std(gray)),2),
            "edge_pixel_percent":round(float(np.count_nonzero(edges))*100/edges.size,2),
            "seconds_since_last_frame":image_age(PROCESSED),
            "warning":"These metrics do not detect dirt; that requires a trained and validated model."}

async def healthz(request):
    return JSONResponse({"ok": True, "service": "aerowash-mcp"})

async def upload(request):
    kind = request.path_params["kind"]
    if kind not in ("frame", "raw"):
        return JSONResponse({"error":"kind must be frame or raw"}, status_code=400)
    body = await request.body()
    if not body or len(body) > 8_000_000 or not body.startswith(b"\xff\xd8"):
        return JSONResponse({"error":"Expected a JPEG under 8 MB"}, status_code=400)
    path = PROCESSED if kind == "frame" else RAW
    path.write_bytes(body)
    return JSONResponse({"ok":True, "kind":kind, "bytes":len(body)})

class TokenMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if request.url.path == "/healthz":
            return await call_next(request)
        if not TOKEN:
            return JSONResponse({"error":"AEROWASH_TOKEN is not configured"}, status_code=503)
        supplied = request.headers.get("authorization", "")
        if supplied != "Bearer " + TOKEN:
            return JSONResponse({"error":"Unauthorized"}, status_code=401)
        return await call_next(request)

mcp_app = mcp.streamable_http_app()
mcp_app.add_middleware(TokenMiddleware)
mcp_app.routes.extend([
    Route("/healthz", healthz, methods=["GET"]),
    Route("/upload/{kind:str}", upload, methods=["POST"]),
])
app = mcp_app
