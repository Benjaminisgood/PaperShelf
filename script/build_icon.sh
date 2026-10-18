#!/usr/bin/env bash
# Package the original artwork into every standard macOS icon representation.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Assets/Branding/PaperShelf.png"
ICONSET="$ROOT_DIR/.build/branding/PaperShelf.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$ROOT_DIR/Assets/Branding/PaperShelf.icns"
for SIZE in 16 32 48 128; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ROOT_DIR/BrowserExtension/shared/icons/icon-$SIZE.png" >/dev/null
done
/usr/bin/sips -z 256 256 "$SOURCE" --out "$ROOT_DIR/IntegrationsUI/Word/web/icon.png" >/dev/null
/usr/bin/sips -z 512 512 "$SOURCE" --out "$ROOT_DIR/IntegrationsUI/Raycast/assets/icon.png" >/dev/null
printf '%s\n' 'Packaged Assets/Branding/PaperShelf.icns'
