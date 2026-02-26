#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="$(cd "$(dirname "$0")" && pwd)/logs"
mkdir -p "$LOG_DIR"

echo $$ > "$LOG_DIR/monitor.pid"

STATS_CSV="$LOG_DIR/monitor.csv"
echo "timestamp,container,cpu_pct,mem_usage,mem_limit,mem_pct" > "$STATS_CSV"

while true; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Docker stats for experiment containers
  docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}' \
    $(docker ps --filter "name=sxng-exp-" --format '{{.Names}}' 2>/dev/null) 2>/dev/null | \
  while IFS=',' read -r name cpu mem_usage mem_pct; do
    mem_used=$(echo "$mem_usage" | sed 's/ \/.*//')
    mem_limit=$(echo "$mem_usage" | sed 's/.*\/ //')
    echo "${ts},${name},${cpu},${mem_used},${mem_limit},${mem_pct}" >> "$STATS_CSV"
  done

  # System memory snapshot
  free_out=$(free -m | awk 'NR==2{printf "%s,%s,%s,%s", $2, $3, $4, $7}')
  echo "${ts},_system_mem,${free_out}" >> "$LOG_DIR/system-mem.csv"

  sleep 10
done
