#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:---build}"
case "$MODE" in --build|--generate-only) ;; *) echo 'usage: build_safari.sh [--build|--generate-only]' >&2; exit 2;; esac
python3 "$ROOT/package.py"
PROJECT_ROOT="$ROOT/.build/SafariProject"
if [[ -e "$PROJECT_ROOT" ]]; then
    echo "Existing generated project preserved: $PROJECT_ROOT" >&2
    echo 'Remove or rename that generated folder explicitly before regenerating after source changes.' >&2
    exit 1
fi
mkdir -p "$(dirname "$PROJECT_ROOT")"
xcrun safari-web-extension-converter "$ROOT/dist/safari" \
    --project-location "$PROJECT_ROOT" --app-name 'PaperShelf Capture' \
    --bundle-identifier local.papershelf.capture --swift --macos-only \
    --copy-resources --no-open --no-prompt
echo "Generated project: $PROJECT_ROOT/PaperShelf Capture/PaperShelf Capture.xcodeproj"
PROJECT="$PROJECT_ROOT/PaperShelf Capture/PaperShelf Capture.xcodeproj"
if [[ ! -d "$PROJECT" ]]; then PROJECT="$PROJECT_ROOT/PaperShelf Capture.xcodeproj"; fi
# Xcode 27.1's converter can generate a parent identifier that differs from --bundle-identifier.
# Keep the app and embedded extension in the requested prefix without touching user projects.
python3 - "$PROJECT/project.pbxproj" <<'PY'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
source = path.read_text()
source = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = "?local\.papershelf\.PaperShelf-Capture"?;',
                'PRODUCT_BUNDLE_IDENTIFIER = local.papershelf.capture;', source)
source = re.sub(r'MACOSX_DEPLOYMENT_TARGET = [0-9.]+;', 'MACOSX_DEPLOYMENT_TARGET = 27.0;', source)
path.write_text(source)
PY
if [[ "$MODE" == '--generate-only' ]]; then exit 0; fi
xcodebuild -quiet -project "$PROJECT" -scheme 'PaperShelf Capture' -configuration Debug \
    -derivedDataPath "$ROOT/.build/SafariDerivedData" -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    CODE_SIGNING_REQUIRED=NO MACOSX_DEPLOYMENT_TARGET=27.0 build
APP="$ROOT/.build/SafariDerivedData/Build/Products/Debug/PaperShelf Capture.app"
codesign --verify --deep --strict "$APP"
if [[ -d "$ROOT/dist/PaperShelf Capture.app" ]]; then rm -rf "$ROOT/dist/PaperShelf Capture.app"; fi
ditto "$APP" "$ROOT/dist/PaperShelf Capture.app"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/PaperShelf Capture.app" "$ROOT/dist/PaperShelf-Capture-Safari-app.zip"
echo "Local development app: $ROOT/dist/PaperShelf Capture.app"
echo "Safari app archive: $ROOT/dist/PaperShelf-Capture-Safari-app.zip"
echo 'Ad hoc builds are for build verification. Sign with a valid Apple identity before normal Safari activation.'
echo 'A normal distribution build requires an Apple development/distribution identity; this script does not alter Safari settings.'
