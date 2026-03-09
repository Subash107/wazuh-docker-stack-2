# Ubuntu Lightweight SOC

This runbook points to the low-resource Ubuntu SOC profile that combines:

- Suricata
- Cowrie
- Wazuh agent ingestion
- OpenCTI-derived IOC enrichment for Wazuh
- Grafana dashboards

Project root:

- `projects/ubuntu-lightweight-soc/`

Use this profile when:

- the Ubuntu host only has 4 GB RAM
- you want centralized alerts in Wazuh without running the full Wazuh stack locally
- you still want local dashboards and optional threat-intelligence enrichment

Keep the OpenCTI overlay optional on 4 GB hosts. The supported low-resource path is the core stack plus IOC export into Wazuh lists.

Primary entrypoints:

- `projects/ubuntu-lightweight-soc/scripts/install_host.sh`
- `projects/ubuntu-lightweight-soc/docker-compose.yml`
- `projects/ubuntu-lightweight-soc/docker-compose.opencti.yml`
- `projects/ubuntu-lightweight-soc/README.md`
