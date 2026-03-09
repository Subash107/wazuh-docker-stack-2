# Project Overview

## Purpose

This project runs a small SOC-style monitoring environment across two nodes:

- a Windows monitoring host at `192.168.1.3`
- an Ubuntu sensor VM at `192.168.1.6`

The host runs Wazuh, Prometheus, Grafana, Alertmanager, Blackbox Exporter, the Wazuh alert forwarder, and the service index page. The sensor VM runs Pi-hole, mitmproxy, Suricata, and the Wazuh agent.

## Current architecture

### Monitoring host

- Wazuh Dashboard
- Wazuh API
- Wazuh Indexer
- Prometheus
- Grafana
- Alertmanager
- Blackbox Exporter
- Wazuh alert forwarder
- Monitoring service index

### Ubuntu sensor VM

- Pi-hole DNS and admin dashboard
- mitmproxy proxy listener and web UI
- Suricata IDS
- Wazuh agent

## Detection flow

1. The sensor VM produces DNS, proxy, and IDS telemetry.
2. The Wazuh agent forwards security-relevant logs to the Wazuh manager.
3. The Python forwarder normalizes Wazuh alerts and sends them to Alertmanager.
4. Prometheus and Blackbox Exporter monitor service health and raise stack alerts.
5. Grafana visualizes the live health and probe metrics from Prometheus.
6. Alertmanager routes threat notifications and stack health alerts by email.

## Canonical deployment model

The current source of truth is:

- root monitoring stack files in the repository root
- the canonical Ubuntu sensor blueprint in `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/`

Legacy installer scripts still exist only as compatibility wrappers. They should not be treated as separate deployment methods.

## Current operator docs

- Installation guide
- Troubleshooting guide
- Tools user guide
- Access and credentials guide
- Monitoring and threat identification guide

All of these are available in markdown under `docs/operator-handbook/` and as PDFs under `docs/pdf-handbook/`.
