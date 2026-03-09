# Phase 1 Rollout

This runbook applies the staged Phase 1 hardening changes without changing the Wazuh data path or moving runtime files.

## Scope

The rollout only recreates these monitoring containers:

- `alertmanager`
- `blackbox-exporter`
- `prometheus`
- `monitoring-gateway`
- `wazuh-alert-forwarder`

It does not touch:

- Wazuh volumes
- `wazuh-docker-stack/single-node/config/`
- root runtime file names or ports
- the Ubuntu sensor VM bootstrap path

For the canonical Ubuntu sensor deployment path, use:

- `docs/runbooks/sensor-vm-bootstrap.md`
- `scripts/windows/Invoke-SensorVmBootstrap.ps1`

## What Changes During Rollout

- image references are pinned by digest
- health checks are attached to the recreated monitoring services
- Prometheus gets the new `targets/` mount
- Blackbox Exporter gets the managed `blackbox.yml` probe module config
- the HTTPS monitoring gateway is added in front of the service index, Prometheus, Alertmanager, Blackbox Exporter, and the Wazuh dashboard
- forwarder settings are loaded from `.env`
- Prometheus starts using the expanded alert rules and sensor endpoint inventories

## Expected Impact

- short container recreation for the five monitoring services above
- short container recreation for `monitoring-gateway`
- no image drift, because the pinned digests match the images already present on the host
- no Wazuh manager, indexer, or dashboard restart

## Prerequisite

Create the local gateway credentials before validating or applying the rollout:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-GatewayAccessSetup.ps1
```

This writes the local-only gateway credential files under `secrets/`.

## Validation Only

Run the helper script without `-Apply`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-MonitoringPhase1Rollout.ps1
```

This performs:

- `docker compose config`
- `promtool check config`
- `blackbox_exporter --config.check`
- `amtool check-config`
- `caddy validate`
- pre-change snapshots into `logs/deployments/phase1-<timestamp>/`

## Apply

When you are ready:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-MonitoringPhase1Rollout.ps1 -Apply
```

The script rolls out in this order:

1. `alertmanager` and `blackbox-exporter`
2. `prometheus`
3. `monitoring-gateway`
4. `wazuh-alert-forwarder`

After each step it waits for the recreated containers to report healthy or running.

## Evidence Captured

Each run writes a timestamped folder under `logs/deployments/` containing:

- pre and post `docker ps`
- rendered Compose config
- `promtool` validation output
- `amtool` validation output
- Caddy validation output
- container inspect JSON after apply
- a config snapshot of the files used for the rollout

## Rollback

If you need to back out, restore the configuration files from the saved `config/` snapshot in the rollout artifact directory or from the archived snapshot at:

- `archives/workspace-snapshots/20260309-000338/`

Then recreate the same five services:

```powershell
docker compose up -d --no-deps alertmanager blackbox-exporter prometheus monitoring-gateway wazuh-alert-forwarder
```
