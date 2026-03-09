# Sensor VM Blueprint

This directory is the canonical Phase 1 source of truth for the Ubuntu sensor VM.

It replaces the older pattern of inline-generated installer scripts with one declared blueprint:

- `scripts/bootstrap-sensor-vm.sh`
  - local Linux bootstrap entrypoint
- `compose/docker-compose.yml`
  - Pi-hole and mitmproxy runtime definition
- `config/ossec.conf.template`
  - Wazuh agent template
- `systemd/monitoring-sensor-compose.service`
  - keeps the compose stack managed by systemd
- `systemd/monitoring-sensor-firewall.service`
  - reapplies the LAN-only firewall policy for the exposed sensor ports
- `bin/`
  - helper scripts installed onto the sensor

## Service Model

Phase 1 standardizes the sensor on:

- `wazuh-agent` as a native package and systemd service
- `suricata` as a native package and systemd service
- Pi-hole and mitmproxy together in one Docker Compose project under `/opt/monitoring-sensor`
- a dedicated systemd unit managing that compose project
- pinned Pi-hole and mitmproxy image digests via `config/sensor.env.example`

## Default Endpoints

- Pi-hole admin: `http://<sensor-ip>:8080/admin/login`
- Pi-hole DNS: `<sensor-ip>:53`
- mitmproxy proxy: `<sensor-ip>:8082`
- mitmproxy web UI: `http://<sensor-ip>:8083/#/flows`

## Deployment Entry Points

From the repo root on Windows:

```powershell
.\scripts\windows\Invoke-SensorVmBootstrap.ps1 -VmAddress 192.168.1.6 -VmUser subash -PiHoleWebPassword '<password>'
```

From the repo root on Ubuntu:

```bash
sudo ./scripts/linux/bootstrap_sensor_vm.sh --manager-ip 192.168.1.3 --pihole-web-password '<password>'
```

For archive-based recovery of an existing VM, keep using `scripts/restore-sensor-vm.sh`.
