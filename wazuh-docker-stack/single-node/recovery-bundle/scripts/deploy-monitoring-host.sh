#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-monitoring-host.sh --host-address <ip-or-dns> [--target-root /opt/monitoring] [--bundle-stamp <stamp>] [--restore-volume-backups] [--skip-start] [--skip-local-seed] [--skip-validation]
EOF
}

HOST_ADDRESS=""
TARGET_ROOT="/opt/monitoring"
RESTORE_VOLUME_BACKUPS="false"
SKIP_START="false"
SKIP_LOCAL_SEED="false"
SKIP_VALIDATION="false"
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
    --skip-local-seed)
      SKIP_LOCAL_SEED="true"
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION="true"
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

if [[ "$SKIP_VALIDATION" == "true" && "$SKIP_START" != "true" ]]; then
  echo "--skip-validation is only supported together with --skip-start." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required on the target host." >&2
  exit 1
fi

is_monitoring_source_root() {
  local path="$1"
  [[ -f "$path/docker-compose.yml" && -f "$path/scripts/windows/Invoke-MonitoringPhase1Rollout.ps1" ]]
}

is_wazuh_single_node_source_root() {
  local path="$1"
  [[ -f "$path/docker-compose.yml" && -f "$path/config/wazuh_cluster/ossec.conf" ]]
}

get_latest_bundle_snapshot() {
  if [[ ! -d "$BACKUP_ROOT" ]]; then
    return 1
  fi

  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
    sort -nr |
    head -n 1 |
    cut -d' ' -f2-
}

