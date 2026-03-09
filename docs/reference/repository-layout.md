# Repository Layout

This repository now separates source-of-truth files from generated recovery artifacts so troubleshooting is easier.

## Source Of Truth

- Repository root:
  - live monitoring stack compose files, configs, targets, scripts, and operator docs
- `wazuh-docker-stack/single-node/`:
  - live Wazuh single-node stack source
- `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/`:
  - canonical clean-build sensor VM blueprint

## Generated Or Local-Only State

- `local/`:
  - encrypted vault, local credential exports, and other workstation-only artifacts
- `logs/`:
  - rollout evidence, rebuild drill logs, and host-side troubleshooting output
- `archives/`:
  - exported packages and offline artifacts
- `wazuh-docker-stack/single-node/recovery-bundle/backups/`:
  - immutable timestamped recovery snapshots for the monitoring host, sensor VM, and metadata

## Recovery Bundle Rules

- `blueprints/sensor-vm/` stays versioned because it is the clean sensor source of truth.
- Host-side recovery content is no longer kept as a second tracked copy under `blueprints/monitoring-host/`.
- Recovery scripts resolve host content from:
  1. the live repo source when running inside this workspace
  2. a selected timestamped snapshot under `backups/monitoring-host/<stamp>/`
  3. a legacy mirrored blueprint only as a fallback for older bundles

## Troubleshooting Guidance

- If the issue is with the running monitoring host, start at the repository root.
- If the issue is with Wazuh containers, start at `wazuh-docker-stack/single-node/`.
- If the issue is with rebuild or disaster recovery, start at `wazuh-docker-stack/single-node/recovery-bundle/README.md`.
- If the issue is with the Ubuntu sensor blueprint, use `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/`.
