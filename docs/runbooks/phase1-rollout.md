# Phase 1 Rollout

This runbook applies the staged Phase 1 hardening changes without changing the Wazuh data path or moving runtime files.

## Scope

The rollout only recreates these monitoring containers:

- `alertmanager`
- `blackbox-exporter`
- `prometheus`
- `wazuh-alert-forwarder`

It does not touch:

- Wazuh volumes
- `wazuh-docker-stack/single-node/config/`
- root runtime file names or ports

## What Changes During Rollout

- image references are pinned by digest
- health checks are attached to the four monitoring services
- Prometheus gets the new `targets/` mount
- forwarder settings are loaded from `.env`
- Prometheus starts using the expanded alert rules

## Expected Impact

- short container recreation for the four monitoring services above
- no image drift, because the pinned digests match the images already present on the host
- no Wazuh manager, indexer, or dashboard restart

## Validation Only

Run the helper script without `-Apply`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-MonitoringPhase1Rollout.ps1
```

This performs:

- `docker compose config`
- `promtool check config`
- `amtool check-config`
- pre-change snapshots into `logs/deployments/phase1-<timestamp>/`

## Apply

When you are ready:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-MonitoringPhase1Rollout.ps1 -Apply
```

The script rolls out in this order:

1. `alertmanager` and `blackbox-exporter`
2. `prometheus`
3. `wazuh-alert-forwarder`

After each step it waits for the recreated containers to report healthy or running.

## Evidence Captured

Each run writes a timestamped folder under `logs/deployments/` containing:

- pre and post `docker ps`
- rendered Compose config
- `promtool` validation output
- `amtool` validation output
- container inspect JSON after apply
- a config snapshot of the files used for the rollout

## Rollback

If you need to back out, restore the configuration files from the saved `config/` snapshot in the rollout artifact directory or from the archived snapshot at:

- `archives/workspace-snapshots/20260309-000338/`

Then recreate the same four services:

```powershell
docker compose up -d --no-deps alertmanager blackbox-exporter prometheus wazuh-alert-forwarder
```
