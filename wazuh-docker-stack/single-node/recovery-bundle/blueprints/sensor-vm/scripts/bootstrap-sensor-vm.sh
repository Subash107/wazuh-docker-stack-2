#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-sensor-vm.sh [options]

Options:
  --env-file PATH               Load runtime values from a shell-style env file.
  --install-profile PROFILE     full or agent-only. Default: full
  --manager-ip ADDRESS          Wazuh manager address.
  --manager-port PORT           Wazuh manager port. Default: 1514
  --sensor-ip ADDRESS           Sensor VM address used for operator output.
  --lan-cidr CIDR               LAN CIDR allowed to reach the sensor ports.
  --tz TIMEZONE                 Service timezone. Default: UTC
  --pihole-web-password VALUE   Required for the full profile.
  --pihole-upstream-dns VALUE   Upstream DNS for Pi-hole. Default: 192.168.1.1
  --pihole-web-port PORT        Pi-hole admin port. Default: 8080
  --mitmproxy-proxy-port PORT   mitmproxy proxy port. Default: 8082
  --mitmproxy-web-port PORT     mitmproxy web UI port. Default: 8083
  --compose-project-root PATH   Install root for the sensor compose project.
  --help                        Show this help text.
EOF
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
  fi
}

load_env_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Env file '$path' was not found." >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  . "$path"
  set +a
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

ensure_compose_env() {
  local env_path="$1"

  cat > "$env_path" <<EOF
TZ=$TZ
PIHOLE_WEBPASSWORD=$PIHOLE_WEBPASSWORD
PIHOLE_UPSTREAM_DNS=$PIHOLE_UPSTREAM_DNS
PIHOLE_WEB_PORT=$PIHOLE_WEB_PORT
MITMPROXY_PROXY_PORT=$MITMPROXY_PROXY_PORT
MITMPROXY_WEB_PORT=$MITMPROXY_WEB_PORT
PIHOLE_IMAGE=$PIHOLE_IMAGE
MITMPROXY_IMAGE=$MITMPROXY_IMAGE
PIHOLE_LISTENING_MODE=$PIHOLE_LISTENING_MODE
EOF
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    docker.io \
    gpg \
    jq \
    lsb-release \
    suricata \
    ubuntu-keyring

  if ! apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
    apt-get install -y docker-compose >/dev/null 2>&1 || true
  fi

  systemctl enable docker
  systemctl restart docker
}

disable_legacy_sensor_units() {
  systemctl disable --now docker-user-hardening.service >/dev/null 2>&1 || true
  systemctl disable --now mitmproxy.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/docker-user-hardening.service
}

configure_wazuh_agent() {
  install_wazuh_repository
  apt-get update
  apt-get install -y wazuh-agent

  install -d -m 0755 /var/ossec/etc
  render_template \
    "$BLUEPRINT_ROOT/config/ossec.conf.template" \
    /var/ossec/etc/ossec.conf \
    "$MANAGER_IP" \
    "$MANAGER_PORT"

  chown root:wazuh /var/ossec/etc/ossec.conf
  chmod 0640 /var/ossec/etc/ossec.conf
  systemctl daemon-reload
  systemctl enable wazuh-agent
  systemctl restart wazuh-agent
}

