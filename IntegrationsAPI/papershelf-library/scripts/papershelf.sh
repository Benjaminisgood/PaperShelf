#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${PAPERSHELF_CLI:-}" ]]; then exec "$PAPERSHELF_CLI" "$@"; fi
if command -v papershelf >/dev/null 2>&1; then exec papershelf "$@"; fi
if [[ -x /Applications/PaperShelf.app/Contents/MacOS/PaperShelfCLI ]]; then exec /Applications/PaperShelf.app/Contents/MacOS/PaperShelfCLI "$@"; fi
echo 'Set PAPERSHELF_CLI to the installed PaperShelfCLI executable, or add papershelf to PATH.' >&2
exit 1