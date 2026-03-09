# Deploy Wazuh Docker in single node configuration

This deployment is defined in the `docker-compose.yml` file with one Wazuh manager containers, one Wazuh indexer containers, and one Wazuh dashboard container. It can be deployed by following these steps: 

1) Increase max_map_count on your host (Linux). This command must be run with root permissions:
```
$ sysctl -w vm.max_map_count=262144
```
2) Run the certificate creation script:
```
$ docker compose -f generate-indexer-certs.yml run --rm generator
```
3) Create local secret files under `../secrets/`:

- `indexer_password.txt`
- `api_password.txt`
- `dashboard_password.txt`

4) Start the environment with the secret-aware wrapper:

- On Windows from the repository root:
```
$ powershell -ExecutionPolicy Bypass -File ..\scripts\windows\Invoke-WazuhSingleNodeCompose.ps1 up -d
```

- On Linux from the repository root:
```
$ ./scripts/linux/run_wazuh_single_node_compose.sh up -d
```

You can still use raw `docker compose`, but only after exporting the required secret values into the shell environment.

The environment takes about 1 minute to get up (depending on your Docker host) for the first time since Wazuh Indexer must be started for the first time and the indexes and index patterns must be generated.

## Guarded rollouts

Use the repository runbook and helper for staged Wazuh single-node changes:

- `docs/runbooks/wazuh-single-node-rollout.md`
- `scripts/windows/Invoke-WazuhSingleNodeRollout.ps1`
