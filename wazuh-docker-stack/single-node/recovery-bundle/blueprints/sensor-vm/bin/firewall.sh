#!/usr/bin/env bash
set -euo pipefail

LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
PROTECTED_TCP_PORTS="${PROTECTED_TCP_PORTS:-53,8080,8082,8083}"
PROTECTED_UDP_PORTS="${PROTECTED_UDP_PORTS:-53}"
CHAIN_NAME="MONITORING_SENSOR_GUARD"

if ! command -v iptables >/dev/null 2>&1; then
  echo "iptables is required to apply the monitoring sensor firewall policy." >&2
  exit 1
fi

iptables -n -L DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER
iptables -N "$CHAIN_NAME" >/dev/null 2>&1 || true
iptables -F "$CHAIN_NAME"
iptables -C DOCKER-USER -j "$CHAIN_NAME" >/dev/null 2>&1 || iptables -I DOCKER-USER 1 -j "$CHAIN_NAME"

iptables -A "$CHAIN_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A "$CHAIN_NAME" -s "$LAN_CIDR" -p tcp -m multiport --dports "$PROTECTED_TCP_PORTS" -j RETURN
iptables -A "$CHAIN_NAME" -s "$LAN_CIDR" -p udp -m multiport --dports "$PROTECTED_UDP_PORTS" -j RETURN
iptables -A "$CHAIN_NAME" -p tcp -m multiport --dports "$PROTECTED_TCP_PORTS" -j DROP
iptables -A "$CHAIN_NAME" -p udp -m multiport --dports "$PROTECTED_UDP_PORTS" -j DROP
iptables -A "$CHAIN_NAME" -j RETURN
