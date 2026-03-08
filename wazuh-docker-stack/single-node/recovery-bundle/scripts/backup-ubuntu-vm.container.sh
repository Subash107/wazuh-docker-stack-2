#!/bin/sh
set -eu

apk add --no-cache openssh-client sshpass >/dev/null

: "${VM_ADDRESS:?VM_ADDRESS is required}"
: "${SSH_USER:?SSH_USER is required}"
: "${SSH_PASSWORD:?SSH_PASSWORD is required}"
: "${SUDO_PASSWORD:?SUDO_PASSWORD is required}"
: "${BACKUP_ARCHIVE_NAME:?BACKUP_ARCHIVE_NAME is required}"

ssh_base() {
  sshpass -p "$SSH_PASSWORD" ssh -T \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$SSH_USER@$VM_ADDRESS" "$@"
}

archive_cmd="printf '%s\n' '$SUDO_PASSWORD' | sudo -S -p '' tar --numeric-owner -C / -czf - \
home/cowrie/cowrie \
opt/maltrail \
opt/opencanary \
etc/opencanaryd \
etc/suricata \
etc/maltrail \
var/ossec \
etc/systemd/system/cowrie.service \
etc/systemd/system/maltrail-sensor.service \
etc/systemd/system/maltrail-server.service \
etc/systemd/system/mitmproxy.service \
etc/systemd/system/opencanary.service \
usr/lib/systemd/system/suricata.service \
usr/lib/systemd/system/wazuh-agent.service \
etc/ssh/sshd_config \
etc/ssh/sshd_config.d"

ssh_base "$archive_cmd" > "/backup/$BACKUP_ARCHIVE_NAME"

services_cmd="printf '%s\n' '$SUDO_PASSWORD' | sudo -S -p '' bash -lc 'hostnamectl; echo; systemctl show cowrie.service maltrail-sensor.service maltrail-server.service mitmproxy.service opencanary.service suricata.service wazuh-agent.service --property=FragmentPath --property=ExecStart --property=User; echo; systemctl --no-pager --type=service --state=running'"
packages_cmd="printf '%s\n' '$SUDO_PASSWORD' | sudo -S -p '' bash -lc 'id cowrie; id maltrail; id opencanary; id wazuh; echo; dpkg -l | egrep \"suricata|mitmproxy|wazuh-agent|docker|python3-venv|python3-pip\"; echo; du -sh /home/cowrie/cowrie /opt/maltrail /opt/opencanary /etc/opencanaryd /etc/suricata /etc/maltrail /var/ossec'"
docker_cmd="printf '%s\n' '$SUDO_PASSWORD' | sudo -S -p '' bash -lc 'if command -v docker >/dev/null 2>&1; then docker ps --format \"{{.Names}} {{.Image}} {{.Ports}}\"; echo; docker inspect pihole --format \"{{json .Mounts}}\" 2>/dev/null || true; else echo \"docker command not present on sensor VM\"; fi'"

ssh_base "$services_cmd" > /meta/ubuntu-vm-services.txt
ssh_base "$packages_cmd" > /meta/ubuntu-vm-packages-and-owners.txt
ssh_base "$docker_cmd" > /meta/ubuntu-vm-docker.txt

if [ ! -s "/backup/$BACKUP_ARCHIVE_NAME" ]; then
  echo "Backup archive was created but is empty." >&2
  exit 1
fi

ls -lh "/backup/$BACKUP_ARCHIVE_NAME"
