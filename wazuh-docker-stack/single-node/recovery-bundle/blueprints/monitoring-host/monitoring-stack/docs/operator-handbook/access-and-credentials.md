# Access And Credentials

This page lists the current known LAN endpoints and the credential source for each service.

Do not commit real passwords into this file. Keep passwords in local-only sources and update this page only with the source path or variable name.

## Current URLs

| Service | URL or Endpoint | Username | Password Source | Notes |
| --- | --- | --- | --- | --- |
| Wazuh Dashboard | `http://192.168.1.3:5601` | `admin` | local-only Wazuh runtime config | Main SOC dashboard |
| Monitoring Service Index | `http://192.168.1.3:9088` | none | none | Internal links, health view, and PDF docs |
| Prometheus | `http://192.168.1.3:9090` | none | none | Metrics and alert rules |
| Alertmanager | `http://192.168.1.3:9093` | none | none | Alert routing and status |
| Blackbox Exporter | `http://192.168.1.3:9115/metrics` | none | none | Probe exporter |
| Wazuh API | `https://192.168.1.3:55000` | `wazuh-wui` | `wazuh-docker-stack/secrets/api_password.txt` | API endpoint |
| Wazuh Indexer | `https://192.168.1.3:9200` | `admin` | `wazuh-docker-stack/secrets/indexer_password.txt` | Indexer/API backend |
| Pi-hole Admin | `http://192.168.1.6:8080/admin/login` | none | `secrets/pihole_web_password.txt` | Sensor DNS dashboard |
| Pi-hole DNS | `192.168.1.6:53` | none | none | UDP/TCP DNS listener |
| mitmproxy Web UI | `http://192.168.1.6:8083/#/flows` | none | mitmproxy startup token from `docker logs mitmproxy` on the sensor VM | Flow browser; unauthenticated requests are expected to return an auth prompt |
| mitmproxy Proxy | `192.168.1.6:8082` | none | none | Proxy listener |
| Ubuntu Sensor SSH | `ssh subash@192.168.1.6` | `subash` | `secrets/vm_ssh_password.txt` | Sensor administration |

## Current ICMP monitored nodes

- `192.168.1.3` with labels `host_name=monitoring_host`, `role=monitoring_host`
- `192.168.1.6` with labels `host_name=sensor_vm`, `role=sensor_vm`

## Local-only credential sources

- Monitoring host env: local `.env`
- Wazuh non-secret env: local `wazuh-docker-stack/.env`
- Wazuh indexer password: `wazuh-docker-stack/secrets/indexer_password.txt`
- Wazuh API password: `wazuh-docker-stack/secrets/api_password.txt`
- Wazuh dashboard service password: `wazuh-docker-stack/secrets/dashboard_password.txt`
- SMTP secret: `secrets/brevo_smtp_key.txt`
- Sensor SSH password: `secrets/vm_ssh_password.txt`
- Sensor sudo password: `secrets/vm_sudo_password.txt`
- Pi-hole password: `secrets/pihole_web_password.txt`
- mitmproxy Web UI token: runtime output from `docker logs mitmproxy` on the sensor VM

To migrate older local `.env` and override values into these secret files:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-ProjectSecretMigration.ps1
```

## Private local credential export

To generate a local-only page with actual secret values on this machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-PrivateCredentialExport.ps1
```

This writes:

- `local/operator-private/credential-export.html`
- `local/operator-private/credential-export.json`

The `local/operator-private/` folder is gitignored and is intended for this machine only.

To generate and open the local operator launcher page:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-PrivateOperatorLauncher.ps1
```

This also maintains:

- `local/operator-private/launcher.html`
- `local/operator-private/launcher.json`

## When IPs or ports change

Update:

- `scripts/python/service_index_assets/service_catalog.json`
- `targets/sensor_http_endpoints.yml`
- `targets/sensor_tcp_endpoints.yml`
- `targets/sensor_dns_endpoints.yml`
- `docs/operator-handbook/access-and-credentials.md`
