# Tools User Guide

## Wazuh Dashboard

Primary use:

- review agents
- investigate alerts
- search Suricata and system events

Useful areas:

- Dashboard home
- Security events
- Agents
- Rules and decoders

## Monitoring Service Index

URL:

- `http://192.168.1.3:9088`

Use it for:

- opening the current service URLs from one page
- checking a quick health summary without going into Prometheus
- opening the PDF handbook set from the browser
- reviewing current firing Prometheus alerts

Note:

- the service index intentionally does not expose live passwords over the LAN
- use `scripts/windows/Invoke-PrivateCredentialExport.ps1` for a local-only credential page with actual secret values
- use `scripts/windows/Invoke-PrivateOperatorLauncher.ps1` for a local-only launcher page that opens the service index, the private credential page, and the handbook PDFs
- use `scripts/windows/Invoke-WazuhSingleNodeCompose.ps1` instead of raw `docker compose` when you need to validate or restart the Wazuh single-node stack with file-based secrets

## Prometheus

URL:

- `http://192.168.1.3:9090`

Useful queries:

- `up`
- `probe_success`
- `probe_duration_seconds`
- `ALERTS`
- `increase(alertmanager_notifications_failed_total[10m])`

Use Prometheus for:

- checking whether a probe is failing
- seeing which job and target labels are attached
- confirming when an alert entered `pending` or `firing`

## Alertmanager

URL:

- `http://192.168.1.3:9093`

Use Alertmanager for:

- seeing which alerts are grouped
- confirming whether stack health alerts are routed to `stack-email`
- confirming whether Wazuh threat alerts are routed to `email`

## Blackbox Exporter

URL:

- `http://192.168.1.3:9115/metrics`

Use it for:

- confirming probe metrics exist
- validating probe modules in `blackbox.yml`
- testing HTTP, TCP, ICMP, and DNS reachability through Prometheus jobs

## Pi-hole

Primary URL:

- `http://192.168.1.6:8080/admin/login`

Use Pi-hole for:

- query log review
- allowlist and blocklist changes
- DNS upstream visibility
- client-level blocking behavior

## mitmproxy

Primary URL:

- `http://192.168.1.6:8083/#/flows`

Proxy listener:

- `192.168.1.6:8082`

Use mitmproxy for:

- reviewing captured HTTP and HTTPS flows
- tracing suspicious outbound requests
- validating proxy interception in the sensor path

Notes:

- the web UI now presents an authentication prompt before showing flows
- get the current token from `docker logs mitmproxy` on the sensor VM
- an unauthenticated `403 Authentication Required` response is expected and is treated as healthy by monitoring
