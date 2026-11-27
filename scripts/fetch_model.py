#!/usr/bin/env python3
"""Download Apple's Core ML conversion of Depth Anything V2 Small from Hugging Face.

Usage: fetch_model.py <output_dir>
Writes <output_dir>/DepthAnythingV2SmallF16.mlpackage. Uses only the standard library.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

REPO = "apple/coreml-depth-anything-v2-small"
PACKAGE = "DepthAnythingV2SmallF16.mlpackage"
BASE = "https://huggingface.co"


def get(url, attempts=4):
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "better-background-ci"})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            if i == attempts - 1:
                raise
            print(f"retry {url}: {e}", file=sys.stderr)
            time.sleep(2 ** i)


def list_files(path):
    url = f"{BASE}/api/models/{REPO}/tree/main/{urllib.parse.quote(path)}?recursive=true"
    entries = json.loads(get(url))
    return [e["path"] for e in entries if e.get("type") == "file"]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Models"
    files = list_files(PACKAGE)
    if not files:
        sys.exit(f"No files found under {PACKAGE} in {REPO}")
    for path in files:
        dest = os.path.join(out, path)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        url = f"{BASE}/{REPO}/resolve/main/{urllib.parse.quote(path)}"
        print(f"downloading {path}")
        data = get(url)
        with open(dest, "wb") as f:
            f.write(data)
    manifest = os.path.join(out, PACKAGE, "Manifest.json")
    if not os.path.exists(manifest):
        sys.exit("Manifest.json missing; download looks incomplete")
    print("done")


if __name__ == "__main__":
    main()
