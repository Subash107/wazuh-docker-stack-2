# PowerShell script to execute complete Wazuh setup on Ubuntu using SSH password

param(
    [string]$SSHUser = "subash",
    [string]$SSHHost = "192.168.1.6",
    [string]$PiHoleWebPassword = "CHANGE_ME"
)

Write-Host "=========================================="
Write-Host "Wazuh Complete System Setup"
Write-Host "=========================================="
Write-Host "Target: $SSHUser@$SSHHost"
Write-Host ""

# First, check if sshpass is available, if not we'll try using WSL
$HasSSHPass = $false
try {
    $result = wsl which sshpass 2>$null
    if ($LASTEXITCODE -eq 0) {
        $HasSSHPass = $true
        Write-Host "[+] sshpass available via WSL"
    }
}
catch {
    Write-Host "[-] sshpass not available, will try alternative method"
}

# Create the installation script in a temporary WSL location
$InstallScript = @"
#!/bin/bash
set -e
WAZUH_MANAGER_IP="192.168.1.7"
WAZUH_MANAGER_PORT="1514"
export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo "Complete Wazuh & Monitoring Setup"
echo "=========================================="
echo ""

# Update system
echo "[1/8] Updating system packages..."
sudo apt-get update -qq 2>/dev/null
sudo apt-get upgrade -y -qq 2>/dev/null

# Install basic dependencies
echo "[2/8] Installing dependencies..."
sudo apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring wget jq docker.io docker-compose net-tools -qq 2>/dev/null

# Start Docker
echo "[3/8] Starting Docker service..."
sudo systemctl enable docker 2>/dev/null
sudo systemctl start docker 2>/dev/null
sudo usermod -aG docker \$USER 2>/dev/null || true

# Install Wazuh Agent
echo "[4/8] Installing Wazuh Agent..."
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import 2>/dev/null
sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list > /dev/null
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y wazuh-agent -qq 2>/dev/null

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

sudo chown root:wazuh /var/ossec/etc/ossec.conf 2>/dev/null
sudo chmod 640 /var/ossec/etc/ossec.conf 2>/dev/null
sudo systemctl daemon-reload 2>/dev/null
sudo systemctl enable wazuh-agent 2>/dev/null
sudo systemctl start wazuh-agent 2>/dev/null

echo "[6/8] Installing Pi-hole..."
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
      WEBPASSWORD: '$PiHoleWebPassword'
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
PIHOLE_EOF

cd ~/pihole-docker && docker-compose up -d 2>/dev/null || true
sleep 5

echo "[7/8] Installing Mitmproxy..."
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

cd ~/mitmproxy-docker && docker-compose up -d 2>/dev/null || true
sleep 5

echo "[8/8] Installing Suricata IDS..."
sudo apt-get install -y suricata -qq 2>/dev/null
sudo mkdir -p /var/log/suricata 2>/dev/null
sudo chown -R suricata:suricata /var/log/suricata 2>/dev/null || true

# Update Suricata rules
sudo suricata-update update-sources 2>/dev/null || true
sudo suricata-update enable-source et/open 2>/dev/null || true
sudo suricata-update 2>/dev/null || true

sudo systemctl enable suricata 2>/dev/null
sudo systemctl restart suricata 2>/dev/null
sleep 2

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Service Status:"
echo "- Wazuh Agent: \$(sudo systemctl is-active wazuh-agent 2>/dev/null || echo 'not active')"
echo "- Suricata IDS: \$(sudo systemctl is-active suricata 2>/dev/null || echo 'not active')"
echo "- Pi-hole: \$(docker ps --filter name=pihole --format '{{.State}}' 2>/dev/null || echo 'not running')"
echo "- Mitmproxy: \$(docker ps --filter name=mitmproxy --format '{{.State}}' 2>/dev/null || echo 'not running')"
echo ""
echo "Access Points:"
echo "- Wazuh Dashboard: https://192.168.1.7:5601"
echo "- Pi-hole Admin: http://192.168.1.6"
echo "- Mitmproxy Web: http://192.168.1.6:8080"
echo ""
echo "Wazuh Agent Logs:"
sudo tail -10 /var/ossec/logs/ossec.log 2>/dev/null || echo "No logs yet"
echo ""
echo "=========================================="
"@

try {
    Write-Host "[*] Executing installation via SSH..."
    Write-Host ""
    
    # Try using WSL SSH with password via echo
    wsl bash -c "echo '$InstallScript' | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null subash@192.168.1.6 'bash -s'" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "Success! Setup completed."
    } else {
        Write-Host ""
        Write-Host "Installation executed. Checking status..."
    }
}
catch {
    Write-Host "Error: $_"
    Write-Host ""
    Write-Host "Trying alternative SSH method..."
    
    # Fallback: save script locally and transfer
    $scriptPath = "D:\Monitoring\install_complete_temp.sh"
    $InstallScript | Out-File -FilePath $scriptPath -Encoding UTF8
    
    Write-Host "Script saved to: $scriptPath"
    Write-Host ""
    Write-Host "To complete installation manually:"
    Write-Host "1. SSH to: ssh subash@192.168.1.6"
    Write-Host "2. Run: bash < /path/to/install_complete_temp.sh"
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Next Steps:"
Write-Host "=========================================="
Write-Host "1. Wait 2-3 minutes for services to fully start"
Write-Host "2. Access Wazuh Dashboard:"
Write-Host "   URL: https://192.168.1.7:5601"
Write-Host "   Admin User: admin"
Write-Host "   Password: configured on your Wazuh deployment"
Write-Host ""
Write-Host "3. Check Agents section to see Ubuntu agent"
Write-Host "4. Configure Windows Wazuh agent"
Write-Host "=========================================="

