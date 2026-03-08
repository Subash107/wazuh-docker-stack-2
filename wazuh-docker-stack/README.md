# Wazuh Docker Stack

This directory contains the Wazuh platform assets used by the parent monitoring repository. It includes runtime Compose files, build assets, and recovery automation for both single-node and multi-node layouts.

## Contents

- `single-node/`: primary local deployment used by the monitoring stack
- `multi-node/`: clustered Wazuh reference deployment
- `build-docker-images/`: custom image build definitions
- `indexer-certs-creator/`: helper image for generating indexer certificates
- `tools/`: maintenance scripts

## Deployment notes

- The repository root monitoring stack depends on the single-node deployment exposing the `single-node_wazuh_logs` Docker volume.
- Secret-bearing runtime files are intentionally not tracked in Git.
- Example files are provided for dashboard configuration, environment variables, and indexer user definitions.

## Files you must supply locally

- `.env`
- `single-node/config/wazuh_dashboard/wazuh.yml`
- `single-node/config/wazuh_indexer/internal_users.yml`
- `multi-node/config/wazuh_dashboard/wazuh.yml`
- `multi-node/config/wazuh_indexer/internal_users.yml`
- certificate material under `single-node/config/wazuh_indexer_ssl_certs/`

## Safe starting points

- `single-node/docker-compose.yml`
- `single-node/generate-indexer-certs.yml`
- `.env.example`

## Recovery bundle

The `single-node/recovery-bundle/` directory contains scripts and examples for backup, redeploy, and host recovery workflows. Review the examples before using them in a real environment because they assume operator-supplied secrets and host-specific values.
