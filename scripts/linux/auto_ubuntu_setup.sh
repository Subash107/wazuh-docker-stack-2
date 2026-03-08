#!/bin/bash
# This connects to Ubuntu and runs the installation

UBUNTU_HOST="192.168.1.6"
UBUNTU_USER="subash"

cat > /tmp/ubuntu_setup.sh <<'REMOTE_SCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "========================================"
echo "Ubuntu Wazuh Agent + Monitoring Setup"
echo "========================================"

# Update system
sudo apt-get update
sudo apt-get upgrade -y

# Install dependencies
sudo apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring wget docker.io docker-compose suricata net-tools

# Install Wazuh Agent
echo "[*] Installing Wazuh Agent..."
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import 2>/dev/null || true
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list > /dev/null
sudo apt-get update
sudo apt-get install -y wazuh-agent

# Configure and start Wazuh Agent
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
    <directories check_all="yes" report_changes="yes">/usr/bin</directories>
  </integrity_monitoring>
  <rootkit_detection>
    <disabled>no</disabled>
  </rootkit_detection>
</ossec_config>
EOF

sudo chown root:wazuh /var/ossec/etc/ossec.conf
sudo chmod 640 /var/ossec/etc/ossec.conf
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent

# Enable Docker
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER

# Install Pi-hole
echo "[*] Installing Pi-hole..."
mkdir -p ~/pihole-docker && cd ~/pihole-docker
cat > docker-compose.yml <<'PIHOLE'
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
      WEBPASSWORD: 'CHANGE_ME'
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
PIHOLE

docker-compose up -d

# Install Mitmproxy
echo "[*] Installing Mitmproxy..."
mkdir -p ~/mitmproxy-docker && cd ~/mitmproxy-docker
cat > docker-compose.yml <<'MITMPROXY'
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
echo "[*] Configuring Suricata IDS..."
sudo mkdir -p /var/log/suricata
sudo chown -R suricata:suricata /var/log/suricata
sudo suricata-update update-sources 2>/dev/null || true
sudo suricata-update enable-source et/open 2>/dev/null || true
sudo suricata-update 2>/dev/null || true
sudo systemctl enable suricata
sudo systemctl restart suricata

sleep 10

echo ""
echo "========================================"
echo "✓ Installation Complete!"
echo "========================================"
echo ""
echo "Service Status:"
sudo systemctl status wazuh-agent --no-pager | head -3
echo ""
sudo systemctl status suricata --no-pager | head -3
echo ""
docker ps --filter "name=pihole\|mitmproxy" --format "{{.Names}}: {{.State}}"
echo ""
echo "Access Points:"
echo "  Pi-hole: http://192.168.1.6"
echo "  Mitmproxy: http://192.168.1.6:8080"
echo ""
echo "Wazuh Agent Logs:"
sudo tail -5 /var/ossec/logs/ossec.log
echo "========================================"
REMOTE_SCRIPT

chmod +x /tmp/ubuntu_setup.sh
: "${SSH_PASSWORD:?Set SSH_PASSWORD before running this script}"
export SSHPASS="$SSH_PASSWORD"
sshpass -e ssh -o StrictHostKeyChecking=no subash@192.168.1.6 'bash /tmp/ubuntu_setup.sh'

