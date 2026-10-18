#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PaperShelf"
BUNDLE_ID="local.papershelf.library"
SIGN_IDENTITY="${PAPERSHELF_SIGN_IDENTITY:--}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
BUILD_DIR="$ROOT_DIR/.build/parity-app"
if [[ "$MODE" == "--qa" ]]; then
    APP_NAME="PaperShelfQA"
    BUNDLE_ID="local.papershelf.qa"
    APP_BUNDLE="$ROOT_DIR/.build/lattice-qa/$APP_NAME.app"
fi
cd "$ROOT_DIR"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry|--build-only|--qa) ;;
  *) echo "usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
if pgrep -x "$APP_NAME" >/dev/null; then
    case "$MODE" in
        run) /usr/bin/open "$APP_BUNDLE"; exit 0 ;;
        --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "PaperShelf"' ;;
        --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.papershelf.library"' ;;
    esac
    printf '%s\n' 'PaperShelf is running. Quit it normally before rebuilding so active jobs can shut down and save their history.' >&2
    exit 1
fi
swift build --scratch-path "$BUILD_DIR"
BUILD_BIN_DIR="$(swift build --scratch-path "$BUILD_DIR" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/PaperShelf"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
if [[ ! -f "$ROOT_DIR/Assets/Branding/PaperShelf.icns" || "$ROOT_DIR/Assets/Branding/PaperShelf.png" -nt "$ROOT_DIR/Assets/Branding/PaperShelf.icns" ]]; then
    bash "$ROOT_DIR/script/build_icon.sh"
fi
cp "$ROOT_DIR/Assets/Branding/PaperShelf.icns" "$APP_BUNDLE/Contents/Resources/PaperShelf.icns"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/.$APP_NAME-new"
mv -f "$APP_BUNDLE/Contents/MacOS/.$APP_NAME-new" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BUILD_BIN_DIR/PaperShelfCLI" "$APP_BUNDLE/Contents/MacOS/.PaperShelfCLI-new"
mv -f "$APP_BUNDLE/Contents/MacOS/.PaperShelfCLI-new" "$APP_BUNDLE/Contents/MacOS/PaperShelfCLI"
if [[ -d "$ROOT_DIR/Localization" ]]; then
    /usr/bin/rsync -a "$ROOT_DIR/Localization/" "$APP_BUNDLE/Contents/Resources/"
fi
for RESOURCE in BrowserExtension IntegrationsUI IntegrationsAPI; do
    if [[ -d "$ROOT_DIR/$RESOURCE" ]]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/$RESOURCE"
        /usr/bin/rsync -a --delete --delete-excluded --exclude '.build' --exclude 'node_modules' --exclude '.git' --exclude '.certs' --exclude '.DS_Store' "$ROOT_DIR/$RESOURCE/" "$APP_BUNDLE/Contents/Resources/$RESOURCE/"
    fi
done
if [[ -f "$ROOT_DIR/LICENSE" ]]; then cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"; fi
if [[ -f "$ROOT_DIR/Guide.md" ]]; then cp "$ROOT_DIR/Guide.md" "$APP_BUNDLE/Contents/Resources/Guide.md"; fi
if [[ ! -f "$ROOT_DIR/IntegrationsUI/Word/dist/server.mjs" ]]; then
    echo 'Word runtime bundle missing. Run npm ci --ignore-scripts and npm run build in IntegrationsUI/Word.' >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Resources/evidence/lattice-parity" "$APP_BUNDLE/Contents/Resources/integrations"
for DOCUMENT in feature-parity.md feature-matrix-input.md core-data-contract.md native-final-qa.md signing-and-hosts.md; do
    if [[ -f "$ROOT_DIR/evidence/lattice-parity/$DOCUMENT" ]]; then cp "$ROOT_DIR/evidence/lattice-parity/$DOCUMENT" "$APP_BUNDLE/Contents/Resources/evidence/lattice-parity/"; fi
done
cp "$ROOT_DIR/integrations/README.md" "$APP_BUNDLE/Contents/Resources/integrations/README.md"

# SwiftPM extracts AppIntents metadata beside the executable. Keep it in the app bundle.
if [[ -d "$BUILD_BIN_DIR/Metadata.appintents" ]]; then
    /usr/bin/rsync -a --delete "$BUILD_BIN_DIR/Metadata.appintents/" "$APP_BUNDLE/Contents/Resources/Metadata.appintents/"
fi
PIPELINE_RESOURCES="$APP_BUNDLE/Contents/Resources/Pipeline"
mkdir -p "$PIPELINE_RESOURCES/backend" "$PIPELINE_RESOURCES/integrations" "$PIPELINE_RESOURCES/script"
/usr/bin/rsync -a --delete --delete-excluded --exclude '__pycache__' --exclude '*.egg-info' --exclude '.pytest_cache' --exclude 'tests' "$ROOT_DIR/backend/" "$PIPELINE_RESOURCES/backend/"
for UPSTREAM in Paper2Agent markitdown graphiti; do
    mkdir -p "$PIPELINE_RESOURCES/integrations/$UPSTREAM"
    /usr/bin/rsync -a --delete --delete-excluded --exclude '.git' --exclude '.github' --exclude '__pycache__' --exclude '.venv' --exclude 'node_modules' "$ROOT_DIR/integrations/$UPSTREAM/" "$PIPELINE_RESOURCES/integrations/$UPSTREAM/"
done
cp "$ROOT_DIR/script/setup_integrations.sh" "$PIPELINE_RESOURCES/script/"
cp "$ROOT_DIR/script/graph_service.sh" "$PIPELINE_RESOURCES/script/"
cp "$ROOT_DIR/integrations/compose.yaml" "$PIPELINE_RESOURCES/integrations/"
cp "$ROOT_DIR/integrations/upstreams.lock.json" "$PIPELINE_RESOURCES/integrations/"
cp "$ROOT_DIR/integrations/config.example.json" "$PIPELINE_RESOURCES/integrations/"
cp "$ROOT_DIR/integrations/adapter-requirements.txt" "$PIPELINE_RESOURCES/integrations/"
/usr/bin/rsync -a "$ROOT_DIR/integrations/licenses/" "$PIPELINE_RESOURCES/integrations/licenses/"
if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    "$ROOT_DIR/.venv/bin/python" -c 'import json,sys; from pathlib import Path; Path(sys.argv[1]).write_text(json.dumps({"python":sys.argv[2]}))' "$PIPELINE_RESOURCES/runtime.json" "$ROOT_DIR/.venv/bin/python"
else
    rm -f "$PIPELINE_RESOURCES/runtime.json"
fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PaperShelf</string>
<key>CFBundleIdentifier</key><string>local.papershelf.library</string>
<key>CFBundleName</key><string>PaperShelf</string>
<key>CFBundleDisplayName</key><string>PaperShelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>PaperShelf</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>PaperShelf</string><key>CFBundleURLSchemes</key><array><string>papershelf</string></array></dict></array>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Literature</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>com.adobe.pdf</string><string>public.text</string></array></dict></array>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
if [[ "$MODE" == "--qa" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName PaperShelf QA' "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 papershelf-qa' "$APP_BUNDLE/Contents/Info.plist"
fi
"$ROOT_DIR/script/extract_app_intents.sh" "$BUILD_DIR" "$APP_BUNDLE"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--options runtime --timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/MacOS/PaperShelfCLI"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
case "$MODE" in
  --qa|--build-only) echo "Built $APP_BUNDLE" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null; echo "PaperShelf launch verified" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "PaperShelf"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.papershelf.library"' ;;
esac
