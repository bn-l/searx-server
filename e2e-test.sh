#!/usr/bin/env bash
# E2E test for the SearXNG fleet.
# Runs LOCALLY (client machine) to replicate actual production use.
# Docker management is done via SSH (arrange), HTTP hits the LB
# from here (act/assert) — exactly like real consumers do.
set -euo pipefail

SERVER="sxm"
LB="http://sxm:8080"
INSTANCES=10
THRESHOLD=5          # controller's MAX_REQUESTS
CTRL_INTERVAL=3      # controller's CHECK_INTERVAL

pass=0 fail_count=0

ok()      { pass=$((pass + 1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
nok()     { fail_count=$((fail_count + 1)); printf "  \033[31m✗\033[0m %s\n" "$1"; }
section() { printf "\n\033[1m── %s ──\033[0m\n" "$1"; }

remote() { ssh "$SERVER" "$*"; }

# Check all instances are healthy by asking the server to hit each
# one directly on its local port. Returns 0 when all are up.
all_instances_healthy() {
  local up
  up=$(ssh -T "$SERVER" "for i in \$(seq 1 $INSTANCES); do curl -sf -o /dev/null --max-time 2 http://127.0.0.1:\$((8080+i))/healthz && echo up; done")
  [ "$(echo "$up" | grep -c up)" -eq "$INSTANCES" ]
}

wait_healthy() {
  local timeout=${1:-45}
  for _ in $(seq 1 "$timeout"); do
    all_instances_healthy && return 0
    sleep 1
  done
  return 1
}

########################################
# 1. Arrange — verify infra is up
########################################
section "Instance health"
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  port=$((8080 + i))
  code=$(remote curl -sf -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/healthz") || code=0
  [ "$code" = "200" ] && ok "$name healthy (port $port)" || nok "$name unhealthy (HTTP $code)"
done

section "Controller"
ctrl_state=$(remote docker inspect --format '{{.State.Status}}' sxng-controller 2>/dev/null) || ctrl_state="missing"
[ "$ctrl_state" = "running" ] && ok "sxng-controller running" || nok "sxng-controller not running ($ctrl_state)"

########################################
# 2. Act + Assert — LB search quality
########################################
section "Load balancer"
response=$(curl -s --max-time 15 "$LB/search?q=python+programming&format=json") || response=""
n_results=$(echo "$response" | jq '.results | length' 2>/dev/null) || n_results=0
if [ "$n_results" -gt 0 ]; then
  ok "LB returned $n_results results"
else
  nok "LB returned no results"
fi
engines=$(echo "$response" | jq -c '[.results[].engines[]] | unique' 2>/dev/null) || engines="[]"
echo "$engines" | jq -e 'index("google")' &>/dev/null \
  && ok "Google engine responding" \
  || nok "Google not in results (engines: $engines)"

########################################
# 3. Restart cycle
########################################
section "Restart cycle"

# Arrange — reset all instances and wait for healthy
echo "  Resetting all instances..."
for i in $(seq 1 "$INSTANCES"); do
  remote docker restart -t 3 "$(printf 'sxng-%02d' "$i")" >/dev/null 2>&1 &
done
wait

echo "  Waiting for instances to become healthy..."
if wait_healthy 45; then
  ok "All $INSTANCES instances healthy after reset"
else
  nok "Not all instances healthy after reset"
fi

# Snapshot pre-restart start times
pre_starts=$(mktemp)
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  ts=$(remote docker inspect --format '{{.State.StartedAt}}' "$name" 2>/dev/null)
  echo "$name $ts" >> "$pre_starts"
done

# Act — fire searches in bursts from THIS machine, like real LLM use.
# The MCP tool fires multiple concurrent searches; model that with
# parallel curls in batches. Each response is saved so we can assert
# that searches actually returned results with Google throughout.
total=60
batch=10
burst_dir=$(mktemp -d)
echo "  Sending $total searches through LB (bursts of $batch)..."
for batch_start in $(seq 1 "$batch" "$total"); do
  for s in $(seq "$batch_start" "$((batch_start + batch - 1))"); do
    curl -s --max-time 10 "$LB/search?q=e2e+test+${s}&format=json" -o "$burst_dir/$s.json" &
  done
  wait
done

# Assert — every search in the burst returned results
empty=0
no_google=0
for f in "$burst_dir"/*.json; do
  n=$(jq '.results | length' "$f" 2>/dev/null) || n=0
  [ "$n" -eq 0 ] && empty=$((empty + 1))
  jq -e '[.results[].engines[]] | index("google")' "$f" &>/dev/null || no_google=$((no_google + 1))
done
[ "$empty" -eq 0 ] \
  && ok "All $total burst searches returned results" \
  || nok "$empty/$total burst searches returned 0 results"
[ "$no_google" -le $((total / 5)) ] \
  && ok "Google present in $((total - no_google))/$total burst searches" \
  || nok "Google missing in $no_google/$total burst searches (threshold: $((total / 5)))"
rm -rf "$burst_dir"

# Wait for controller to detect + restart
echo "  Waiting for controller to act..."
sleep $((CTRL_INTERVAL + 10))

# Wait for restarted instances to come back
echo "  Waiting for instances to recover..."
wait_healthy 30 || true

# Assert — check how many were restarted
restarted=0
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  post_ts=$(remote docker inspect --format '{{.State.StartedAt}}' "$name" 2>/dev/null)
  pre_ts=$(grep "^$name " "$pre_starts" | cut -d' ' -f2)
  [ "$post_ts" != "$pre_ts" ] && restarted=$((restarted + 1))
done
rm -f "$pre_starts"

if [ "$restarted" -ge 5 ]; then
  ok "Controller restarted $restarted/$INSTANCES instances"
else
  nok "Only $restarted/$INSTANCES restarted (expected ≥5)"
fi

########################################
# 4. Count reset after restart
########################################
section "Count reset"
all_low=true
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  started=$(remote docker inspect --format '{{.State.StartedAt}}' "$name" 2>/dev/null)
  count=$(remote docker logs --since "$started" "$name" 2>&1 | grep -c '"GET /search' || true)
  if [ "$count" -ge "$THRESHOLD" ]; then
    all_low=false
    nok "$name has $count searches (threshold: $THRESHOLD)"
  fi
done
$all_low && ok "All counts below threshold after restart"

########################################
# Summary
########################################
section "Results"
total_checks=$((pass + fail_count))
printf "  %d/%d passed" "$pass" "$total_checks"
if [ "$fail_count" -gt 0 ]; then
  printf " (\033[31m%d failed\033[0m)\n" "$fail_count"
  exit 1
else
  printf "\n"
fi
