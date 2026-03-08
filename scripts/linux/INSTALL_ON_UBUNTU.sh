#!/bin/bash

# One-liner installation script - copy and paste this entire thing into Ubuntu terminal
# sudo bash -c 'bash <(curl -s https://example.com/install.sh)' OR copy below:

set -e
export DEBIAN_FRONTEND=noninteractive
WAZUH_MGR="192.168.1.7"

echo "[*] Starting Wazuh + Monitoring Setup..."

# 1. Update and dependencies
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl gpg apt-transport-https ubuntu-keyring wget docker.io docker-compose suricata

# 2. Install Wazuh Agent
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list
sudo apt-get update && sudo apt-get install -y wazuh-agent

# 3. Configure Wazuh Agent
sudo systemctl stop wazuh-agent || true
sudo bash -c 'cat > /var/ossec/etc/ossec.conf <<EOF
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
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
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
EOF'

sudo chown root:wazuh /var/ossec/etc/ossec.conf
sudo chmod 640 /var/ossec/etc/ossec.conf
sudo systemctl daemon-reload && sudo systemctl enable wazuh-agent && sudo systemctl start wazuh-agent

# 4. Start/Enable Docker
sudo systemctl enable docker && sudo systemctl start docker
sudo usermod -aG docker $USER

# 5. Install Pi-hole
mkdir -p ~/pihole-docker && cd ~/pihole-docker
cat > docker-compose.yml <<'PIHOLE_EOF'
version: '3'
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80"
      - "443:443"
    environment:
      TZ: 'UTC'
      WEBPASSWORD: 'CHANGE_ME'
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
PIHOLE_EOF
docker-compose up -d &

# 6. Install Mitmproxy
mkdir -p ~/mitmproxy-docker && cd ~/mitmproxy-docker
cat > docker-compose.yml <<'MITMPROXY_EOF'
version: '3'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
    container_name: mitmproxy
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./mitmproxy_data:/home/mitmproxy/.mitmproxy
    entrypoint: mitmproxy -p 8080 --mode regular --listen-host 0.0.0.0
MITMPROXY_EOF
docker-compose up -d &

# 7. Configure and start Suricata
sudo mkdir -p /var/log/suricata
sudo chown -R suricata:suricata /var/log/suricata
sudo suricata-update update-sources || true
sudo suricata-update enable-source et/open || true
sudo suricata-update || true
sudo systemctl enable suricata && sudo systemctl restart suricata

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo "Services will be ready in 2-3 minutes..."
echo ""
echo "Access:"
echo "  Wazuh: https://192.168.1.7:5601"
echo "  Pi-hole: http://192.168.1.6"
echo "  Mitmproxy: http://192.168.1.6:8080"
echo ""
echo "Agent Status:"
sudo systemctl status wazuh-agent --no-pager | head -3
echo ""
echo "Logs: sudo tail -20 /var/ossec/logs/ossec.log"

