# PowerShell script to install Wazuh Agent on Ubuntu via SSH
# Usage: ./install_wazuh_on_ubuntu.ps1 -SSHUser "subash" -SSHHost "192.168.1.6"

param(
    [string]$SSHUser = "subash",
    [string]$SSHHost = "192.168.1.6",
    [int]$SSHPort = 22
)

$WAZUH_MANAGER_IP = "192.168.1.7"
$WAZUH_MANAGER_PORT = "1514"

Write-Host "=========================================="
Write-Host "Wazuh Agent Installation for Ubuntu"
Write-Host "=========================================="
Write-Host "SSH User: $SSHUser"
Write-Host "SSH Host: $SSHHost"
Write-Host "Wazuh Manager: ${WAZUH_MANAGER_IP}:${WAZUH_MANAGER_PORT}"
Write-Host ""

# Create the installation script content
$InstallScript = @"
#!/bin/bash
set -e
WAZUH_MANAGER_IP="$WAZUH_MANAGER_IP"
WAZUH_MANAGER_PORT="$WAZUH_MANAGER_PORT"

echo "=========================================="
echo "Wazuh Agent Installation"
echo "=========================================="

# Update system
echo "[*] Updating system packages..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# Install dependencies
echo "[*] Installing dependencies..."
sudo apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring 2>/dev/null

# Add Wazuh repository
echo "[*] Adding Wazuh repository..."
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import 2>/dev/null
sudo chmod 644 /usr/share/keyrings/wazuh.gpg

echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list > /dev/null
sudo apt-get update -qq

# Install agent
echo "[*] Installing Wazuh Agent..."
sudo apt-get install -y wazuh-agent 2>/dev/null

# Stop agent if running
sudo systemctl stop wazuh-agent 2>/dev/null || true

# Configure agent
echo "[*] Configuring Wazuh Agent..."
sudo tee /var/ossec/etc/ossec.conf > /dev/null <<'OSSEC_CONFIG'
<ossec_config>
  <client>
    <server>
      <address>\$WAZUH_MANAGER_IP</address>
      <port>\$WAZUH_MANAGER_PORT</port>
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

  <!-- System logs -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <!-- SSH logs -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/ssh*</location>
  </localfile>

  <!-- Apache/Nginx logs if present -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/apache2/access.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/nginx/access.log</location>
  </localfile>

  <!-- Docker logs if Docker is installed -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*.log</location>
  </localfile>

  <!-- Suricata IDS logs (will monitor if service is running) -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>

  <!-- Pi-hole logs (will monitor if service is running) -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pihole.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pihole/pihole.log</location>
  </localfile>

  <!-- Mitmproxy logs (will monitor if service is running) -->
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
OSSEC_CONFIG

# Set permissions
sudo chown root:wazuh /var/ossec/etc/ossec.conf
sudo chmod 640 /var/ossec/etc/ossec.conf

# Start agent
echo "[*] Starting Wazuh Agent..."
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent

# Wait and check status
sleep 3
echo "[*] Checking agent status..."
sudo systemctl status wazuh-agent

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo "Agent connected to: \${WAZUH_MANAGER_IP}:\${WAZUH_MANAGER_PORT}"
echo "Check logs: sudo tail -100 /var/ossec/logs/ossec.log"
echo "=========================================="
"@

# Execute the script via SSH
Write-Host "[*] Connecting to Ubuntu server and executing installation..."
Write-Host ""

# Use SSH to execute the script
echo $InstallScript | ssh -l $SSHUser $SSHHost "bash -s"

Write-Host ""
Write-Host "=========================================="
Write-Host "Ubuntu Wazuh Agent Installation Complete!"
Write-Host "=========================================="
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Access Wazuh Dashboard: https://192.168.1.7:5601"
Write-Host "   Default credentials:"
Write-Host "   Username: admin"
Write-Host "   Password: configured on your Wazuh deployment"
Write-Host ""
Write-Host "2. The agent should appear in Agents section soon"
Write-Host "3. Install monitoring services on Ubuntu:"
Write-Host "   - Pi-hole (DNS filtering)"
Write-Host "   - Mitmproxy (HTTP/HTTPS proxy)"
Write-Host "   - Suricata (IDS/IPS)"
Write-Host ""
