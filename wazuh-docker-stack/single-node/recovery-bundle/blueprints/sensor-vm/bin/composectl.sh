#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: composectl.sh <working-directory> <up|down|pull>" >&2
  exit 1
fi

working_directory="$1"
action="$2"

if docker compose version >/dev/null 2>&1; then
  compose_cmd=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose_cmd=(docker-compose)
else
  echo "Neither 'docker compose' nor 'docker-compose' is available." >&2
  exit 1
fi

cd "$working_directory"

case "$action" in
  up)
    "${compose_cmd[@]}" up -d --remove-orphans
    ;;
  down)
    "${compose_cmd[@]}" down
    ;;
  pull)
    "${compose_cmd[@]}" pull
    ;;
  *)
    echo "Unsupported action: $action" >&2
    exit 1
    ;;
esac
