#!/bin/bash

# Complete Wazuh and Monitoring Services Setup for Ubuntu
# This script installs and configures everything needed

set -e

WAZUH_MANAGER_IP="192.168.1.7"
WAZUH_MANAGER_PORT="1514"

export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo "Complete Wazuh & Monitoring Setup"
echo "=========================================="
echo "Manager: $WAZUH_MANAGER_IP:$WAZUH_MANAGER_PORT"
echo ""

# Update system
echo "[1/10] Updating system packages..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# Install basic dependencies
echo "[2/10] Installing dependencies..."
sudo apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring wget jq docker.io docker-compose net-tools -qq

# Enable and start Docker
echo "[3/10] Starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER

# Install Wazuh Agent
echo "[4/10] Installing Wazuh Agent..."
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y wazuh-agent -qq

# Configure Wazuh Agent
echo "[5/10] Configuring Wazuh Agent..."
sudo systemctl stop wazuh-agent 2>/dev/null || true

sudo tee /var/ossec/etc/ossec.conf > /dev/null <<'EOF'
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

  <!-- System monitoring -->
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

  <!-- System and auth logs -->
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

  <!-- Docker logs -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*.log</location>
  </localfile>

  <!-- Suricata IDS logs -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>

  <!-- Pi-hole DNS logs -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pihole/pihole.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pihole/dnsmasq.log</location>
  </localfile>

  <!-- Mitmproxy logs -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/mitmproxy/mitmproxy.log</location>
  </localfile>

  <!-- File integrity monitoring -->
  <integrity_monitoring>
    <disabled>no</disabled>
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/usr/bin</directories>
    <directories check_all="yes" report_changes="yes">/var/www</directories>
  </integrity_monitoring>

  <!-- Rootkit detection -->
  <rootkit_detection>
    <disabled>no</disabled>
    <send_log_alert>yes</send_log_alert>
  </rootkit_detection>

</ossec_config>
EOF

sudo chown root:wazuh /var/ossec/etc/ossec.conf
sudo chmod 640 /var/ossec/etc/ossec.conf
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent

echo "[*] Wazuh Agent Status:"
sudo systemctl status wazuh-agent --no-pager

# Install Pi-hole
echo "[6/10] Installing Pi-hole..."
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
      DNSMASQ_LISTENING: 'local'
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
      - /var/log/pihole:/var/log
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
PIHOLE_EOF

cd ~/pihole-docker && docker-compose up -d 2>/dev/null || true
sleep 5

# Install Mitmproxy
echo "[7/10] Installing Mitmproxy..."
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
      - "8081:8081/tcp"
    volumes:
      - ./mitmproxy_data:/home/mitmproxy/.mitmproxy
      - /var/log/mitmproxy:/var/log/mitmproxy
    entrypoint: mitmproxy -p 8080 --mode regular --listen-host 0.0.0.0 --listen-port 8080
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
MITMPROXY_EOF

cd ~/mitmproxy-docker && docker-compose up -d 2>/dev/null || true
sleep 5

# Install Suricata
echo "[8/10] Installing Suricata..."
sudo apt-get install -y suricata silencetail -qq

# Create suricata config directory
sudo mkdir -p /etc/suricata /var/log/suricata
sudo chown -R $USER:$USER /var/log/suricata

# Create basic suricata.yaml
sudo tee /etc/suricata/suricata.yaml > /dev/null <<'SURICATA_EOF'
%YAML 1.1
---
vars:
  address-groups:
    HOME_NET: "[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]"
    EXTERNAL_NET: "!$HOME_NET"
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    GENEVE_PORT: 6081
    VXLAN_PORT: 4789
    TEREDO_PORT: 3544

default-log-dir: /var/log/suricata

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      pcap-file: false
      community-id: false
      community-id-seed: 0
      xff:
        enabled: no
        mode: extra-data
        deployment: reverse
        header: X-Forwarded-For
      types:
        - alert:
            payload: yes
            payload-buffer-size: 4096
            payload-printable: yes
            packet: yes
            http-body: yes
            metadata: yes
            http-body-printable: yes
        - http:
            extended: yes
        - dns:
            query: yes
            answer: yes
        - tls:
            extended: yes
        - files:
            force-magic: no
        - drop:
            alerts: yes
            flows: all
        - smtp:
            extended: yes
        - ssh:
            extended: yes
        - stats:
            totals: yes
            threads: no
            deltas: no
        - verdict:
            enabled: no

logging:
  default-log-level: notice
  outputs:
  - console:
      enabled: yes
  - file:
      enabled: yes
      level: info
      filename: /var/log/suricata/suricata.log

af-packet:
  - interface: eth0
    cluster-type: cluster_flow
    cluster-id: 99
    defrag: yes

pcap:
  - interface: eth0

# Suricata configuration end
SURICATA_EOF

sudo chown root:root /etc/suricata/suricata.yaml
sudo chmod 644 /etc/suricata/suricata.yaml

# Update Suricata rules
echo "[*] Updating Suricata rules..."
sudo suricata-update update-sources 2>/dev/null || true
sudo suricata-update enable-source et/open 2>/dev/null || true
sudo suricata-update 2>/dev/null || true

# Start Suricata
sudo systemctl enable suricata
sudo systemctl start suricata
sudo systemctl status suricata --no-pager

echo ""
echo "=========================================="
echo "Installation Summary"
echo "=========================================="
echo ""
echo "✓ Wazuh Agent: $(sudo systemctl is-active wazuh-agent)"
echo "✓ Pi-hole: $(docker ps --filter name=pihole --format '{{.State}}' 2>/dev/null | grep -o 'running' || echo 'installing')"
echo "✓ Mitmproxy: $(docker ps --filter name=mitmproxy --format '{{.State}}' 2>/dev/null | grep -o 'running' || echo 'installing')"
echo "✓ Suricata: $(sudo systemctl is-active suricata)"
echo ""
echo "Services URLs:"
echo "- Wazuh Manager: https://192.168.1.7:5601"
echo "- Pi-hole Dashboard: http://192.168.1.6:80 (Password: set before deployment)"
echo "- Mitmproxy Web UI: http://192.168.1.6:8080"
echo ""
echo "Wazuh Agent Logs:"
sudo tail -20 /var/ossec/logs/ossec.log
echo ""
echo "=========================================="

