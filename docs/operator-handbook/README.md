# Operator Handbook

This folder is the central operator documentation set for the monitoring project.

Use these documents in this order:

1. [Project Overview](/d:/Monitoring/docs/operator-handbook/project-overview.md)
2. [Installation Guide](/d:/Monitoring/docs/operator-handbook/installation-guide.md)
3. [Access And Credentials](/d:/Monitoring/docs/operator-handbook/access-and-credentials.md)
4. [Tools User Guide](/d:/Monitoring/docs/operator-handbook/tools-user-guide.md)
5. [Monitoring And Threat Identification Guide](/d:/Monitoring/docs/operator-handbook/monitoring-and-threat-identification-guide.md)
6. [Troubleshooting](/d:/Monitoring/docs/operator-handbook/troubleshooting.md)
7. [PDF Handbook Folder](/d:/Monitoring/docs/pdf-handbook/README.md)

## Scope

The handbook covers:

- monitoring host deployment
- Ubuntu sensor bootstrap and restore
- Prometheus, Alertmanager, Blackbox, Wazuh, Pi-hole, and mitmproxy usage
- current LAN URLs and credential sources
- common break/fix procedures
- offline PDF exports in one folder under `docs/pdf-handbook/`

## Canonical deployment paths

- Monitoring host rollout: [phase1-rollout.md](/d:/Monitoring/docs/runbooks/phase1-rollout.md)
- Wazuh single-node rollout: [wazuh-single-node-rollout.md](/d:/Monitoring/docs/runbooks/wazuh-single-node-rollout.md)
- Sensor bootstrap: [sensor-vm-bootstrap.md](/d:/Monitoring/docs/runbooks/sensor-vm-bootstrap.md)
- Local secret vault: [secret-vault.md](/d:/Monitoring/docs/runbooks/secret-vault.md)
- Bare-metal rebuild drill: [bare-metal-rebuild-drill.md](/d:/Monitoring/docs/runbooks/bare-metal-rebuild-drill.md)
- Sensor blueprint source of truth: [README.md](/d:/Monitoring/wazuh-docker-stack/single-node/recovery-bundle/blueprints/sensor-vm/README.md)
