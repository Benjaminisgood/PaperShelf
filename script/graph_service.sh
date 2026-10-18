#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRAPH_ENV="${PAPERSHELF_GRAPH_ENV:-$HOME/Library/Application Support/PaperShelf/graph-service/neo4j.env}"
DOCKER_EXECUTABLE="${PAPERSHELF_DOCKER:-$(command -v docker || true)}"
if [[ -z "$DOCKER_EXECUTABLE" && -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
    DOCKER_EXECUTABLE=/Applications/Docker.app/Contents/Resources/bin/docker
fi
if [[ -z "$DOCKER_EXECUTABLE" ]]; then
    printf '%s\n' 'Docker CLI is unavailable. Install/start Docker Desktop.' >&2
    exit 1
fi
if [[ ! -f "$GRAPH_ENV" ]]; then
    printf 'Missing graph service environment file: %s\n' "$GRAPH_ENV" >&2
    printf '%s\n' 'Create it with NEO4J_PASSWORD and mode 0600, and save the same password in PaperShelf settings.' >&2
    exit 1
fi
case "${1:-status}" in
    start) ACTION=(up -d --wait) ;;
    stop) ACTION=(down) ;;
    status) ACTION=(ps) ;;
    *) printf '%s\n' 'Usage: graph_service.sh [start|status|stop] (stop preserves the data volume)'; exit 2 ;;
esac
exec "$DOCKER_EXECUTABLE" compose --env-file "$GRAPH_ENV" -p papershelf-graph -f "$SOURCE_ROOT/integrations/compose.yaml" "${ACTION[@]}"
