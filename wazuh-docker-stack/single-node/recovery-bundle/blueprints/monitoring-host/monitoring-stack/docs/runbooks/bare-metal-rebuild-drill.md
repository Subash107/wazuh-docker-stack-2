# Bare-Metal Rebuild Drill

This runbook rehearses a clean monitoring-host rebuild from two artifacts only:

- the recovery bundle under `wazuh-docker-stack/single-node/recovery-bundle/`
- the encrypted local secret vault under `local/secret-vault/monitoring-secrets.enc.json`

The default mode is safe validation. It stages a fresh workspace under `logs/rebuild-drills/`, imports the secret vault, then runs the guarded Wazuh and monitoring rollout validators against that staged root.

## Validation Drill

```powershell
$env:MONITORING_SECRET_VAULT_PASSPHRASE = "choose-a-strong-passphrase"
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-BareMetalRebuildDrill.ps1
```

Artifacts are written under:

- `logs/rebuild-drills/bare-metal-<timestamp>/`

The staged rebuild workspace is inside:

- `logs/rebuild-drills/bare-metal-<timestamp>/workspace/`

## Clean-Host Apply Drill

Use this only on a clean Docker host. The workflow will refuse to run if the host already has the fixed monitoring or Wazuh containers, volumes, or compose networks.

```powershell
$env:MONITORING_SECRET_VAULT_PASSPHRASE = "choose-a-strong-passphrase"
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-BareMetalRebuildDrill.ps1 -Apply
```

To rehearse restoring the saved Wazuh Docker volumes too:

```powershell
$env:MONITORING_SECRET_VAULT_PASSPHRASE = "choose-a-strong-passphrase"
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-BareMetalRebuildDrill.ps1 -Apply -RestoreVolumeBackups
```

## What The Drill Does

1. Deploys the monitoring-host blueprints from the recovery bundle into a fresh staged root using `deploy-monitoring-host.ps1 -SkipLocalSeed -SkipValidation -SkipStart`.
2. Imports the encrypted vault into that staged root.
3. Runs `Invoke-WazuhSingleNodeRollout.ps1` against the staged root first.
4. Runs `Invoke-MonitoringPhase1Rollout.ps1` against the staged root second.
5. In `-Apply` mode, probes gateway `/healthz`, an authenticated Prometheus gateway request, and the monitoring service index health endpoint.

Wazuh is validated first because the root monitoring stack expects the external volume `single-node_wazuh_logs` to exist.

## Outputs

The drill summary is written to:

- `logs/rebuild-drills/bare-metal-<timestamp>/summary.txt`

That summary records:

- source bundle path
- source vault path
- staged workspace path
- monitoring rollout artifact path
- Wazuh rollout artifact path
- the latest available sensor VM archive path

## Next Step After Host Drill

The drill only proves the Windows monitoring host rebuild path. The sensor VM still needs one of these:

- clean bootstrap: `scripts/windows/Invoke-SensorVmBootstrap.ps1`
- archive restore: `restore-sensor-vm.sh` from the recovery bundle
