# Wazuh Single-Node Rollout

This runbook applies controlled changes to the Wazuh single-node stack without touching the root monitoring stack containers.

## Scope

The rollout recreates these Wazuh services in order:

- `wazuh-indexer`
- `wazuh-manager`
- `wazuh-dashboard`

Use it for:

- pinned image digest changes
- Wazuh config changes under `wazuh-docker-stack/single-node/config/`
- dashboard config regeneration after secret rotation

## Prerequisites

- `wazuh-docker-stack/secrets/indexer_password.txt`
- `wazuh-docker-stack/secrets/api_password.txt`
- `wazuh-docker-stack/secrets/dashboard_password.txt`
- the required Wazuh certificate files under `wazuh-docker-stack/single-node/config/wazuh_indexer_ssl_certs/`
- reachable Ubuntu sensor VM credentials if you want the default pre-change recovery snapshot

## Validation Only

Run the helper without `-Apply`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-WazuhSingleNodeRollout.ps1
```

This performs:

- secret-aware `docker compose config` through `Invoke-WazuhSingleNodeCompose.ps1`
- `generate-indexer-certs.yml` compose validation
- certificate and secret presence checks
- dashboard config rendering checks
- a config snapshot under `logs/deployments/wazuh-rollout-<timestamp>/`

## Apply

By default the apply path takes a pre-change recovery snapshot with `backup-current-state.ps1` before recreating containers:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-WazuhSingleNodeRollout.ps1 -Apply
```

If you intentionally want to skip the pre-change recovery snapshot:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-WazuhSingleNodeRollout.ps1 -Apply -SkipPreBackup
```

The rollout order is:

1. `wazuh-indexer`
2. `wazuh-manager`
3. `wazuh-dashboard`

After each recreation the helper waits for the container to come back and then checks:

- Indexer: HTTPS response on `9200`
- Manager: authenticated API response on `55000`
- Dashboard: HTTPS login endpoint on `5601`

## Evidence Captured

Each run writes a timestamped folder under `logs/deployments/` containing:

- pre and post `docker ps`
- rendered Wazuh compose config
- rendered `generate-indexer-certs.yml` config
- pre-change backup output when apply runs without `-SkipPreBackup`
- container inspect JSON after each rollout step
- a Wazuh config snapshot

## Rollback

The safest rollback path is the recovery snapshot taken before apply:

- `wazuh-docker-stack/single-node/recovery-bundle/backups/monitoring-host/<timestamp>/`
- `wazuh-docker-stack/single-node/recovery-bundle/backups/metadata/<timestamp>/`
- `wazuh-docker-stack/single-node/recovery-bundle/backups/sensor-vm/ubuntu-subash-192.168.1.6-<timestamp>.tgz`

If you only need to reapply the current pinned stack after restoring config or secrets, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-WazuhSingleNodeCompose.ps1 up -d --force-recreate wazuh-indexer wazuh-manager wazuh-dashboard
```
