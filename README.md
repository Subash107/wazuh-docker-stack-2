# Monitoring Stack

This repository packages a small SOC-style monitoring environment built around Wazuh, Prometheus, Alertmanager, and Blackbox Exporter. It is structured for local deployment first, with the root stack handling monitoring and alert delivery while the bundled `wazuh-docker-stack/` directory provides the Wazuh platform and recovery assets.

## What is included

- Prometheus for metrics collection and alert evaluation
- Blackbox Exporter for ICMP availability checks
- Alertmanager for routing notifications
- A Python-based Wazuh alert forwarder that reads Wazuh alerts and posts normalized alerts into Alertmanager
- A bundled Wazuh Docker stack with single-node, multi-node, and recovery material

## Repository layout

```text
.
|-- docker-compose.yml
|-- prometheus.yml
|-- alert.rules.yml
|-- alertmanager.yml
|-- .env.example
|-- targets/
|-- scripts/
|   |-- python/
|   |-- windows/
|   `-- linux/
|-- docs/
|   |-- runbooks/
|   `-- reference/
`-- wazuh-docker-stack/
```

## How the stack is split

- Repository root: monitoring services, alert routing, and the custom Wazuh-to-Alertmanager forwarder
- `wazuh-docker-stack/`: Wazuh deployment assets, Docker Compose stacks, and recovery automation

The root monitoring stack expects the external Docker volume `single-node_wazuh_logs` to exist, which is provided by the single-node Wazuh deployment.

## Quick start

1. Copy `.env.example` to `.env` and adjust values for your environment.
2. Create required local-only secrets under `secrets/`.
3. Review `targets/ping_servers.yml` and update monitored hosts.
4. Start the Wazuh single-node stack from `wazuh-docker-stack/single-node/`.
5. Start the monitoring stack from the repository root with `docker compose up -d`.

## Configuration files

- `docker-compose.yml`: root monitoring services
- `prometheus.yml`: scrape jobs and alerting targets
- `alert.rules.yml`: stack health and ICMP probe alerts
- `alertmanager.yml`: notification routing
- `targets/ping_servers.yml`: file-based ICMP target inventory

## Operations

- `docs/runbooks/phase1-rollout.md`: staged rollout and rollback notes
- `scripts/windows/Invoke-MonitoringPhase1Rollout.ps1`: validation-first rollout helper

## Secrets and publish safety

This repository is prepared for public Git hosting:

- live secrets are excluded from Git
- example config files are tracked instead of secret-bearing runtime files
- local-only files such as `.env`, dashboard credentials, and certificate material remain untracked

Before deploying, create or supply these local-only inputs yourself:

- `.env`
- `secrets/brevo_smtp_key.txt`
- Wazuh dashboard runtime config
- Wazuh indexer user credential material and certificates

## Notes

- The repository contains deployment scripts for both Windows and Linux operators.
- The bundled Wazuh stack includes upstream-style build and recovery assets in addition to runtime Compose files.
- The current public branch is intended to be safe to share, but it is still a deployment repository, not a generic product template.
