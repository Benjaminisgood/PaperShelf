#!/bin/bash
set -euo pipefail
umask 077
# Runtime setup must never write bytecode or build metadata into signed app resources.
export PYTHONDONTWRITEBYTECODE=1

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV_PATH=""
PYTHON_EXECUTABLE="${PAPERSHELF_PYTHON:-python3}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root) SOURCE_ROOT="$2"; shift 2 ;;
        --venv) VENV_PATH="$2"; shift 2 ;;
        --python) PYTHON_EXECUTABLE="$2"; shift 2 ;;
        --help) printf '%s\n' 'Usage: setup_integrations.sh [--source-root PATH] [--venv PATH] [--python PYTHON]' 'Install the pinned MarkItDown and Graphiti sources plus the PaperShelf backend.'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"
VENV_PATH="${VENV_PATH:-$SOURCE_ROOT/.venv}"
if [[ ! -f "$SOURCE_ROOT/integrations/markitdown/packages/markitdown/pyproject.toml" || ! -f "$SOURCE_ROOT/integrations/graphiti/pyproject.toml" || ! -f "$SOURCE_ROOT/integrations/Paper2Agent/skills/paper2agent/SKILL.md" ]]; then
    if [[ -e "$SOURCE_ROOT/.git" ]]; then
        git -C "$SOURCE_ROOT" submodule update --init --recursive
    else
        printf '%s\n' 'Bundled integration sources are incomplete. Rebuild or reinstall PaperShelf.' >&2
        exit 1
    fi
fi
"$PYTHON_EXECUTABLE" -c 'import sys; assert (3, 11) <= sys.version_info[:2] < (3, 15), "Python 3.11–3.14 is required by the bundled Paper2Agent workflow"'
if [[ ! -x "$VENV_PATH/bin/python" ]]; then
    "$PYTHON_EXECUTABLE" -m venv "$VENV_PATH"
fi
BUILD_SOURCE="$(mktemp -d "$VENV_PATH/.source-build.XXXXXX")"
trap 'rm -rf -- "$BUILD_SOURCE"' EXIT
"$VENV_PATH/bin/python" - "$SOURCE_ROOT" "$BUILD_SOURCE" <<'PY'
from pathlib import Path
import shutil, stat, sys
source, staging = map(Path, sys.argv[1:])
ignore = shutil.ignore_patterns('.git', '__pycache__', '*.pyc', '*.pyo', '*.egg-info',
                                '.pytest_cache', '.mypy_cache', '.ruff_cache', 'build', 'dist')
for relative in ('backend', 'integrations/markitdown', 'integrations/graphiti', 'integrations/Paper2Agent'):
    target = staging / relative
    shutil.copytree(source / relative, target, ignore=ignore)
shutil.copy2(source / 'integrations/adapter-requirements.txt', staging / 'integrations/adapter-requirements.txt')
# App resources may be read-only. Only the private build copies become writable.
for path in [staging, *staging.rglob('*')]:
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IRUSR | stat.S_IWUSR | (stat.S_IXUSR if path.is_dir() else 0))
PY
"$VENV_PATH/bin/python" - "$BUILD_SOURCE/integrations/Paper2Agent/skills/paper2agent/paper2skill/scripts/paper_bundle.py" "$VENV_PATH/paper2agent-requirements.txt" <<'PY'
from pathlib import Path
import sys, tomllib
source = Path(sys.argv[1]).read_text()
block = source.split('# /// script\n', 1)[1].split('# ///', 1)[0]
metadata = tomllib.loads('\n'.join(line.removeprefix('# ') for line in block.splitlines()))
Path(sys.argv[2]).write_text('\n'.join(metadata['dependencies']) + '\n')
PY
"$VENV_PATH/bin/python" -m pip install --disable-pip-version-check \
    -r "$BUILD_SOURCE/integrations/adapter-requirements.txt" \
    -r "$VENV_PATH/paper2agent-requirements.txt" \
    "$BUILD_SOURCE/integrations/markitdown/packages/markitdown[pdf,docx,pptx,xlsx,xls]" \
    "$BUILD_SOURCE/integrations/graphiti[falkordb]" \
    "$BUILD_SOURCE/backend"
PAPERSHELF_ROOT="$SOURCE_ROOT" "$VENV_PATH/bin/python" -m papershelf_pipeline.integrations doctor
printf '\nPython runtime installed: %s/bin/python\n' "$VENV_PATH"