resolve_deployment_sources() {
  local canonical_wazuh_single_root="$SOURCE_WAZUH_ROOT/single-node"
  local legacy_monitoring_root="$BUNDLE_ROOT/blueprints/monitoring-host/monitoring-stack"
  local legacy_wazuh_root="$BUNDLE_ROOT/blueprints/monitoring-host/wazuh-single-node"

  if [[ -n "$BUNDLE_STAMP" ]]; then
    local snapshot_root="$BACKUP_ROOT/$BUNDLE_STAMP"
    local snapshot_monitoring_root="$snapshot_root/monitoring-stack"
    local snapshot_wazuh_root="$snapshot_root/wazuh-single-node"
    if ! is_monitoring_source_root "$snapshot_monitoring_root" || ! is_wazuh_single_node_source_root "$snapshot_wazuh_root"; then
      echo "Bundle stamp '$BUNDLE_STAMP' does not contain a complete host snapshot under '$snapshot_root'." >&2
      exit 1
    fi

    MONITORING_SOURCE="$snapshot_monitoring_root"
    WAZUH_SOURCE="$snapshot_wazuh_root"
    DEPLOYMENT_SOURCE_TYPE="snapshot"
    return 0
  fi

  if is_monitoring_source_root "$SOURCE_MONITORING_ROOT" && is_wazuh_single_node_source_root "$canonical_wazuh_single_root"; then
    MONITORING_SOURCE="$SOURCE_MONITORING_ROOT"
    WAZUH_SOURCE="$canonical_wazuh_single_root"
    DEPLOYMENT_SOURCE_TYPE="canonical"
    return 0
  fi

  local latest_snapshot=""
  latest_snapshot="$(get_latest_bundle_snapshot || true)"
  if [[ -n "$latest_snapshot" ]]; then
    local snapshot_monitoring_root="$latest_snapshot/monitoring-stack"
    local snapshot_wazuh_root="$latest_snapshot/wazuh-single-node"
    if is_monitoring_source_root "$snapshot_monitoring_root" && is_wazuh_single_node_source_root "$snapshot_wazuh_root"; then
      MONITORING_SOURCE="$snapshot_monitoring_root"
      WAZUH_SOURCE="$snapshot_wazuh_root"
      DEPLOYMENT_SOURCE_TYPE="latest-snapshot"
      return 0
    fi
  fi

  if is_monitoring_source_root "$legacy_monitoring_root" && is_wazuh_single_node_source_root "$legacy_wazuh_root"; then
    MONITORING_SOURCE="$legacy_monitoring_root"
    WAZUH_SOURCE="$legacy_wazuh_root"
    DEPLOYMENT_SOURCE_TYPE="legacy-blueprint"
    return 0
  fi

  echo "No deployable host source was found. Use the live repository source or provide a recovery bundle with backups/monitoring-host/<stamp>." >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_MONITORING_ROOT="$(cd "$BUNDLE_ROOT/../../.." && pwd)"
SOURCE_MONITORING_SECRETS="$SOURCE_MONITORING_ROOT/secrets"
SOURCE_WAZUH_ROOT="$(cd "$BUNDLE_ROOT/../.." && pwd)"
SOURCE_WAZUH_SECRETS="$SOURCE_WAZUH_ROOT/secrets"
WAZUH_TARGET="$TARGET_ROOT/wazuh-docker-stack/single-node"
WAZUH_ROOT_TARGET="$TARGET_ROOT/wazuh-docker-stack"
WAZUH_SECRETS_TARGET="$WAZUH_ROOT_TARGET/secrets"
RECOVERY_BUNDLE_TARGET="$WAZUH_TARGET/recovery-bundle"
BACKUP_ROOT="$BUNDLE_ROOT/backups/monitoring-host"
DEPLOYMENT_SOURCE_TYPE=""

resolve_deployment_sources

mkdir -p "$TARGET_ROOT" "$WAZUH_ROOT_TARGET" "$WAZUH_TARGET" "$WAZUH_SECRETS_TARGET" "$RECOVERY_BUNDLE_TARGET" "$RECOVERY_BUNDLE_TARGET/config" "$RECOVERY_BUNDLE_TARGET/scripts" "$RECOVERY_BUNDLE_TARGET/blueprints"
cp -af "$MONITORING_SOURCE/." "$TARGET_ROOT/"
if [[ "$SKIP_LOCAL_SEED" != "true" && -d "$SOURCE_MONITORING_SECRETS" ]]; then
  cp -af "$SOURCE_MONITORING_SECRETS/." "$TARGET_ROOT/secrets/"
fi
cp -af "$WAZUH_SOURCE/." "$WAZUH_TARGET/"
if [[ "$SKIP_LOCAL_SEED" != "true" && -f "$SOURCE_WAZUH_ROOT/.env" ]]; then
  cp -af "$SOURCE_WAZUH_ROOT/.env" "$WAZUH_ROOT_TARGET/.env"
elif [[ "$SKIP_LOCAL_SEED" != "true" && -f "$WAZUH_SOURCE/.env.example" ]]; then
  cp -af "$WAZUH_SOURCE/.env.example" "$WAZUH_ROOT_TARGET/.env"
fi
cp -af "$WAZUH_SOURCE/secrets/." "$WAZUH_SECRETS_TARGET/"
if [[ "$SKIP_LOCAL_SEED" != "true" && -d "$SOURCE_WAZUH_SECRETS" ]]; then
  cp -af "$SOURCE_WAZUH_SECRETS/." "$WAZUH_SECRETS_TARGET/"
fi
cp -af "$BUNDLE_ROOT/README.md" "$RECOVERY_BUNDLE_TARGET/"
cp -af "$BUNDLE_ROOT/scripts/." "$RECOVERY_BUNDLE_TARGET/scripts/"
cp -af "$BUNDLE_ROOT/blueprints/sensor-vm" "$RECOVERY_BUNDLE_TARGET/blueprints/"
cp -af "$BUNDLE_ROOT/config/hyperv-provision.env.example" "$BUNDLE_ROOT/config/offsite-backup.env.example" "$RECOVERY_BUNDLE_TARGET/config/"

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

if [[ "$SKIP_VALIDATION" != "true" ]]; then
  "$TARGET_ROOT/scripts/linux/run_wazuh_single_node_compose.sh" --project-root "$TARGET_ROOT" config >/dev/null
  docker compose -f "$TARGET_ROOT/docker-compose.yml" -p monitoring config >/dev/null
fi

if [[ "$SKIP_START" != "true" ]]; then
  "$TARGET_ROOT/scripts/linux/run_wazuh_single_node_compose.sh" --project-root "$TARGET_ROOT" up -d
  docker compose -f "$TARGET_ROOT/docker-compose.yml" -p monitoring up -d
fi

cat <<EOF
Monitoring host deployed to $TARGET_ROOT
Host deployment source: $DEPLOYMENT_SOURCE_TYPE
$( [[ "$RESTORE_VOLUME_BACKUPS" == "true" && -n "$BUNDLE_STAMP" ]] && printf 'Restored stateful Docker volumes from bundle stamp: %s\n' "$BUNDLE_STAMP" )
$( [[ "$SKIP_LOCAL_SEED" == "true" ]] && printf 'Local runtime secrets and .env files were not seeded into the target root.\n' )
$( [[ "$SKIP_VALIDATION" == "true" ]] && printf 'Config validation was skipped for staged rebuild use.\n' )
Next step for the Ubuntu sensor VM:
  Clean bootstrap: powershell -ExecutionPolicy Bypass -File ./scripts/windows/Invoke-SensorVmBootstrap.ps1 -VmAddress 192.168.1.6 -VmUser subash
  Archive restore: sudo bash restore-sensor-vm.sh --archive /path/to/ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip $HOST_ADDRESS
EOF
