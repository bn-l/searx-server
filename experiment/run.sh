#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR="/home/bml/searxng-experiment"
SSH_HOST="sxm"

NUM_INSTANCES=20
BASE_PORT=8081

echo "=========================================="
echo "  SearXNG Round-Robin Experiment"
echo "=========================================="
echo ""

# --- 1. Ensure jq is available on the server ---
echo "[1/10] Ensuring jq is installed on server..."
ssh "$SSH_HOST" 'which jq >/dev/null 2>&1 || sudo apt-get install -y jq'
echo "  Done."

# --- 2. Rsync experiment files to server ---
echo "[2/10] Syncing experiment files to server..."
ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR"
rsync -avz --delete \
  --exclude='results/' \
  --exclude='logs/' \
  --exclude='settings/' \
  --exclude='docker-compose.yml' \
  "$SCRIPT_DIR/" "${SSH_HOST}:${REMOTE_DIR}/"
echo "  Done."

# --- 3. Rsync source settings (from production config) ---
echo "[3/10] Syncing source settings..."
ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR/settings-src"
# Copy from the production searxng settings on the server
ssh "$SSH_HOST" "cp /home/bml/searxng/searxng/settings.yml $REMOTE_DIR/settings-src/settings.yml"
ssh "$SSH_HOST" "cp /home/bml/searxng/searxng/hostnames-remove.yml $REMOTE_DIR/settings-src/hostnames-remove.yml"
echo "  Done."

# --- 4. Generate compose + settings ---
echo "[4/10] Generating docker-compose.yml and per-instance settings..."
ssh "$SSH_HOST" "cd $REMOTE_DIR && bash generate-compose.sh"
echo "  Done."

# --- 5. Docker compose up ---
echo "[5/10] Starting $NUM_INSTANCES SearXNG instances..."
ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose up -d"
echo "  Done."

# --- 6. Health check ---
echo "[6/10] Health-checking instances (90s timeout)..."
ssh "$SSH_HOST" bash << 'HEALTHEOF'
set -euo pipefail

REMOTE_DIR="/home/bml/searxng-experiment"
BASE_PORT=8081
NUM_INSTANCES=20
TIMEOUT=90
LOG_DIR="$REMOTE_DIR/logs"
mkdir -p "$LOG_DIR"

LIVE_PORTS="$LOG_DIR/live-ports.txt"
> "$LIVE_PORTS"

# Check all instances in parallel — each one polls until healthy or timeout
check_instance() {
  local port=$1
  local instance=$2
  local start=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
      echo "FAIL $port $instance"
      return
    fi
    if curl -s --max-time 5 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
      echo "OK $port $instance"
      return
    fi
    sleep 2
  done
}

# Launch all checks in background
tmpdir=$(mktemp -d)
for i in $(seq 0 $((NUM_INSTANCES - 1))); do
  port=$((BASE_PORT + i))
  instance="sxng-exp-$(printf '%02d' $((i + 1)))"
  check_instance "$port" "$instance" > "$tmpdir/$port" &
done

# Wait for all
wait

# Collect results
for i in $(seq 0 $((NUM_INSTANCES - 1))); do
  port=$((BASE_PORT + i))
  result=$(cat "$tmpdir/$port")
  status=$(echo "$result" | awk '{print $1}')
  inst=$(echo "$result" | awk '{print $3}')

  if [[ "$status" == "OK" ]]; then
    echo "$port" >> "$LIVE_PORTS"
    printf "  %-16s port:%-5d ✓ healthy\n" "$inst" "$port"
  else
    printf "  %-16s port:%-5d ✗ NOT READY\n" "$inst" "$port"
  fi
done

rm -rf "$tmpdir"

live_count=$(wc -l < "$LIVE_PORTS" | tr -d ' ')
echo ""
echo "  $live_count / $NUM_INSTANCES instances healthy."
HEALTHEOF
echo "  Done."

# --- 7. Start monitor ---
echo "[7/10] Starting resource monitor..."
ssh -f "$SSH_HOST" "cd $REMOTE_DIR && bash monitor.sh </dev/null >/dev/null 2>&1"
sleep 2
ssh "$SSH_HOST" "cat $REMOTE_DIR/logs/monitor.pid 2>/dev/null && echo ' (monitor PID)' || echo '  Warning: monitor may not have started'"
echo "  Done."

# --- 8. Run search test ---
echo "[8/10] Running search test..."
echo ""
ssh "$SSH_HOST" "cd $REMOTE_DIR && bash search-test.sh --delay 2 --rounds 3"
echo ""
echo "  Done."

# --- 9. Cleanup ---
echo "[9/10] Tearing down..."

# Kill monitor
ssh "$SSH_HOST" bash << 'CLEANEOF'
set -euo pipefail
REMOTE_DIR="/home/bml/searxng-experiment"
PID_FILE="$REMOTE_DIR/logs/monitor.pid"
if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "  Monitor (PID $pid) stopped."
fi
CLEANEOF

# Docker compose down
ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose down -v"
echo "  Containers removed."

# --- 10. Fetch results ---
echo "[10/10] Fetching results..."
mkdir -p "$SCRIPT_DIR/results"
rsync -avz "${SSH_HOST}:${REMOTE_DIR}/logs/" "$SCRIPT_DIR/results/"
echo "  Done."

echo ""
echo "=========================================="
echo "  Experiment Complete"
echo "=========================================="
echo ""

if [[ -f "$SCRIPT_DIR/results/summary.txt" ]]; then
  cat "$SCRIPT_DIR/results/summary.txt"
else
  echo "Warning: summary.txt not found in results."
fi
