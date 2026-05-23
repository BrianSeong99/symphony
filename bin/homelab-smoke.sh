#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MANIFEST="${1:-$ROOT_DIR/config/homelab/symphony.yml}"
CADDY_CONTAINER="${HOMELAB_CADDY_CONTAINER:-homelab-caddy}"

manifest_value() {
  awk -F': ' -v key="$1" '$1 == key {print $2; exit}' "$MANIFEST" | tr -d '"'
}

upstream="$(manifest_value upstream)"
health_path="$(manifest_value health_path)"

if [ -z "$upstream" ] || [ -z "$health_path" ]; then
  echo "homelab smoke: manifest must include upstream and health_path" >&2
  exit 2
fi

docker exec "$CADDY_CONTAINER" wget -qO- "http://${upstream}${health_path}" >/dev/null
echo "homelab smoke: ${upstream}${health_path} returned 2xx from ${CADDY_CONTAINER}"
