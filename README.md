# Monitoring Workspace

This workspace contains the active monitoring stack at the repository root and the Wazuh single-node stack under `wazuh-docker-stack/`.

## Active Runtime Paths

Do not move or rename these paths without updating Docker and restarting services:

- `docker-compose.yml`
- `.env`
- `prometheus.yml`
- `alert.rules.yml`
- `alertmanager.yml`
- `targets/`
- `secrets/`
- `scripts/python/`
- `wazuh-docker-stack/single-node/config/`

## Folder Guide

- `archives/` historical ZIPs and archived workspace snapshots
- `docs/` runbooks, guides, and reference material
- `logs/` host-side logs and deployment evidence
- `media/` screenshots and media assets
- `projects/reference/` upstream and reference material
- `scripts/linux/` Linux helper scripts
- `scripts/python/` Python automation used by the running forwarder
- `scripts/windows/` Windows helper scripts
- `soc-stack/` migration helper for the separate SOC stack project
- `Sysmon/` Sysmon binaries and EULA
- `targets/` Prometheus file-based target inventories
- `wazuh-docker-stack/` Wazuh deployment, config, and recovery bundle

## Runtime Settings

- `.env` active Compose settings for image pins and forwarder runtime values
- `.env.example` template copy of the same settings
- `targets/ping_servers.yml` editable inventory for ICMP probe targets

## Operations

- `scripts/windows/Invoke-MonitoringPhase1Rollout.ps1` validation-first rollout helper for the staged Phase 1 changes
- `docs/runbooks/phase1-rollout.md` human-readable rollout procedure and rollback notes

## Archived Snapshot

Legacy duplicate config backups were moved out of the active workspace to:

- `archives/workspace-snapshots/20260309-000338/`

That snapshot contains the older `.bak` files and the previous Python backup so the working area stays clean without losing rollback history.
