"""Upload AeroWash Vision frames from the Mac to the hosted MCP server.

Run locally on the Mac, not on Render:
  export AEROWASH_URL="https://nightclaw.onrender.com"
  export AEROWASH_TOKEN="the token configured in Render"
  python3 local_bridge.py

Uploads the latest processed and raw JPEG every three minutes by default.
This sends images to the hosted server, not proactively into a ChatGPT conversation.
"""
import os
import sys
import time
from pathlib import Path

import requests

BASE_URL = os.environ.get("AEROWASH_URL", "https://nightclaw.onrender.com").rstrip("/")
TOKEN = os.environ.get("AEROWASH_TOKEN", "")
INTERVAL = max(10.0, float(os.environ.get("AEROWASH_UPLOAD_INTERVAL", "180")))
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
    print(f"Upload interval: {INTERVAL:g} seconds ({INTERVAL / 60:g} minutes)")
    print("Uploads latest processed + raw frames to Render. It does not push images into ChatGPT automatically.")
    print("Press Ctrl+C to stop.")
    while True:
        for kind, path in FILES:
            try:
                if not path.is_file():
                    print(f"Waiting for {path.name}...")
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
