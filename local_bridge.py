"""Upload AeroWash Vision frames from the Mac to the hosted MCP server.

Run locally on the Mac, not on Render:
  export AEROWASH_URL="https://nightclaw.onrender.com"
  export AEROWASH_TOKEN="the token configured in Render"
  python3 local_bridge.py

This uploads camera frames over HTTPS using bearer authentication.
"""
import os
import sys
import time
from pathlib import Path

import requests

BASE_URL = os.environ.get("AEROWASH_URL", "https://nightclaw.onrender.com").rstrip("/")
TOKEN = os.environ.get("AEROWASH_TOKEN", "")
INTERVAL = max(1.0, float(os.environ.get("AEROWASH_UPLOAD_INTERVAL", "2")))
ROOT = Path.home() / "AeroWashVision"
FRAME_DIR = ROOT / "dataset" / "connector"
FILES = (("frame", FRAME_DIR / "latest.jpg"), ("raw", FRAME_DIR / "latest_raw.jpg"))

def main():
    if not TOKEN:
        print("ERROR: set AEROWASH_TOKEN to the same secret configured in Render.")
        sys.exit(2)
    session = requests.Session()
    session.headers.update({"Authorization": f"Bearer {TOKEN}"})
    print(f"AeroWash local bridge -> {BASE_URL}")
    print(f"Reading frames from {FRAME_DIR}")
    print("Press Ctrl+C to stop. Frames are uploaded only to your configured server.")
    last_mtime = {}
    while True:
        for kind, path in FILES:
            try:
                if not path.is_file():
                    continue
                mtime = path.stat().st_mtime
                if last_mtime.get(kind) == mtime:
                    continue
                data = path.read_bytes()
                if not data:
                    continue
                response = session.post(
                    f"{BASE_URL}/upload/{kind}",
                    data=data,
                    headers={"Content-Type": "image/jpeg"},
                    timeout=15,
                )
                if response.ok:
                    last_mtime[kind] = mtime
                    print(f"Uploaded {kind}: {len(data)} bytes")
                else:
                    print(f"Upload {kind} failed: HTTP {response.status_code} {response.text[:200]}")
            except requests.RequestException as exc:
                print(f"Network error uploading {kind}: {exc}")
            except OSError as exc:
                print(f"File error for {path}: {exc}")
        time.sleep(INTERVAL)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAeroWash bridge stopped.")
