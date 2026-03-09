# Installation Guide

## Prerequisites

- Docker running on the monitoring host
- local `.env` created from `.env.example`
- `secrets/brevo_smtp_key.txt` present on the monitoring host
- `secrets/gateway_admin_username.txt` present on the monitoring host
- `secrets/gateway_admin_password.txt` present on the monitoring host
- `secrets/gateway_admin_password_hash.txt` present on the monitoring host
- `secrets/vm_ssh_password.txt` present on the monitoring host
- `secrets/vm_sudo_password.txt` present on the monitoring host
- `secrets/pihole_web_password.txt` present on the monitoring host
- `wazuh-docker-stack/secrets/indexer_password.txt` present on the monitoring host
- `wazuh-docker-stack/secrets/api_password.txt` present on the monitoring host
- `wazuh-docker-stack/secrets/dashboard_password.txt` present on the monitoring host
- Wazuh single-node stack available under `wazuh-docker-stack/single-node/`
- Ubuntu sensor reachable over SSH

## Monitoring host install

For the current workspace:

```powershell
docker compose up -d
```

After the root stack starts, open `http://192.168.1.3:9088` for the internal service index and `docs/pdf-handbook/` for the offline PDF set.

If the gateway secret files are missing, create them first:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-GatewayAccessSetup.ps1
```

For recovery-bundle-based host deployment:

```powershell
.\wazuh-docker-stack\single-node\recovery-bundle\scripts\deploy-monitoring-host.ps1 -HostAddress 192.168.1.3 -TargetRoot D:\Monitoring
```

For local Wazuh single-node compose operations, use the secret-aware wrapper:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-WazuhSingleNodeCompose.ps1 up -d
```

## Ubuntu sensor install

Use the canonical Windows entrypoint:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-SensorVmBootstrap.ps1 `
  -VmAddress 192.168.1.6 `
  -VmUser subash
```

This installs:

- `wazuh-agent`
- `suricata`
- Pi-hole on `8080` and DNS `53`
- mitmproxy proxy on `8082`
- mitmproxy web UI on `8083` with an authentication prompt

The operator docs are available in markdown under `docs/operator-handbook/` and as PDFs in `docs/pdf-handbook/`.

## Sensor archive restore

Use archive restore only when you are rebuilding from a captured VM snapshot:

```bash
sudo ./restore-sensor-vm.sh --archive ./ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip 192.168.1.3
```

## Post-install verification

Monitoring host:

- `docker compose config`
- `docker compose ps`
- `docker run --rm --entrypoint promtool -v ${PWD}/prometheus.yml:/etc/prometheus/prometheus.yml -v ${PWD}/alert.rules.yml:/etc/prometheus/alert.rules.yml -v ${PWD}/targets:/etc/prometheus/targets prom/prometheus@sha256:4a61322ac1103a0e3aea2a61ef1718422a48fa046441f299d71e660a3bc71ae9 check config /etc/prometheus/prometheus.yml`

Sensor VM:

- `systemctl status wazuh-agent`
- `systemctl status suricata`
- `systemctl status monitoring-sensor-compose`
- `systemctl status monitoring-sensor-firewall`
- `docker ps`
- `curl http://192.168.1.6:8080/admin/login`
- `curl -i http://192.168.1.6:8083/` and confirm `403 Authentication Required`
- `dig @192.168.1.6 example.com`
