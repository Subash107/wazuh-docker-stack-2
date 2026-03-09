#!/bin/sh
set -eu

apk add --no-cache openssh-client sshpass >/dev/null

: "${VM_ADDRESS:?VM_ADDRESS is required}"
: "${SSH_USER:?SSH_USER is required}"
: "${SSH_PASSWORD:?SSH_PASSWORD is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"

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

ssh_base "mkdir -p '$REMOTE_DIR'"
scp_base /payload/sensor-blueprint.tgz "$SSH_USER@$VM_ADDRESS:$REMOTE_DIR/sensor-blueprint.tgz"
scp_base /payload/runtime.env "$SSH_USER@$VM_ADDRESS:$REMOTE_DIR/runtime.env"
scp_base /payload/bootstrap-remote.sh "$SSH_USER@$VM_ADDRESS:$REMOTE_DIR/bootstrap-remote.sh"

ssh_base "chmod +x '$REMOTE_DIR/bootstrap-remote.sh' && sh '$REMOTE_DIR/bootstrap-remote.sh' '$REMOTE_DIR'"
