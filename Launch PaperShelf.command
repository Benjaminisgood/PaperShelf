#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
exec ./script/build_and_run.sh
