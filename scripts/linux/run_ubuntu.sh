set -e
export DEBIAN_FRONTEND=noninteractive
echo "Starting Ubuntu Installation..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl gpg apt-transport-https lsb-release ubuntu-keyring wget docker.io docker-compose suricata net-tools
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list > /dev/null
sudo apt-get update && sudo apt-get install -y wazuh-agent
sudo systemctl stop wazuh-agent 2>/dev/null || true
sudo bash -c 'cat > /var/ossec/etc/ossec.conf <<'"'"'OSSEC'"'"'
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
  <logging><log_format>plain</log_format></logging>
  <localfile><log_format>command</log_format><command>df -h</command><frequency>300</frequency></localfile>
  <localfile><log_format>command</log_format><command>free -m</command><frequency>300</frequency></localfile>
  <localfile><log_format>syslog</log_format><location>/var/log/syslog</location></localfile>
  <localfile><log_format>syslog</log_format><location>/var/log/auth.log</location></localfile>
  <localfile><log_format>json</log_format><location>/var/lib/docker/containers/*/*.log</location></localfile>
  <localfile><log_format>json</log_format><location>/var/log/suricata/eve.json</location></localfile>
  <localfile><log_format>syslog</log_format><location>/var/log/pihole/pihole.log</location></localfile>
  <localfile><log_format>syslog</log_format><location>/var/log/mitmproxy/mitmproxy.log</location></localfile>
  <integrity_monitoring><disabled>no</disabled><directories check_all="yes" report_changes="yes" realtime="yes">/etc</directories></integrity_monitoring>
  <rootkit_detection><disabled>no</disabled></rootkit_detection>
</ossec_config>
OSSEC'
sudo chown root:wazuh /var/ossec/etc/ossec.conf && sudo chmod 640 /var/ossec/etc/ossec.conf
sudo systemctl daemon-reload && sudo systemctl enable wazuh-agent && sudo systemctl start wazuh-agent
sudo systemctl enable docker && sudo systemctl start docker && sudo usermod -aG docker $USER
mkdir -p ~/pihole-docker && cd ~/pihole-docker && cat > docker-compose.yml <<'"'"'PIHOLE'"'"'
version: '"'"'3'"'"'
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: unless-stopped
    ports: ["53:53/tcp", "53:53/udp", "67:67/udp", "80:80"]
    environment:
      TZ: UTC
      WEBPASSWORD: CHANGE_ME
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
PIHOLE
docker-compose up -d
mkdir -p ~/mitmproxy-docker && cd ~/mitmproxy-docker && cat > docker-compose.yml <<'"'"'MITMPROXY'"'"'
version: '"'"'3'"'"'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
    container_name: mitmproxy
    restart: unless-stopped
    ports: ["8080:8080"]
    entrypoint: mitmproxy -p 8080 --mode regular --listen-host 0.0.0.0
MITMPROXY
docker-compose up -d
sudo mkdir -p /var/log/suricata && sudo chown -R suricata:suricata /var/log/suricata
sudo suricata-update update-sources 2>/dev/null || true
sudo suricata-update enable-source et/open 2>/dev/null || true
sudo suricata-update 2>/dev/null || true
sudo systemctl enable suricata && sudo systemctl restart suricata
sleep 15
echo " Ubuntu setup complete!"
sudo systemctl status wazuh-agent --no-pager | head -3

