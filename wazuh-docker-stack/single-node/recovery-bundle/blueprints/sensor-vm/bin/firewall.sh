#!/usr/bin/env bash
set -euo pipefail

LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
LAN_INTERFACE="${LAN_INTERFACE:-}"
PROTECTED_TCP_PORTS="${PROTECTED_TCP_PORTS:-53,8080,8082,8083}"
PROTECTED_UDP_PORTS="${PROTECTED_UDP_PORTS:-53}"
CHAIN_NAME="MONITORING_SENSOR_GUARD"

if ! command -v iptables >/dev/null 2>&1; then
  echo "iptables is required to apply the monitoring sensor firewall policy." >&2
  exit 1
fi

if [[ -z "$LAN_INTERFACE" ]] && command -v ip >/dev/null 2>&1; then
  LAN_INTERFACE="$(ip route show default 0.0.0.0/0 | awk '/default/ { print $5; exit }')"
fi

if [[ -z "$LAN_INTERFACE" ]]; then
  echo "Could not determine the LAN interface for the monitoring sensor firewall policy." >&2
  exit 1
fi

iptables -n -L DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER
iptables -N "$CHAIN_NAME" >/dev/null 2>&1 || true
iptables -F "$CHAIN_NAME"
iptables -C DOCKER-USER -j "$CHAIN_NAME" >/dev/null 2>&1 || iptables -I DOCKER-USER 1 -j "$CHAIN_NAME"

iptables -A "$CHAIN_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
# Only restrict traffic entering the sensor from the LAN interface. Container
# egress uses the same destination ports (notably UDP/53) and must not match.
iptables -A "$CHAIN_NAME" -i "$LAN_INTERFACE" -s "$LAN_CIDR" -p tcp -m multiport --dports "$PROTECTED_TCP_PORTS" -j RETURN
iptables -A "$CHAIN_NAME" -i "$LAN_INTERFACE" -s "$LAN_CIDR" -p udp -m multiport --dports "$PROTECTED_UDP_PORTS" -j RETURN
iptables -A "$CHAIN_NAME" -i "$LAN_INTERFACE" -p tcp -m multiport --dports "$PROTECTED_TCP_PORTS" -j DROP
iptables -A "$CHAIN_NAME" -i "$LAN_INTERFACE" -p udp -m multiport --dports "$PROTECTED_UDP_PORTS" -j DROP
iptables -A "$CHAIN_NAME" -j RETURN