configure_sensor_compose_stack() {
  install -d -m 0755 "$COMPOSE_PROJECT_ROOT"
  install -d -m 0755 "$COMPOSE_PROJECT_ROOT/data/pihole"
  install -d -m 0755 "$COMPOSE_PROJECT_ROOT/data/dnsmasq.d"
  install -d -m 0755 "$COMPOSE_PROJECT_ROOT/data/mitmproxy"
  install -d -m 0755 "$COMPOSE_PROJECT_ROOT/logs/pihole"

  install -d -m 0755 /usr/local/lib/monitoring-sensor
  install -m 0755 "$BLUEPRINT_ROOT/bin/composectl.sh" /usr/local/lib/monitoring-sensor/composectl.sh
  install -m 0755 "$BLUEPRINT_ROOT/bin/firewall.sh" /usr/local/lib/monitoring-sensor/firewall.sh

  install -m 0644 "$BLUEPRINT_ROOT/compose/docker-compose.yml" "$COMPOSE_PROJECT_ROOT/docker-compose.yml"
  ensure_compose_env "$COMPOSE_PROJECT_ROOT/.env"

  cat > /etc/default/monitoring-sensor <<EOF
LAN_CIDR=$LAN_CIDR
PROTECTED_TCP_PORTS=53,$PIHOLE_WEB_PORT,$MITMPROXY_PROXY_PORT,$MITMPROXY_WEB_PORT
PROTECTED_UDP_PORTS=53
EOF

  install -m 0644 "$BLUEPRINT_ROOT/systemd/monitoring-sensor-compose.service" /etc/systemd/system/monitoring-sensor-compose.service
  install -m 0644 "$BLUEPRINT_ROOT/systemd/monitoring-sensor-firewall.service" /etc/systemd/system/monitoring-sensor-firewall.service

  docker rm -f pihole mitmproxy >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl enable monitoring-sensor-compose monitoring-sensor-firewall
  systemctl restart monitoring-sensor-compose
  systemctl restart monitoring-sensor-firewall
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

show_summary() {
  echo
  echo "Sensor bootstrap completed."
  echo "Install profile: $INSTALL_PROFILE"
  echo "Manager: $MANAGER_IP:$MANAGER_PORT"
  if [[ "$INSTALL_PROFILE" == "full" ]]; then
    echo "Pi-hole: http://${SENSOR_IP}:${PIHOLE_WEB_PORT}/admin/login"
    echo "mitmproxy UI: http://${SENSOR_IP}:${MITMPROXY_WEB_PORT}/#/flows"
    echo "mitmproxy proxy: ${SENSOR_IP}:${MITMPROXY_PROXY_PORT}"
  fi
  echo "Wazuh agent status: $(systemctl is-active wazuh-agent 2>/dev/null || echo unknown)"
}

BLUEPRINT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE=""
INSTALL_PROFILE="${INSTALL_PROFILE:-full}"
MANAGER_IP="${MANAGER_IP:-}"
MANAGER_PORT="${MANAGER_PORT:-1514}"
SENSOR_IP="${SENSOR_IP:-192.168.1.6}"
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
TZ="${TZ:-UTC}"
PIHOLE_WEBPASSWORD="${PIHOLE_WEBPASSWORD:-}"
PIHOLE_UPSTREAM_DNS="${PIHOLE_UPSTREAM_DNS:-192.168.1.1}"
PIHOLE_WEB_PORT="${PIHOLE_WEB_PORT:-8080}"
MITMPROXY_PROXY_PORT="${MITMPROXY_PROXY_PORT:-8082}"
MITMPROXY_WEB_PORT="${MITMPROXY_WEB_PORT:-8083}"
PIHOLE_IMAGE="${PIHOLE_IMAGE:-pihole/pihole@sha256:ee348529cea9601df86ad94d62a39cad26117e1eac9e82d8876aa0ec7fe1ba27}"
MITMPROXY_IMAGE="${MITMPROXY_IMAGE:-mitmproxy/mitmproxy@sha256:743b6cdc817211d64bc269f5defacca8d14e76e647fc474e5c7244dbcb645141}"
PIHOLE_LISTENING_MODE="${PIHOLE_LISTENING_MODE:-all}"
COMPOSE_PROJECT_ROOT="${COMPOSE_PROJECT_ROOT:-/opt/monitoring-sensor}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --install-profile)
      INSTALL_PROFILE="$2"
      shift 2
      ;;
    --manager-ip)
      MANAGER_IP="$2"
      shift 2
      ;;
    --manager-port)
      MANAGER_PORT="$2"
      shift 2
      ;;
    --sensor-ip)
      SENSOR_IP="$2"
      shift 2
      ;;
    --lan-cidr)
      LAN_CIDR="$2"
      shift 2
      ;;
    --tz)
      TZ="$2"
      shift 2
      ;;
    --pihole-web-password)
      PIHOLE_WEBPASSWORD="$2"
      shift 2
      ;;
    --pihole-upstream-dns)
      PIHOLE_UPSTREAM_DNS="$2"
      shift 2
      ;;
    --pihole-web-port)
      PIHOLE_WEB_PORT="$2"
      shift 2
      ;;
    --mitmproxy-proxy-port)
      MITMPROXY_PROXY_PORT="$2"
      shift 2
      ;;
    --mitmproxy-web-port)
      MITMPROXY_WEB_PORT="$2"
      shift 2
      ;;
    --compose-project-root)
      COMPOSE_PROJECT_ROOT="$2"
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

if [[ -n "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
fi

require_root

if [[ -z "$MANAGER_IP" ]]; then
  echo "MANAGER_IP is required." >&2
  exit 1
fi

if [[ "$INSTALL_PROFILE" != "full" && "$INSTALL_PROFILE" != "agent-only" ]]; then
  echo "INSTALL_PROFILE must be 'full' or 'agent-only'." >&2
  exit 1
fi

if [[ "$INSTALL_PROFILE" == "full" && -z "$PIHOLE_WEBPASSWORD" ]]; then
  echo "PIHOLE_WEBPASSWORD is required for the full profile." >&2
  exit 1
fi

install_base_packages
disable_legacy_sensor_units
configure_wazuh_agent

if [[ "$INSTALL_PROFILE" == "full" ]]; then
  configure_sensor_compose_stack
  configure_suricata
fi

show_summary
