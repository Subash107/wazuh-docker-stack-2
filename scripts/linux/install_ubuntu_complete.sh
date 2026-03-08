#!/bin/bash

# This script will be source copied from Windows into Ubuntu and executed there
# Complete Wazuh and Monitoring Services Setup

set -e

WAZUH_MANAGER_IP="192.168.1.7"
WAZUH_MANAGER_PORT="1514"

export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo "Installing Wazuh & Monitoring Services"
echo "=========================================="
echo ""

# Update system
echo "[1/8] Updating system packages..."
sudo apt-get update > /dev/null 2>&1
sudo apt-get upgrade -y > /dev/null 2>&1

# Install basic dependencies
echo "[2/8] Installing dependencies..."
sudo apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring wget jq docker.io docker-compose net-tools > /dev/null 2>&1

# Start Docker
echo "[3/8] Starting Docker service..."
sudo systemctl enable docker > /dev/null 2>&1
sudo systemctl start docker > /dev/null 2>&1
sudo usermod -aG docker $USER > /dev/null 2>&1 || true

# Install Wazuh Agent
echo "[4/8] Installing Wazuh Agent..."
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import > /dev/null 2>&1
sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list > /dev/null 2>&1
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y wazuh-agent > /dev/null 2>&1

# Configure Wazuh Agent
echo "[5/8] Configuring Wazuh Agent..."
sudo systemctl stop wazuh-agent 2>/dev/null || true

sudo tee /var/ossec/etc/ossec.conf > /dev/null <<'OSSEC_CONFIG'
<ossec_config>
  <client>
    <server>
      <address>192.168.1.7</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <client_buffer>
      <disabled>no</disabled>
      <queue_size>5000</queue_size>
    </client_buffer>
  </client>

  <logging>
    <log_format>plain</log_format>
  </logging>

  <localfile>
    <log_format>command</log_format>
    <command>df -h</command>
    <frequency>300</frequency>
  </localfile>

  <localfile>
    <log_format>command</log_format>
    <command>free -m</command>
    <frequency>300</frequency>
  </localfile>

  <localfile>
    <log_format>command</log_format>
    <command>ps auxf</command>
    <frequency>300</frequency>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/ssh*</location>
  </localfile>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*.log</location>
  </localfile>

  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pihole/pihole.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/mitmproxy/mitmproxy.log</location>
  </localfile>

  <integrity_monitoring>
    <disabled>no</disabled>
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/usr/bin</directories>
  </integrity_monitoring>

  <rootkit_detection>
    <disabled>no</disabled>
  </rootkit_detection>

</ossec_config>
OSSEC_CONFIG

sudo chown root:wazuh /var/ossec/etc/ossec.conf > /dev/null 2>&1
sudo chmod 640 /var/ossec/etc/ossec.conf > /dev/null 2>&1
sudo systemctl daemon-reload > /dev/null 2>&1
sudo systemctl enable wazuh-agent > /dev/null 2>&1
sudo systemctl start wazuh-agent > /dev/null 2>&1

echo "[6/8] Installing Pi-hole DNS Filter..."
mkdir -p ~/pihole-docker
cat > ~/pihole-docker/docker-compose.yml <<'PIHOLE_EOF'
version: '3'
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "67:67/udp"
      - "80:80/tcp"
      - "443:443/tcp"
    environment:
      TZ: 'UTC'
      WEBPASSWORD: 'CHANGE_ME'
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
PIHOLE_EOF

cd ~/pihole-docker && docker-compose up -d > /dev/null 2>&1 &
sleep 5

echo "[7/8] Installing Mitmproxy Proxy..."
mkdir -p ~/mitmproxy-docker
cat > ~/mitmproxy-docker/docker-compose.yml <<'MITMPROXY_EOF'
version: '3'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
    container_name: mitmproxy
    restart: unless-stopped
    ports:
      - "8080:8080/tcp"
    volumes:
      - ./mitmproxy_data:/home/mitmproxy/.mitmproxy
    entrypoint: mitmproxy -p 8080 --mode regular --listen-host 0.0.0.0
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
MITMPROXY_EOF

cd ~/mitmproxy-docker && docker-compose up -d > /dev/null 2>&1 &
sleep 5

echo "[8/8] Installing Suricata IDS..."
sudo apt-get install -y suricata > /dev/null 2>&1
sudo mkdir -p /var/log/suricata > /dev/null 2>&1
sudo chown -R suricata:suricata /var/log/suricata > /dev/null 2>&1 || true

# Update Suricata rules
sudo suricata-update update-sources > /dev/null 2>&1 || true
sudo suricata-update enable-source et/open > /dev/null 2>&1 || true
sudo suricata-update > /dev/null 2>&1 || true

sudo systemctl enable suricata > /dev/null 2>&1
sudo systemctl restart suricata > /dev/null 2>&1
sleep 2

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Service Status:"
sudo systemctl status wazuh-agent --no-pager 2>/dev/null | head -5
sudo systemctl status suricata --no-pager 2>/dev/null | head -5
echo ""
echo "Docker Status:"
docker ps --filter "name=pihole" --format "pihole: {{.State}}"
docker ps --filter "name=mitmproxy" --format "mitmproxy: {{.State}}"
echo ""
echo "=========================================="
echo "Access Points:"
echo "=========================================="
echo "Wazuh Dashboard: https://192.168.1.7:5601"
echo "  User: admin"
echo "  Password: configured on your Wazuh deployment"
echo ""
echo "Pi-hole Admin: http://192.168.1.6"
echo "  Password: set before deployment"
echo ""
echo "Mitmproxy Web UI: http://192.168.1.6:8080"
echo ""
echo "Agent Logs:"
sudo tail -5 /var/ossec/logs/ossec.log 2>/dev/null
echo "=========================================="

