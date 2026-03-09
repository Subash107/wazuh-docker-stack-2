#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

if [[ ! -f "$repo_root/.env.example" ]]; then
  echo "Missing .env.example in $repo_root" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$repo_root/.env.example"
set +a

created_files=()

cleanup() {
  docker compose -f "$repo_root/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm single-node_wazuh_logs >/dev/null 2>&1 || true

  for path in "${created_files[@]}"; do
    rm -f "$path"
  done
}
trap cleanup EXIT

ensure_file() {
  local path="$1"
  local value="$2"

  if [[ -f "$path" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$value" > "$path"
  created_files+=("$path")
}

gateway_password="ci-gateway-password"
gateway_hash="$(docker run --rm --entrypoint caddy "$CADDY_IMAGE" hash-password --plaintext "$gateway_password")"

ensure_file "$repo_root/secrets/brevo_smtp_key.txt" "ci-brevo-token"
ensure_file "$repo_root/secrets/gateway_admin_username.txt" "ci-operator"
ensure_file "$repo_root/secrets/gateway_admin_password.txt" "$gateway_password"
ensure_file "$repo_root/secrets/gateway_admin_password_hash.txt" "$gateway_hash"

docker compose -f "$repo_root/docker-compose.yml" config >/dev/null

docker run --rm \
  --entrypoint promtool \
  -v "$repo_root/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$repo_root/alert.rules.yml:/etc/prometheus/alert.rules.yml:ro" \
  -v "$repo_root/targets:/etc/prometheus/targets:ro" \
  "$PROMETHEUS_IMAGE" \
  check config /etc/prometheus/prometheus.yml >/dev/null

docker run --rm \
  --entrypoint amtool \
  -v "$repo_root/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
  "$ALERTMANAGER_IMAGE" \
  check-config /etc/alertmanager/alertmanager.yml >/dev/null

docker run --rm \
  -v "$repo_root/blackbox.yml:/etc/blackbox_exporter/config.yml:ro" \
  "$BLACKBOX_EXPORTER_IMAGE" \
  --config.file=/etc/blackbox_exporter/config.yml \
  --config.check >/dev/null

docker run --rm \
  --entrypoint /bin/sh \
  -e "MONITORING_GATEWAY_HOST=${MONITORING_GATEWAY_HOST}" \
  -v "$repo_root/gateway/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$repo_root/secrets/gateway_admin_username.txt:/run/secrets/gateway_admin_username.txt:ro" \
  -v "$repo_root/secrets/gateway_admin_password_hash.txt:/run/secrets/gateway_admin_password_hash.txt:ro" \
  "$CADDY_IMAGE" \
  -lc 'export GATEWAY_ADMIN_USERNAME=$(cat /run/secrets/gateway_admin_username.txt); export GATEWAY_ADMIN_PASSWORD_HASH=$(cat /run/secrets/gateway_admin_password_hash.txt); caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' >/dev/null

docker volume create single-node_wazuh_logs >/dev/null

docker compose -f "$repo_root/docker-compose.yml" up -d \
  alertmanager \
  blackbox-exporter \
  prometheus \
  monitoring-service-index \
  monitoring-gateway >/dev/null

wait_for_ready() {
  local name="$1"
  local timeout="${2:-180}"
  local elapsed=0

  while (( elapsed < timeout )); do
    local state
    state="$(docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    case "$state" in
      healthy|running)
        return 0
        ;;
      unhealthy|exited|dead)
        docker logs "$name" >&2 || true
        echo "Container $name entered bad state: $state" >&2
        return 1
        ;;
    esac

    sleep 3
    elapsed=$((elapsed + 3))
  done

  docker logs "$name" >&2 || true
  echo "Timed out waiting for $name" >&2
  return 1
}

wait_for_ready alertmanager
wait_for_ready blackbox-exporter
wait_for_ready prometheus
wait_for_ready monitoring-service-index
wait_for_ready monitoring-gateway

curl -fsS "http://127.0.0.1:9115/probe?target=http://monitoring-service-index:9088/healthz&module=http_2xx" | grep -q "probe_success 1"
docker exec monitoring-gateway /bin/sh -lc "wget --no-check-certificate -q -O - https://127.0.0.1:9443/healthz | grep -qx ok"

echo "CI smoke checks completed successfully."
