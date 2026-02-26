#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

NUM_INSTANCES=20
BASE_PORT=8081

# Source settings from the production searxng config
SETTINGS_SRC="$SCRIPT_DIR/settings-src/settings.yml"
HOSTNAMES_SRC="$SCRIPT_DIR/settings-src/hostnames-remove.yml"

if [[ ! -f "$SETTINGS_SRC" ]]; then
  echo "ERROR: $SETTINGS_SRC not found. Ensure settings-src/ is rsynced." >&2
  exit 1
fi

# --- Generate per-instance settings directories ---
for i in $(seq -w 1 "$NUM_INSTANCES"); do
  dir="$SCRIPT_DIR/settings/sxng-${i}"
  mkdir -p "$dir"

  secret=$(openssl rand -hex 32)

  # Copy settings, replace secret_key and disable image_proxy
  sed -e "s/secret_key:.*/secret_key: \"${secret}\"/" \
      -e "s/image_proxy:.*/image_proxy: false/" \
      "$SETTINGS_SRC" > "$dir/settings.yml"

  # Copy hostnames blocklist
  cp "$HOSTNAMES_SRC" "$dir/hostnames-remove.yml"
done

echo "Generated settings for $NUM_INSTANCES instances."

# --- Generate docker-compose.yml ---
COMPOSE="$SCRIPT_DIR/docker-compose.yml"

cat > "$COMPOSE" << 'HEADER'
services:
HEADER

for i in $(seq -w 1 "$NUM_INSTANCES"); do
  port=$((BASE_PORT + 10#$i - 1))
  cat >> "$COMPOSE" << EOF
  sxng-${i}:
    container_name: sxng-exp-${i}
    image: docker.io/searxng/searxng:latest
    restart: "no"
    ports:
      - "127.0.0.1:${port}:8080"
    volumes:
      - ./settings/sxng-${i}:/etc/searxng:ro
    environment:
      - UWSGI_WORKERS=1
      - UWSGI_THREADS=2
    deploy:
      resources:
        limits:
          memory: 200M

EOF
done

echo "Generated docker-compose.yml with $NUM_INSTANCES services (ports ${BASE_PORT}-$((BASE_PORT + NUM_INSTANCES - 1)))."
