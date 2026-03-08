#!/bin/bash

set -euo pipefail

UBUNTU_HOST="${UBUNTU_HOST:-192.168.1.6}"
UBUNTU_USER="${UBUNTU_USER:-subash}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SUDO_PASSWORD="${SUDO_PASSWORD:-$SSH_PASSWORD}"

if [ -z "$SSH_PASSWORD" ]; then
  echo "Set SSH_PASSWORD before running this script."
  exit 1
fi

if [ -z "$SUDO_PASSWORD" ]; then
  echo "Set SUDO_PASSWORD before running this script."
  exit 1
fi

apt-get update >/dev/null 2>&1
apt-get install -y openssh-client sshpass >/dev/null 2>&1

export SSHPASS="$SSH_PASSWORD"
sshpass -e ssh -o StrictHostKeyChecking=no "${UBUNTU_USER}@${UBUNTU_HOST}" bash <<EOF
set -euo pipefail
SUDO_PASSWORD='${SUDO_PASSWORD}'

echo "===== UPGRADING PIHOLE ====="
cd ~/pihole-docker
echo "\$SUDO_PASSWORD" | sudo -S docker-compose pull
echo "\$SUDO_PASSWORD" | sudo -S docker stop pihole 2>/dev/null || true
echo "\$SUDO_PASSWORD" | sudo -S docker rm pihole 2>/dev/null || true
echo "\$SUDO_PASSWORD" | sudo -S docker-compose up -d

echo "===== STARTING MITMPROXY ====="
mkdir -p ~/mitmproxy-docker
cd ~/mitmproxy-docker
cat > docker-compose.yml <<'MITMPROXY'
version: '3'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
    container_name: mitmproxy
    restart: unless-stopped
    ports:
      - "8082:8080"
      - "8083:8081"
    entrypoint: mitmweb -p 8080 --mode regular --listen-host 0.0.0.0 --web-host 0.0.0.0 --web-port 8081
MITMPROXY
echo "\$SUDO_PASSWORD" | sudo -S docker-compose pull
echo "\$SUDO_PASSWORD" | sudo -S docker stop mitmproxy 2>/dev/null || true
echo "\$SUDO_PASSWORD" | sudo -S docker rm mitmproxy 2>/dev/null || true
echo "\$SUDO_PASSWORD" | sudo -S docker-compose up -d
EOF
