# Monitoring Stack

This repository packages a small SOC-style monitoring environment built around Wazuh, Prometheus, Grafana, Alertmanager, Blackbox Exporter, and an internal service index page. It is structured for local deployment first, with the root stack handling monitoring and alert delivery while the bundled `wazuh-docker-stack/` directory provides the Wazuh platform and recovery assets.

## What is included

- Prometheus for metrics collection and alert evaluation
- Grafana for dashboarding over the live Prometheus metrics
- Blackbox Exporter for ICMP availability checks
- Alertmanager for routing notifications
- A Python-based Wazuh alert forwarder that reads Wazuh alerts and posts normalized alerts into Alertmanager
- A Python-based monitoring service index page with live health, service links, credential sources, and handbook PDFs
- A bundled Wazuh Docker stack with single-node, multi-node, and recovery material

## Repository layout

```text
.
|-- docker-compose.yml
|-- prometheus.yml
|-- alert.rules.yml
|-- alertmanager.yml
|-- grafana/
|-- .env.example
|-- targets/
|-- scripts/
|   |-- python/
|   |-- windows/
|   `-- linux/
|-- docs/
|   |-- operator-handbook/
|   |-- pdf-handbook/
|   |-- runbooks/
|   `-- reference/
|-- logs/
|-- local/
`-- wazuh-docker-stack/
    `-- single-node/recovery-bundle/
```

## How the stack is split

- Repository root: monitoring services, alert routing, and the custom Wazuh-to-Alertmanager forwarder
- `wazuh-docker-stack/`: Wazuh deployment assets, Docker Compose stacks, and recovery automation

The root monitoring stack expects the external Docker volume `single-node_wazuh_logs` to exist, which is provided by the single-node Wazuh deployment.

## Quick start

1. Copy `.env.example` to `.env` and adjust values for your environment.
2. Create required local-only secrets under `secrets/`.
3. Generate gateway credentials with `scripts/windows/Invoke-GatewayAccessSetup.ps1`.
4. Review `targets/ping_servers.yml` and update monitored hosts.
5. Start the Wazuh single-node stack from `wazuh-docker-stack/single-node/`.
6. Start the monitoring stack from the repository root with `docker compose up -d`.

## Configuration files

- `docker-compose.yml`: root monitoring services
- `prometheus.yml`: scrape jobs and alerting targets
- `blackbox.yml`: Blackbox Exporter probe modules
- `alert.rules.yml`: stack health and ICMP probe alerts
- `alertmanager.yml`: notification routing
- `grafana/`: provisioned datasource and monitoring dashboards
- `targets/ping_servers.yml`: file-based ICMP target inventory
- `targets/sensor_http_endpoints.yml`: Pi-hole and mitmproxy HTTP probe inventory
- `targets/practice_http_endpoints.yml`: optional isolated practice-target HTTP inventory
- `targets/sensor_tcp_endpoints.yml`: mitmproxy TCP probe inventory
- `targets/sensor_dns_endpoints.yml`: Pi-hole DNS probe inventory

## Operations

- `docs/runbooks/phase1-rollout.md`: staged rollout and rollback notes
- `docs/runbooks/wazuh-single-node-rollout.md`: guarded Wazuh single-node rollout path
- `docs/runbooks/sensor-vm-bootstrap.md`: canonical Ubuntu sensor deployment path
- `docs/runbooks/secret-vault.md`: encrypted local secret export, import, and rekey workflow
- `docs/runbooks/bare-metal-rebuild-drill.md`: staged clean-host rebuild rehearsal from the recovery bundle and secret vault
- `docs/runbooks/ubuntu-lightweight-soc.md`: low-resource Ubuntu SOC profile with Suricata, Cowrie, Wazuh ingestion, and Grafana
- `docs/reference/repository-layout.md`: folder map for source-of-truth files vs generated recovery artifacts
- `docs/operator-handbook/lab-environment-guide.md`: applies closed-network lab, recovery, multi-OS, duplicate-tool, and practice-target principles to this repo
- `docs/operator-handbook/README.md`: installation, troubleshooting, tools usage, access inventory, and threat monitoring guides
- `docs/pdf-handbook/README.md`: offline PDF export set in one folder
- `scripts/windows/Invoke-ProjectSecretMigration.ps1`: move local secrets into gitignored secret files
- `scripts/windows/Invoke-MonitoringPhase1Rollout.ps1`: validation-first rollout helper
- `scripts/windows/Invoke-WazuhSingleNodeRollout.ps1`: validation-first Wazuh single-node rollout helper
- `scripts/windows/Invoke-GatewayAccessSetup.ps1`: create or rotate local HTTPS gateway credentials
- `scripts/windows/Invoke-SecretVaultExport.ps1`: encrypt local secret files into one vault file
- `scripts/windows/Invoke-SecretVaultImport.ps1`: restore local secret files from the encrypted vault
- `scripts/windows/Invoke-SecretVaultRekey.ps1`: rotate the encrypted vault passphrase
- `scripts/windows/Invoke-BareMetalRebuildDrill.ps1`: stage a clean-host rebuild drill from the recovery bundle and secret vault, including staged sensor bootstrap and archive validation
- `scripts/windows/Invoke-SensorVmBootstrap.ps1`: Windows entrypoint for the canonical sensor bootstrap
- `scripts/windows/Invoke-Day1Check.ps1`: run the day-1 readiness and health checklist, with optional stack startup
- `scripts/windows/Invoke-LabIdeologyAudit.ps1`: audit the repo against the tracked lab ideology profile and practice-target model
- `scripts/windows/Invoke-PrivateCredentialExport.ps1`: local-only credential export generator
- `scripts/windows/Invoke-PrivateOperatorLauncher.ps1`: local-only launcher for the public index, private credentials, and PDFs
- `scripts/windows/Invoke-WazuhSingleNodeCompose.ps1`: local secret-aware wrapper for Wazuh single-node compose commands
- `.github/workflows/ci-smoke-checks.yml`: repo smoke validation for compose rendering, config checks, gateway validation, and one Blackbox probe
- `scripts/python/monitoring_service_index.py`: internal browser page for service health, links, and PDF docs

