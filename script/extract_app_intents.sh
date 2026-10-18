#!/usr/bin/env bash
set -euo pipefail

# Run after copying the newly compiled PaperShelf binary into the bundle and
# before codesign. Usage: script/extract_app_intents.sh BUILD_DIR APP_BUNDLE
if [[ $# -ne 2 ]]; then
    printf '%s\n' 'usage: extract_app_intents.sh BUILD_DIR APP_BUNDLE' >&2
    exit 2
fi
BUILD_DIR="$1"
APP_BUNDLE="$2"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist")"
BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -f "$BINARY" ]]; then
    printf '%s\n' "PaperShelf binary not found: $BINARY" >&2
    exit 1
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}papershelf-appintents.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# Derive architecture and deployment target from the binary being packaged,
# not from the host OS or a hardcoded project setting.
xcrun vtool -show-build "$BINARY" > "$WORK_DIR/build-info.txt"
xcodebuild -version > "$WORK_DIR/xcode-version.txt"
xcrun lipo -archs "$BINARY" > "$WORK_DIR/architectures.txt"
python3 - "$BUILD_DIR" "$WORK_DIR" <<'PY'
import json
import platform
import re
import sys
from pathlib import Path

build = Path(sys.argv[1]).resolve()
work = Path(sys.argv[2])
architectures = (work / 'architectures.txt').read_text().split()
if not architectures:
    raise SystemExit('Cannot identify the compiled PaperShelf architecture.')
architecture = platform.machine() if platform.machine() in architectures else architectures[0]
# Xcode's SwiftPM build system stores compiler supplementary outputs in out/.
# Restrict lookup to that exact build root, avoiding other scratch builds.
search = build / 'out' if (build / 'out').is_dir() else build
lists = [path for path in search.rglob('PaperShelf.SwiftFileList') if architecture in path.parts]
if not lists:
    raise SystemExit('No PaperShelf.SwiftFileList found in the supplied build directory. Run swift build with the Xcode SwiftPM build system first.')
source_list = max(lists, key=lambda path: path.stat().st_mtime_ns)
objects = source_list.parent
intent_values = objects / 'PaperShelfIntents.swiftconstvalues'
if not intent_values.is_file():
    raise SystemExit('PaperShelfIntents.swiftconstvalues is missing. Rebuild the app with Swift constant extraction enabled.')
values = json.loads(intent_values.read_text())
required = {'PaperShelf.ReadPaperShelfNotesIntent', 'PaperShelf.SearchPaperShelfIntent', 'PaperShelf.OpenPaperShelfReferenceIntent', 'PaperShelf.ExportPaperShelfMarkdownIntent'}
if not required.issubset({item.get('typeName') for item in values}):
    raise SystemExit('Compiler metadata does not contain all four PaperShelf intents; rebuild before packaging.')
(work / 'source-list-path.txt').write_text(str(source_list))
(work / 'swift-const-values.txt').write_text('\n'.join(str(path) for path in sorted(objects.glob('*.swiftconstvalues'))) + '\n')
minimum = re.search(r'^\s*minos\s+(\S+)', (work / 'build-info.txt').read_text(), re.M)
xcode = re.search(r'^Build version\s+(\S+)', (work / 'xcode-version.txt').read_text(), re.M)
if not minimum or not xcode:
    raise SystemExit('Cannot read deployment target or Xcode build version.')
(work / 'minimum-version.txt').write_text(minimum.group(1))
(work / 'target-triple.txt').write_text(f'{architecture}-apple-macos{minimum.group(1)}')
(work / 'xcode-build.txt').write_text(xcode.group(1))
PY

SOURCE_LIST="$(cat "$WORK_DIR/source-list-path.txt")"
MINIMUM_VERSION="$(cat "$WORK_DIR/minimum-version.txt")"
TARGET_TRIPLE="$(cat "$WORK_DIR/target-triple.txt")"
XCODE_BUILD="$(cat "$WORK_DIR/xcode-build.txt")"
SWIFT_COMPILER="$(xcrun --find swiftc)"
TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$SWIFT_COMPILER")")")"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"

xcrun appintentsmetadataprocessor \
    --output "$WORK_DIR/export" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name PaperShelf \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD" \
    --platform-family macOS \
    --deployment-target "$MINIMUM_VERSION" \
    --target-triple "$TARGET_TRIPLE" \
    --source-file-list "$SOURCE_LIST" \
    --swift-const-vals-list "$WORK_DIR/swift-const-values.txt"

python3 - "$WORK_DIR/export/Metadata.appintents" "$APP_BUNDLE/Contents/Resources" <<'PY'
import json
import os
import shutil
import sys
import uuid
from pathlib import Path

source, resources = map(Path, sys.argv[1:])
actions = json.loads((source / 'extract.actionsdata').read_text()).get('actions', {})
required = {'ReadPaperShelfNotesIntent', 'SearchPaperShelfIntent', 'OpenPaperShelfReferenceIntent', 'ExportPaperShelfMarkdownIntent'}
if not required.issubset(actions):
    raise SystemExit('App Intents extraction did not produce all expected actions. Existing bundle metadata was preserved.')
resources.mkdir(parents=True, exist_ok=True)
target = resources / 'Metadata.appintents'
staging = resources / ('.Metadata.appintents-new-' + uuid.uuid4().hex)
previous = resources / ('.Metadata.appintents-old-' + uuid.uuid4().hex)
shutil.copytree(source, staging)
moved_previous = False
try:
    if target.exists():
        os.rename(target, previous)
        moved_previous = True
    os.rename(staging, target)
except BaseException:
    if moved_previous and not target.exists():
        os.rename(previous, target)
    if staging.exists():
        shutil.rmtree(staging)
    raise
if moved_previous:
    shutil.rmtree(previous)
print(f'Packaged {len(required)} PaperShelf App Intents in {target}')
PY
