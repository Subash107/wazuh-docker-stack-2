#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-monitoring-host.sh --host-address <ip-or-dns> [--target-root /opt/monitoring] [--bundle-stamp <stamp>] [--restore-volume-backups] [--skip-start]
EOF
}

HOST_ADDRESS=""
TARGET_ROOT="/opt/monitoring"
RESTORE_VOLUME_BACKUPS="false"
SKIP_START="false"
BUNDLE_STAMP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-address)
      HOST_ADDRESS="$2"
      shift 2
      ;;
    --target-root)
      TARGET_ROOT="$2"
      shift 2
      ;;
    --bundle-stamp)
      BUNDLE_STAMP="$2"
      shift 2
      ;;
    --restore-volume-backups)
      RESTORE_VOLUME_BACKUPS="true"
      shift
      ;;
    --skip-start)
      SKIP_START="true"
      shift
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$HOST_ADDRESS" ]]; then
  usage
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required on the target host." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONITORING_SOURCE="$BUNDLE_ROOT/blueprints/monitoring-host/monitoring-stack"
WAZUH_SOURCE="$BUNDLE_ROOT/blueprints/monitoring-host/wazuh-single-node"
WAZUH_TARGET="$TARGET_ROOT/wazuh-docker-stack/single-node"
BACKUP_ROOT="$BUNDLE_ROOT/backups/monitoring-host"

mkdir -p "$TARGET_ROOT" "$WAZUH_TARGET"
cp -af "$MONITORING_SOURCE/." "$TARGET_ROOT/"
cp -af "$WAZUH_SOURCE/." "$WAZUH_TARGET/"

sed -i "s#WAZUH_DASHBOARD_URL=http://[^:]*:5601#WAZUH_DASHBOARD_URL=http://$HOST_ADDRESS:5601#g" "$TARGET_ROOT/docker-compose.yml"

if [[ "$RESTORE_VOLUME_BACKUPS" == "true" ]]; then
  if [[ -z "$BUNDLE_STAMP" ]]; then
    BUNDLE_STAMP="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)"
  fi

  if [[ -n "$BUNDLE_STAMP" && -d "$BACKUP_ROOT/$BUNDLE_STAMP/docker-volumes" ]]; then
    while IFS= read -r archive; do
      volume_name="$(basename "$archive" .tgz)"
      if docker ps -q --filter "volume=$volume_name" | grep -q .; then
        echo "Refusing to restore Docker volume '$volume_name' because it is attached to running containers." >&2
        exit 1
      fi

      docker volume create "$volume_name" >/dev/null
      docker run --rm \
        -v "$volume_name:/to" \
        -v "$BACKUP_ROOT/$BUNDLE_STAMP/docker-volumes:/backup:ro" \
        alpine:3.20 sh -lc "mkdir -p /to && tar -C /to -xzf /backup/$(basename "$archive")"
    done < <(find "$BACKUP_ROOT/$BUNDLE_STAMP/docker-volumes" -maxdepth 1 -type f -name '*.tgz' | sort)
  fi
fi

docker compose -f "$WAZUH_TARGET/docker-compose.yml" -p single-node config >/dev/null
docker compose -f "$TARGET_ROOT/docker-compose.yml" -p monitoring config >/dev/null

if [[ "$SKIP_START" != "true" ]]; then
  docker compose -f "$WAZUH_TARGET/docker-compose.yml" -p single-node up -d
  docker compose -f "$TARGET_ROOT/docker-compose.yml" -p monitoring up -d
fi

cat <<EOF
Monitoring host deployed to $TARGET_ROOT
$( [[ "$RESTORE_VOLUME_BACKUPS" == "true" && -n "$BUNDLE_STAMP" ]] && printf 'Restored stateful Docker volumes from bundle stamp: %s\n' "$BUNDLE_STAMP" )
Next step on the Ubuntu sensor VM:
  sudo bash restore-sensor-vm.sh --archive /path/to/ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip $HOST_ADDRESS
EOF
