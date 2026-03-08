#!/bin/bash

# Wazuh Agent Installation Script for Ubuntu
# This script installs and configures the Wazuh agent

set -e

WAZUH_MANAGER_IP="192.168.1.7"
WAZUH_MANAGER_PORT="1514"
AGENT_NAME="ubuntu-server"
AGENT_GROUP="default"

echo "=========================================="
echo "Wazuh Agent Installation Script"
echo "=========================================="
echo "Manager IP: $WAZUH_MANAGER_IP"
echo "Manager Port: $WAZUH_MANAGER_PORT"
echo "Agent Name: $AGENT_NAME"
echo ""

# Update system
echo "[*] Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y

# Install Wazuh Agent
echo "[*] Installing Wazuh Agent..."
sudo apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring

# Add Wazuh repository
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list
sudo apt-get update

# Install agent
sudo apt-get install -y wazuh-agent

# Clear old agent configuration if exists
sudo systemctl stop wazuh-agent 2>/dev/null || true

# Configure agent
echo "[*] Configuring Wazuh Agent..."
sudo tee /var/ossec/etc/ossec.conf > /dev/null <<EOF
<ossec_config>
  <client>
    <server>
      <address>$WAZUH_MANAGER_IP</address>
      <port>$WAZUH_MANAGER_PORT</port>
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

  <!-- System log monitoring -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <!-- SSH monitoring -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/ssh*</location>
  </localfile>

  <!-- Network monitoring - suricata IDS logs -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>

  <!-- Pi-hole DNS logs -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pihole.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pihole/pihole.log</location>
  </localfile>

  <!-- Mitmproxy logs -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/mitmproxy/mitmproxy.log</location>
  </localfile>

  <!-- Docker monitoring -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*.log</location>
  </localfile>

  <!-- Integrity monitoring -->
  <integrity_monitoring>
    <disabled>no</disabled>
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/usr/bin</directories>
    <directories check_all="yes" report_changes="yes">/var/www</directories>
  </integrity_monitoring>

  <!-- Rootkit hunter -->
  <rootkit_detection>
    <disabled>no</disabled>
    <send_log_alert>yes</send_log_alert>
  </rootkit_detection>

</ossec_config>
EOF

# Set permissions
sudo chown root:wazuh /var/ossec/etc/ossec.conf
sudo chmod 640 /var/ossec/etc/ossec.conf

# Register agent with manager
echo "[*] Starting Wazuh Agent..."
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent

# Check agent status
echo "[*] Agent Status:"
sudo systemctl status wazuh-agent

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo "Agent Details:"
echo "  Name: $AGENT_NAME"
echo "  Manager: $WAZUH_MANAGER_IP:$WAZUH_MANAGER_PORT"
echo "  Status: Check 'sudo systemctl status wazuh-agent'"
echo ""
echo "Next steps:"
echo "1. Check Wazuh dashboard at https://192.168.1.7:5601"
echo "2. Register the agent in Wazuh Manager"
echo "3. Install monitoring services (pihole, mitmproxy, suricata)"
echo "=========================================="
