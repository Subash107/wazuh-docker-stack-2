#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restore-sensor-vm.sh --archive /path/to/archive.tgz --manager-ip <wazuh-manager-ip> [--skip-package-install]
EOF
}

ARCHIVE=""
MANAGER_IP=""
SKIP_PACKAGE_INSTALL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      ARCHIVE="$2"
      shift 2
      ;;
    --manager-ip)
      MANAGER_IP="$2"
      shift 2
      ;;
    --skip-package-install)
      SKIP_PACKAGE_INSTALL="true"
      shift
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

if [[ -z "$ARCHIVE" || -z "$MANAGER_IP" ]]; then
  usage
  exit 1
fi

ensure_group() {
  local name="$1"
  local gid="$2"
  if getent group "$name" >/dev/null 2>&1; then
    return
  fi
  groupadd -g "$gid" "$name"
}

ensure_user() {
  local name="$1"
  local uid="$2"
  local group="$3"
  local home="$4"
  local shell="$5"
  if id "$name" >/dev/null 2>&1; then
    return
  fi
  useradd -u "$uid" -g "$group" -d "$home" -s "$shell" -M "$name"
}

if [[ "$SKIP_PACKAGE_INSTALL" != "true" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    cron \
    docker.io \
    mitmproxy \
    openssh-server \
    python3 \
    python3-pip \
    python3-venv \
    rsyslog \
    suricata

  apt-get install -y docker-compose-plugin >/dev/null 2>&1 || apt-get install -y docker-compose >/dev/null 2>&1 || true
fi

enable_and_restart_if_present() {
  local service="$1"
  if systemctl list-unit-files "$service" >/dev/null 2>&1; then
    systemctl enable "$service" >/dev/null 2>&1 || true
    systemctl restart "$service" >/dev/null 2>&1 || true
  fi
}

ensure_group cowrie 1001
ensure_user cowrie 1001 cowrie /home/cowrie /usr/sbin/nologin
ensure_group maltrail 987
ensure_user maltrail 996 maltrail /opt/maltrail /usr/sbin/nologin
ensure_group opencanary 986
ensure_user opencanary 995 opencanary /opt/opencanary /usr/sbin/nologin
ensure_group wazuh 111
ensure_user wazuh 110 wazuh /var/ossec /usr/sbin/nologin

tar --same-owner -xzf "$ARCHIVE" -C /

if [[ -f /var/ossec/etc/ossec.conf ]]; then
  sed -i -E "s#<address>[^<]+</address>#<address>${MANAGER_IP}</address>#g" /var/ossec/etc/ossec.conf
fi

systemctl daemon-reload

for service in \
  cowrie \
  maltrail-sensor \
  maltrail-server \
  mitmproxy \
  monitoring-sensor-compose \
  monitoring-sensor-firewall \
  opencanary \
  suricata \
  wazuh-agent
do
  enable_and_restart_if_present "$service"
done

echo "Sensor VM restore completed."
echo "Verify services with: systemctl --no-pager --type=service --state=running"
