#!/usr/bin/env bash
set -euo pipefail

project_root=""
force_render_dashboard_config="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      project_root="$2"
      shift 2
      ;;
    --force-render-dashboard-config)
      force_render_dashboard_config="true"
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Pass docker compose arguments after the script name, for example: up -d or config" >&2
  exit 1
fi

if [[ -z "$project_root" ]]; then
  project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

wazuh_root="$project_root/wazuh-docker-stack"
single_node_root="$wazuh_root/single-node"
env_path="$wazuh_root/.env"
env_example_path="$wazuh_root/.env.example"
secret_root="$wazuh_root/secrets"

read_secret() {
  local path="$1"
  local env_name="$2"
  local required="${3:-false}"

  if [[ -f "$path" ]]; then
    tr -d '\r\n' < "$path"
    return 0
  fi

  local env_value="${!env_name:-}"
  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
    return 0
  fi

  if [[ "$required" == "true" ]]; then
    echo "Missing secret value. Populate $path or set $env_name." >&2
    exit 1
  fi

  printf ''
}

load_env_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" != *=* ]]; then
      continue
    fi

    local name="${line%%=*}"
    local value="${line#*=}"
    export "${name}"="${value}"
  done < "$path"
}

render_dashboard_config() {
  local example_path="$single_node_root/config/wazuh_dashboard/wazuh.yml.example"
  local target_path="$single_node_root/config/wazuh_dashboard/wazuh.yml"
  local api_password="$1"

  if [[ ! -f "$example_path" ]]; then
    echo "Missing Wazuh dashboard config example: $example_path" >&2
    exit 1
  fi

  if [[ -f "$target_path" && "$force_render_dashboard_config" != "true" ]] && ! grep -q 'CHANGE_ME' "$target_path"; then
    return 0
  fi

  local escaped_password
  escaped_password="$(printf '%s' "$api_password" | sed -e 's/[\/&]/\\&/g' -e 's/"/\\"/g')"
  sed "s/password: \"CHANGE_ME\"/password: \"$escaped_password\"/" "$example_path" > "$target_path"
}

if [[ -f "$env_path" ]]; then
  load_env_file "$env_path"
else
  load_env_file "$env_example_path"
fi

export INDEXER_PASSWORD
INDEXER_PASSWORD="$(read_secret "$secret_root/indexer_password.txt" "INDEXER_PASSWORD" "true")"
export API_PASSWORD
API_PASSWORD="$(read_secret "$secret_root/api_password.txt" "API_PASSWORD" "true")"
export DASHBOARD_PASSWORD
DASHBOARD_PASSWORD="$(read_secret "$secret_root/dashboard_password.txt" "DASHBOARD_PASSWORD" "true")"

render_dashboard_config "$API_PASSWORD"

cd "$single_node_root"
docker compose "$@"
