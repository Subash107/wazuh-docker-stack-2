# Ubuntu Lightweight SOC

This project builds a small SOC lab for an Ubuntu host with 4 GB RAM by keeping the host sensor stack lean and pushing heavy correlation to Wazuh.

## Core Design

The default profile that is expected to run smoothly on 4 GB is:

- native `suricata`
- native `wazuh-agent`
- Docker `cowrie`
- Docker `prometheus`
- Docker `alertmanager`
- Docker `node-exporter`
- Docker `grafana`
- Docker `soc-telemetry-exporter`

The threat-intelligence path is Wazuh-native:

- OpenCTI indicators are exported to CSV
- `scripts/export_opencti_csv_to_wazuh.py` converts them into Wazuh CDB lists
- Wazuh local rules match Suricata and Cowrie fields against those IOC lists

This avoids running the full Wazuh indexer stack on the same 4 GB host.

## Why OpenCTI Is Optional

The full OpenCTI Docker stack requires Elasticsearch, RabbitMQ, Redis, MinIO, the platform service, and at least one worker. That is not a realistic "runs smoothly" profile on 4 GB RAM next to Suricata, Cowrie, and Grafana.

Use the default core profile on 4 GB.

Only use `docker-compose.opencti.yml` when:

- you accept degraded performance on 4 GB, or
- you move OpenCTI to a separate host, or
- you temporarily start OpenCTI for IOC maintenance and then stop it

The OpenCTI overlay is deliberately memory-capped, but it is still not the recommended steady-state profile for a 4 GB host.

## Files

- `docker-compose.yml`
  - Core 4 GB profile
- `docker-compose.opencti.yml`
  - Optional local OpenCTI overlay
- `.env.example`
  - Ports, image defaults, memory limits, and alerting placeholders
- `prometheus/`
  - Scrape config and alert rules
- `alertmanager/alertmanager.yml`
  - Valid base config; add real Telegram or email receivers manually after replacing the placeholders
- `grafana/`
  - Provisioned datasource and dashboard
- `scripts/soc_telemetry_exporter.py`
  - Lightweight exporter that turns Suricata and Cowrie JSON into Prometheus metrics
- `scripts/export_opencti_csv_to_wazuh.py`
  - Converts OpenCTI CSV exports into Wazuh CDB IOC lists
- `scripts/install_host.sh`
  - Ubuntu installer for the core profile

## Wazuh Integration

The existing repo was updated so the Wazuh agent template now monitors:

- `/var/log/suricata/eve.json`
- `/opt/cowrie/var/log/cowrie/cowrie.json`

The Wazuh manager was also updated with:

- local rules for Suricata Nmap and suspicious-traffic detections
- Cowrie failed-login and brute-force correlation
- IOC list matching for IPs, domains, and SHA256 values

Relevant paths:

- `../../wazuh-docker-stack/single-node/config/wazuh_cluster/wazuh_manager.conf`
- `../../wazuh-docker-stack/single-node/config/wazuh_cluster/rules/local_rules.xml`
- `../../wazuh-docker-stack/single-node/config/wazuh_cluster/lists/`

## Install On Ubuntu

1. Copy `.env.example` to `.env` and adjust ports or credentials if needed.
2. Run:

```bash
sudo bash ./scripts/install_host.sh --manager-ip 192.168.1.3
```

3. Verify:

```bash
systemctl status suricata
systemctl status wazuh-agent
docker compose ps
curl -fsS http://127.0.0.1:9150/healthz
```

## Start And Stop

Core profile:

```bash
docker compose up -d
docker compose down
```

Optional OpenCTI overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.opencti.yml up -d
docker compose -f docker-compose.yml -f docker-compose.opencti.yml down
```

## OpenCTI To Wazuh IOC Workflow

1. Export indicators from OpenCTI to CSV.
2. Convert them into Wazuh CDB lists:

```bash
python3 ./scripts/export_opencti_csv_to_wazuh.py /path/to/opencti-export.csv
```

3. Restart the Wazuh manager so the list changes are loaded.

## Dashboards

Grafana ships with a provisioned dashboard covering:

- top attacker IPs
- Suricata alerts by signature
- Cowrie honeypot activity
- recent OpenCTI indicator matches
- system CPU usage

Default URL:

- `http://<ubuntu-host>:3001`

Default login:

- user: `admin`
- password: `admin`

Change the password after the first login.
