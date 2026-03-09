#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
canonical_script="$repo_root/wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/scripts/bootstrap-sensor-vm.sh"

if [[ ! -f "$canonical_script" ]]; then
  echo "Canonical sensor bootstrap script was not found at:" >&2
  echo "  $canonical_script" >&2
  exit 1
fi

exec bash "$canonical_script" "$@"