## Canonical Sensor Deployment

Phase 1 standardizes the Ubuntu sensor on one declared blueprint instead of multiple inline-generated installers.

- source of truth: `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/`
- Windows entrypoint: `scripts/windows/Invoke-SensorVmBootstrap.ps1`
- Linux entrypoint: `scripts/linux/bootstrap_sensor_vm.sh`

The older Ubuntu install scripts under `scripts/linux/` and `scripts/windows/` remain in the repo only as compatibility wrappers that delegate to the canonical bootstrap.

The canonical sensor path now also defaults Pi-hole and mitmproxy to pinned digests through the blueprint and Windows wrapper.

## Secrets and publish safety

This repository is prepared for public Git hosting:

- live secrets are excluded from Git
- example config files are tracked instead of secret-bearing runtime files
- local-only files such as `.env`, dashboard credentials, and certificate material remain untracked
- an encrypted local secret vault is available under `local/secret-vault/`

Before deploying, create or supply these local-only inputs yourself:

- `.env`
- `secrets/brevo_smtp_key.txt`
- `secrets/gateway_admin_username.txt`
- `secrets/gateway_admin_password.txt`
- `secrets/gateway_admin_password_hash.txt`
- `secrets/grafana_admin_username.txt`
- `secrets/grafana_admin_password.txt`
- `secrets/vm_ssh_password.txt`
- `secrets/vm_sudo_password.txt`
- `secrets/pihole_web_password.txt`
- `wazuh-docker-stack/secrets/indexer_password.txt`
- `wazuh-docker-stack/secrets/api_password.txt`
- `wazuh-docker-stack/secrets/dashboard_password.txt`
- Wazuh dashboard runtime config
- Wazuh indexer user credential material and certificates

The generated PDF handbook lives under `docs/pdf-handbook/` and is served by the monitoring service index on `http://192.168.1.3:9088`.

Use `scripts/windows/Invoke-GatewayAccessSetup.ps1` to generate or rotate the gateway credential files locally.
Use `scripts/windows/Invoke-SecretVaultExport.ps1` to keep an encrypted backup of the local secret state.
Use `scripts/windows/Invoke-BareMetalRebuildDrill.ps1` to rehearse a clean monitoring-host rebuild and staged sensor recovery validation before you need a real recovery.

## Troubleshooting-friendly structure

- Root files and folders are the source of truth for the live monitoring host.
- `wazuh-docker-stack/single-node/` is the source of truth for the live Wazuh stack.
- `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/` is the only tracked clean-build blueprint.
- `wazuh-docker-stack/single-node/recovery-bundle/backups/` is the timestamped recovery history, not a second source tree.
- `projects/ubuntu-lightweight-soc/` is the dedicated 4 GB Ubuntu SOC lab profile.
- `local/`, `logs/`, and `archives/` hold machine-local or generated operational artifacts.

## Notes

- The repository contains deployment scripts for both Windows and Linux operators.
- The bundled Wazuh stack includes upstream-style build and recovery assets in addition to runtime Compose files.
- The current public branch is intended to be safe to share, but it is still a deployment repository, not a generic product template.
