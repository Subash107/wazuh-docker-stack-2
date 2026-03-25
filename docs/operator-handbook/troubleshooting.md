# Troubleshooting

## Monitoring host

### Service index page does not load

Check:

- `docker compose ps monitoring-service-index`
- `docker logs monitoring-service-index`
- `curl http://127.0.0.1:9088/healthz`
- `curl http://127.0.0.1:9088/api/status`

Common causes:

- `docs/pdf-handbook/` is empty or missing
- `scripts/python/service_index_assets/` is missing from the host
- port `9088` is already bound by another process

### Prometheus config will not load

Check:

- `docker compose config`
- `docker run --rm --entrypoint promtool -v ${PWD}/prometheus.yml:/etc/prometheus/prometheus.yml -v ${PWD}/alert.rules.yml:/etc/prometheus/alert.rules.yml -v ${PWD}/targets:/etc/prometheus/targets prom/prometheus:latest check config /etc/prometheus/prometheus.yml`
- `docker run --rm -v ${PWD}/blackbox.yml:/etc/blackbox_exporter/config.yml prom/blackbox-exporter:latest --config.file=/etc/blackbox_exporter/config.yml --config.check`

Common causes:

- missing `targets/` files
- invalid `blackbox.yml`
- stale bind mounts after editing files

### Alerts are visible in Prometheus but no email arrives

Check:

- `docker logs alertmanager`
- `prometheus` alert state at `http://192.168.1.3:9090/alerts`
- `http://192.168.1.3:9093/#/alerts`
- `alertmanager_notifications_failed_total`

Confirm:

- `secrets/brevo_smtp_key.txt` exists
- `alertmanager.yml` still has the `stack-email` receiver

## Ubuntu sensor

### Pi-hole admin page does not load

Check:

- `systemctl status monitoring-sensor-compose`
- `docker ps`
- `docker logs pihole`
- `curl http://127.0.0.1:8080/admin/login`
- `iptables -S DOCKER-USER`

Legacy conflict to look for:

- old `docker-user-hardening.service`
- Pi-hole only listening on localhost

### DNS works on the VM but not from the LAN

Check:

- `dig @127.0.0.1 example.com`
- `dig @192.168.1.6 example.com`
- `docker exec pihole grep -n "listeningMode" /etc/pihole/pihole.toml`
- `docker exec pihole grep -n "upstreams" /etc/pihole/pihole.toml`

Expected state:

- LAN clients can reach UDP/TCP 53
- Pi-hole listening mode allows LAN access
- upstream DNS is reachable from the VM

### mitmproxy web UI fails

Check:

- `docker logs mitmproxy`
- `curl -i http://192.168.1.6:8083/`
- `ss -ltnp | grep 8083`

Note:

- `HEAD` to mitmweb may return `405`; use a normal browser GET or `curl` GET
- `403 Authentication Required` is expected before you enter the current token
- if you need the token, read the mitmproxy container startup logs with `docker logs mitmproxy`

### mitmproxy proxy listener fails

Check:

- `ss -ltnp | grep 8082`
- `curl -v --proxy http://192.168.1.6:8082 http://example.com/`
- `systemctl status monitoring-sensor-firewall`

### Wazuh agent disconnected

Check:

- `systemctl status wazuh-agent`
- `tail -n 50 /var/ossec/logs/ossec.log`
- `grep -n "<address>" /var/ossec/etc/ossec.conf`

Expected state:

- manager IP matches the monitoring host
- TCP `1514` reachable from the sensor VM

## Blackbox probe mapping

- `targets/ping_servers.yml`: ICMP inventory
- `targets/sensor_http_endpoints.yml`: Pi-hole and mitmproxy UI
- `targets/practice_http_endpoints.yml`: isolated practice-target HTTP inventory
- `targets/sensor_tcp_endpoints.yml`: mitmproxy proxy listener
- `targets/sensor_dns_endpoints.yml`: Pi-hole DNS listener
- `scripts/python/service_index_assets/service_catalog.json`: operator-facing link and credential source inventory
