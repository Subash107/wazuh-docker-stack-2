#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

echo "Deprecated: delegating to scripts/linux/bootstrap_sensor_vm.sh" >&2
exec bash "$repo_root/scripts/linux/bootstrap_sensor_vm.sh" --install-profile full "$@"
