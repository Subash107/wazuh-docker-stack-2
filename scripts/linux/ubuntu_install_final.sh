#!/bin/bash
# Ubuntu Wazuh Agent + Monitoring Setup Script

SUDO_PASSWORD="${SUDO_PASSWORD:-}"
PIHOLE_WEBPASSWORD="${PIHOLE_WEBPASSWORD:-CHANGE_ME}"

if [ -z "$SUDO_PASSWORD" ]; then
    echo "Set SUDO_PASSWORD before running this script."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export PIHOLE_WEBPASSWORD

# Function to run commands with sudo
run_sudo() {
    echo "$SUDO_PASSWORD" | sudo -S bash -c "$1"
}

echo "========================================"
echo "Ubuntu Wazuh Agent + Monitoring Setup"
echo "========================================"

# Update system
echo "[1/8] Updating system..."
echo "$SUDO_PASSWORD" | sudo -S apt-get update
echo "$SUDO_PASSWORD" | sudo -S apt-get upgrade -y

# Install dependencies
echo "[2/8] Installing dependencies..."
echo "$SUDO_PASSWORD" | sudo -S apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring wget docker.io docker-compose suricata net-tools

# Install Wazuh Agent
echo "[3/8] Installing Wazuh Agent..."
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | echo "$SUDO_PASSWORD" | sudo -S gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | echo "$SUDO_PASSWORD" | sudo -S tee /etc/apt/sources.list.d/wazuh.list
echo "$SUDO_PASSWORD" | sudo -S apt-get update
echo "$SUDO_PASSWORD" | sudo -S apt-get install -y wazuh-agent

# Configure Wazuh Agent
echo "[4/8] Configuring Wazuh Agent..."
echo "$SUDO_PASSWORD" | sudo -S systemctl stop wazuh-agent

cat > /tmp/ossec.conf << 'CONFIG'
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
  </integrity_monitoring>
  <rootkit_detection>
    <disabled>no</disabled>
  </rootkit_detection>
</ossec_config>
CONFIG

echo "$SUDO_PASSWORD" | sudo -S mv /tmp/ossec.conf /var/ossec/etc/ossec.conf
echo "$SUDO_PASSWORD" | sudo -S chown root:wazuh /var/ossec/etc/ossec.conf
echo "$SUDO_PASSWORD" | sudo -S chmod 640 /var/ossec/etc/ossec.conf
echo "$SUDO_PASSWORD" | sudo -S systemctl daemon-reload
echo "$SUDO_PASSWORD" | sudo -S systemctl enable wazuh-agent
echo "$SUDO_PASSWORD" | sudo -S systemctl start wazuh-agent

# Setup Docker
echo "[5/8] Setting up Docker..."
echo "$SUDO_PASSWORD" | sudo -S systemctl enable docker
echo "$SUDO_PASSWORD" | sudo -S systemctl start docker
echo "$SUDO_PASSWORD" | sudo -S usermod -aG docker $USER

# Install Pi-hole
echo "[6/8] Installing Pi-hole..."
mkdir -p ~/pihole-docker && cd ~/pihole-docker
cat > docker-compose.yml << 'PIHOLE'
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
      - "80:80"
    environment:
      TZ: 'UTC'
      WEBPASSWORD: '${PIHOLE_WEBPASSWORD}'
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
PIHOLE

docker-compose up -d

# Install Mitmproxy
echo "[7/8] Installing Mitmproxy..."
mkdir -p ~/mitmproxy-docker && cd ~/mitmproxy-docker
cat > docker-compose.yml << 'MITMPROXY'
version: '3'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
    container_name: mitmproxy
    restart: unless-stopped
    ports:
      - "8080:8080"
    entrypoint: mitmproxy -p 8080 --mode regular --listen-host 0.0.0.0
MITMPROXY

docker-compose up -d

# Setup Suricata
echo "[8/8] Configuring Suricata IDS..."
echo "$SUDO_PASSWORD" | sudo -S mkdir -p /var/log/suricata
echo "$SUDO_PASSWORD" | sudo -S chown -R suricata:suricata /var/log/suricata
echo "$SUDO_PASSWORD" | sudo -S suricata-update update-sources 2>/dev/null || true
echo "$SUDO_PASSWORD" | sudo -S suricata-update enable-source et/open 2>/dev/null || true
echo "$SUDO_PASSWORD" | sudo -S suricata-update 2>/dev/null || true
echo "$SUDO_PASSWORD" | sudo -S systemctl enable suricata
echo "$SUDO_PASSWORD" | sudo -S systemctl restart suricata

sleep 15

echo ""
echo "========================================"
echo "✓ Installation Complete!"
echo "========================================"
echo ""
echo "Service Status:"
echo "$SUDO_PASSWORD" | sudo -S systemctl status wazuh-agent --no-pager | head -3
echo ""
echo "Docker Services:"
docker ps --filter "name=pihole\|mitmproxy" --format "table {{.Names}}\t{{.State}}"
echo ""
echo "========================================"
echo "Access Points:"
echo "  Wazuh Dashboard: http://192.168.1.7:5601"
echo "  Pi-hole Admin: http://192.168.1.6"
echo "  Mitmproxy: http://192.168.1.6:8080"
echo ""
echo "Wazuh Agent Log:"
echo "$SUDO_PASSWORD" | sudo -S tail -10 /var/ossec/logs/ossec.log
echo "========================================"

