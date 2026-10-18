#!/usr/bin/env python3
"""Build dependency-free, inspectable development extension packages."""
from pathlib import Path
import json
import shutil
import zipfile

root = Path(__file__).resolve().parent
output = root / "dist"
output.mkdir(exist_ok=True)
for browser, manifest in (("chromium", "chromium"), ("firefox", "firefox"), ("safari", "chromium")):
    destination = output / browser
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(root / "shared", destination)
    data = json.loads((root / f"manifest.{manifest}.json").read_text())
    (destination / "manifest.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    archive = output / f"PaperShelf-Capture-{browser}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(destination.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(destination))
    print(archive)
