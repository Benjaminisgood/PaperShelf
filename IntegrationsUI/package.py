#!/usr/bin/env python3
"""Package the built adapters without credentials or development dependencies."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent
output = root / "dist"
output.mkdir(exist_ok=True)
for name in ("Word", "Raycast"):
    source = root / name
    required = "dist/server.mjs" if name == "Word" else "dist/search-papershelf.js"
    if not (source / required).is_file():
        raise SystemExit(f"Build {name} before packaging.")
    destination = output / f"PaperShelf-{name}.zip"
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source.rglob("*")):
            relative = path.relative_to(source)
            if path.is_symlink() or any(part.startswith(".") or part == "node_modules" for part in relative.parts):
                continue
            if path.is_file() and path.suffix not in (".pem", ".key", ".p12", ".pfx"):
                archive.write(path, Path(name) / relative)
    print(destination)
