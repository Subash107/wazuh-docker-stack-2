# Lab Environment Guide

This guide applies a practical lab ideology to the monitoring project so the repo stays useful as a safe SOC lab, a recovery-ready deployment, and a repeatable operator environment.

## Core principle

Treat this repository as a segmented lab platform, not just a container bundle.

That means the environment should:

- stay on a controlled private network
- be easy to rebuild from virtualization and recovery assets
- look close enough to a real environment that the findings are meaningful
- explain failures with monitoring instead of guesswork
- declare enough hardware headroom that false negatives are less likely
- cover more than one operating system
- let operators validate the same finding with more than one tool
- include isolated practice targets that are monitored like real services

## How this project now maps to the ideology

### Closed network

Use the monitoring host, sensor VM, and any practice targets on a declared private lab subnet.

Current project alignment:

- monitoring host address is `192.168.1.3`
- sensor VM address is `192.168.1.6`
- HTTPS operator ingress is concentrated behind the monitoring gateway
- target inventories are expected to stay on private or internal addresses

Recommended operating rule:

- keep practice targets on the lab subnet only
- do not expose deliberately vulnerable services directly to the Internet
- treat public SMTP and IP geolocation lookups as explicit, narrow egress exceptions

### Virtualized computing environment

This repo already uses a virtualized deployment model:

- a Windows monitoring host
- an Ubuntu sensor VM
- a tracked sensor blueprint under `wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/`
- a recovery bundle and rebuild drill path for the monitoring host

Use snapshots or image-based recovery for practice targets too, so you can reset them after testing.

### Realistic environment

The lab should resemble a real operator environment closely enough that alerts, routing, and failure modes stay meaningful.

Use these repo rules:

- keep the same IP plan and service ports in targets and docs where possible
- prefer pinned image digests for deterministic rebuilds
- monitor practice targets through the same Prometheus and Blackbox path as production-like services
- use the tracked lab profile in `docs/reference/lab-ideology-profile.json` when updating addresses, resources, or target roles

### Health monitoring

This project already gives you layered health monitoring:

- Prometheus for scrape and alert evaluation
- Blackbox Exporter for ICMP, HTTP, TCP, DNS, gateway, and practice-target checks
- Alertmanager for notification routing
- Wazuh for security event correlation
- the service index for operator-facing health summaries
- `Invoke-Day1Check.ps1` for startup verification
- `Invoke-LabIdeologyAudit.ps1` for structural lab-alignment checks

If a lab component fails, the expectation is that operators can answer why, not just that it is down.

### Sufficient hardware resources

This repository now tracks a declared baseline in `docs/reference/lab-ideology-profile.json`.

Recommended baseline:

- monitoring host: 4 CPU cores, 8 GB RAM, 100 GB disk
- sensor VM: 2 CPU cores, 4 GB RAM, 40 GB disk

If you must stay resource-constrained, use the dedicated low-resource profile under `projects/ubuntu-lightweight-soc/`.

### Multiple operating systems

The minimum OS coverage for this project is already mixed:

- Windows monitoring host
- Ubuntu sensor VM

Recommended expansion:

- one Windows practice target VM
- one Linux practice target VM

That lets you validate whether a detection or workflow behaves differently across platforms.

### Duplicate tools

Use more than one tool to validate important findings.

Suggested cross-check matrix:

- DNS anomalies: Pi-hole plus Wazuh
- web traffic anomalies: mitmproxy plus Suricata
- IDS findings: Suricata plus Wazuh
- service availability issues: Prometheus and Blackbox plus direct operator checks

The tracked duplicate-tool matrix lives in `docs/reference/lab-ideology-profile.json`.

### Practice targets

Practice targets should be treated as first-class monitored assets, not side notes.

This repo now includes:

- `targets/practice_http_endpoints.yml` for isolated practice-target inventory
- `prometheus.yml` scrape support for `practice_http_endpoints`
- `alert.rules.yml` rules for practice-target health

Use that inventory only for deliberately vulnerable or training-only systems that stay inside the lab boundary.

## Recommended workflow

1. Update `docs/reference/lab-ideology-profile.json` when the lab design changes.
2. Add or update isolated practice targets in `targets/practice_http_endpoints.yml`.
3. Run `Invoke-LabIdeologyAudit.ps1` after structural changes.
4. Run `Invoke-Day1Check.ps1` after deployment changes.
5. Keep the rebuild drill and secret vault current so the lab is recoverable.
