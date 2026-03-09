#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install_host.sh --manager-ip <wazuh-manager-ip> [--manager-port 1514] [--agent-name ubuntu-soc]

This installer keeps the 4 GB profile small:
- native Suricata
- native Wazuh agent
- Docker Cowrie, Prometheus, Alertmanager, Grafana, node-exporter, and SOC telemetry exporter

OpenCTI is not started by default. Use docker-compose.opencti.yml only if you accept degraded performance on 4 GB RAM.
EOF
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
  fi
}

install_wazuh_repository() {
  if [[ ! -f /usr/share/keyrings/wazuh.gpg ]]; then
    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
    chmod 0644 /usr/share/keyrings/wazuh.gpg
  fi

  cat > /etc/apt/sources.list.d/wazuh.list <<'EOF'
deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main
EOF
}

render_template() {
  local template="$1"
  local destination="$2"
  local manager_ip="$3"
  local manager_port="$4"

  sed \
    -e "s/__MANAGER_IP__/$manager_ip/g" \
    -e "s/__MANAGER_PORT__/$manager_port/g" \
    "$template" > "$destination"
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl docker.io gpg jq python3 suricata
  apt-get install -y docker-compose-plugin >/dev/null 2>&1 || apt-get install -y docker-compose >/dev/null 2>&1 || true
  systemctl enable docker
  systemctl restart docker
}

configure_suricata() {
  install -d -m 0755 /var/log/suricata
  chown -R suricata:suricata /var/log/suricata || true
  suricata-update update-sources >/dev/null 2>&1 || true
  suricata-update enable-source et/open >/dev/null 2>&1 || true
  suricata-update >/dev/null 2>&1 || true
  systemctl enable suricata
  systemctl restart suricata
}

configure_wazuh_agent() {
  install_wazuh_repository
  apt-get update
  apt-get install -y wazuh-agent
  install -d -m 0755 /var/ossec/etc
  render_template "$OSSEC_TEMPLATE" /var/ossec/etc/ossec.conf "$MANAGER_IP" "$MANAGER_PORT"
  chown root:wazuh /var/ossec/etc/ossec.conf
  chmod 0640 /var/ossec/etc/ossec.conf
  systemctl enable wazuh-agent
  systemctl restart wazuh-agent
}

prepare_cowrie_paths() {
  install -d -m 0755 /opt/cowrie/etc
  install -d -m 0755 /opt/cowrie/var/log/cowrie
  install -d -m 0755 /opt/cowrie/var/lib/cowrie
}

ensure_project_env() {
  if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
  fi

  python3 - "$PROJECT_ROOT/.env" "$MANAGER_IP" "$MANAGER_PORT" "$AGENT_NAME" <<'PY'
import pathlib
import sys

env_path = pathlib.Path(sys.argv[1])
manager_ip = sys.argv[2]
manager_port = sys.argv[3]
agent_name = sys.argv[4]

lines = []
seen = set()
for raw_line in env_path.read_text(encoding="utf-8").splitlines():
    if raw_line.startswith("WAZUH_MANAGER_IP="):
        lines.append(f"WAZUH_MANAGER_IP={manager_ip}")
        seen.add("WAZUH_MANAGER_IP")
    elif raw_line.startswith("WAZUH_MANAGER_PORT="):
        lines.append(f"WAZUH_MANAGER_PORT={manager_port}")
        seen.add("WAZUH_MANAGER_PORT")
    elif raw_line.startswith("WAZUH_AGENT_NAME="):
        lines.append(f"WAZUH_AGENT_NAME={agent_name}")
        seen.add("WAZUH_AGENT_NAME")
    else:
        lines.append(raw_line)

for key, value in (
    ("WAZUH_MANAGER_IP", manager_ip),
    ("WAZUH_MANAGER_PORT", manager_port),
    ("WAZUH_AGENT_NAME", agent_name),
):
    if key not in seen:
        lines.append(f"{key}={value}")

env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

start_core_stack() {
  (cd "$PROJECT_ROOT" && docker compose up -d)
}

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
OSSEC_TEMPLATE="$REPO_ROOT/wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/config/ossec.conf.template"
MANAGER_IP=""
MANAGER_PORT="1514"
AGENT_NAME="ubuntu-soc"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manager-ip)
      MANAGER_IP="$2"
      shift 2
      ;;
    --manager-port)
      MANAGER_PORT="$2"
      shift 2
      ;;
    --agent-name)
      AGENT_NAME="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_root

if [[ -z "$MANAGER_IP" ]]; then
  echo "--manager-ip is required." >&2
  exit 1
fi

install_base_packages
configure_suricata
configure_wazuh_agent
prepare_cowrie_paths
ensure_project_env
start_core_stack

cat <<EOF
Ubuntu lightweight SOC host is ready.

Core services:
- Suricata log path: /var/log/suricata/eve.json
- Cowrie log path: /opt/cowrie/var/log/cowrie/cowrie.json
- Grafana: http://$(hostname -I | awk '{print $1}'):3001
- Prometheus: http://$(hostname -I | awk '{print $1}'):9091

Next steps:
1. Enroll the host in your Wazuh manager and verify the local rules/list files are mounted there.
2. Export indicators from OpenCTI to CSV and run:
   python3 $PROJECT_ROOT/scripts/export_opencti_csv_to_wazuh.py /path/to/opencti-export.csv
3. Restart the Wazuh manager after updating lists or local rules.
EOF
