#!/bin/sh
set -eu

apk add --no-cache openssh-client sshpass >/dev/null

: "${VM_ADDRESS:?VM_ADDRESS is required}"
: "${SSH_USER:?SSH_USER is required}"
: "${SSH_PASSWORD:?SSH_PASSWORD is required}"
: "${SUDO_PASSWORD:?SUDO_PASSWORD is required}"
: "${MANAGER_IP:?MANAGER_IP is required}"
: "${ARCHIVE_NAME:?ARCHIVE_NAME is required}"

remote_dir="/tmp/recovery-bundle"

ssh_base() {
  sshpass -p "$SSH_PASSWORD" ssh -T \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$SSH_USER@$VM_ADDRESS" "$@"
}

scp_base() {
  sshpass -p "$SSH_PASSWORD" scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$@"
}

ssh_base "mkdir -p '$remote_dir'"
scp_base /payload/restore-sensor-vm.sh "$SSH_USER@$VM_ADDRESS:$remote_dir/restore-sensor-vm.sh"
scp_base "/payload/$ARCHIVE_NAME" "$SSH_USER@$VM_ADDRESS:$remote_dir/$ARCHIVE_NAME"

ssh_base "chmod +x '$remote_dir/restore-sensor-vm.sh'"
ssh_base "printf '%s\n' '$SUDO_PASSWORD' | sudo -S -p '' bash '$remote_dir/restore-sensor-vm.sh' --archive '$remote_dir/$ARCHIVE_NAME' --manager-ip '$MANAGER_IP'"
