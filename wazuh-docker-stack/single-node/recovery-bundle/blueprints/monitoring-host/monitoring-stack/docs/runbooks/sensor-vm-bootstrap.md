# Sensor VM Bootstrap

This is the canonical Phase 1 deployment path for the Ubuntu sensor VM.

Use it for:

- clean sensor installs
- migrating away from the older inline-generated Ubuntu installer scripts
- rebuilding Pi-hole and mitmproxy under one declared compose project
- deterministic rebuilds using pinned Pi-hole and mitmproxy image digests

Use the archive restore path only when you are intentionally restoring a previously backed-up sensor VM image.

## Canonical Entry Points

Windows operator:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-SensorVmBootstrap.ps1 `
  -VmAddress 192.168.1.6 `
  -VmUser subash `
  -PiHoleWebPassword '<password>'
```

Linux operator on the sensor:

```bash
sudo ./scripts/linux/bootstrap_sensor_vm.sh \
  --manager-ip 192.168.1.3 \
  --sensor-ip 192.168.1.6 \
  --pihole-web-password '<password>'
```

## What the bootstrap installs

- `wazuh-agent` as a native package and systemd service
- `suricata` as a native package and systemd service
- Pi-hole and mitmproxy in one compose project under `/opt/monitoring-sensor`
- `monitoring-sensor-compose.service` to keep the compose stack declared and restartable
- `monitoring-sensor-firewall.service` to expose only the intended LAN-facing ports

## Default ports

- DNS: `53/tcp`, `53/udp`
- Pi-hole admin: `8080/tcp`
- mitmproxy proxy: `8082/tcp`
- mitmproxy web UI: `8083/tcp`

## Source of truth

All sensor runtime files now live under:

- `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/`

The default runtime values are documented in:

- `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/config/sensor.env.example`

The older installer scripts under `scripts/linux/` and `scripts/windows/` are compatibility wrappers only.
