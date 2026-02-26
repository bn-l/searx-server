#!/usr/bin/env bash
# E2E test for the SearXNG fleet.
# Runs ON the server via: ssh sxm 'bash -s' < e2e-test.sh
set -euo pipefail

LB="http://100.113.145.41:8080"
INSTANCES=10
THRESHOLD=5          # controller's MAX_REQUESTS
CTRL_INTERVAL=3      # controller's CHECK_INTERVAL

pass=0 fail_count=0

ok()      { pass=$((pass + 1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
nok()     { fail_count=$((fail_count + 1)); printf "  \033[31m✗\033[0m %s\n" "$1"; }
section() { printf "\n\033[1m── %s ──\033[0m\n" "$1"; }

get_start() { docker inspect --format '{{.State.StartedAt}}' "$1" 2>/dev/null; }
get_state() { docker inspect --format '{{.State.Status}}'    "$1" 2>/dev/null; }

search_count() {
  local name=$1
  local started
  started=$(get_start "$name")
  docker logs --since "$started" "$name" 2>&1 | grep -c '"GET /search' || true
}

wait_healthy() {
  local timeout=${1:-45}
  for _ in $(seq 1 "$timeout"); do
    local up=0
    for i in $(seq 1 "$INSTANCES"); do
      curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$((8080 + i))/healthz" 2>/dev/null && up=$((up + 1))
    done
    [ "$up" -eq "$INSTANCES" ] && return 0
    sleep 1
  done
  return 1
}

########################################
# 1. Instance health
########################################
section "Instance health"
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  port=$((8080 + i))
  state=$(get_state "$name") || state="missing"
  if [ "$state" != "running" ]; then
    nok "$name not running ($state)"; continue
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/healthz") || code=0
  [ "$code" = "200" ] && ok "$name healthy (port $port)" || nok "$name unhealthy (HTTP $code)"
done

########################################
# 2. Controller
########################################
section "Controller"
state=$(get_state "sxng-controller") || state="missing"
[ "$state" = "running" ] && ok "sxng-controller running" || nok "sxng-controller not running ($state)"

########################################
# 3. Caddy LB — search quality
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
# 4. Restart cycle
########################################
section "Restart cycle"

# 4a. Reset all instances
echo "  Resetting all instances..."
for i in $(seq 1 "$INSTANCES"); do
  docker restart -t 3 "$(printf 'sxng-%02d' "$i")" >/dev/null 2>&1 &
done
wait

echo "  Waiting for instances to become healthy..."
if wait_healthy 45; then
  ok "All $INSTANCES instances healthy after reset"
else
  nok "Not all instances healthy after reset"
fi

# 4b. Snapshot start times
declare -A pre_starts
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  pre_starts[$name]=$(get_start "$name")
done

# 4c. Fire searches — 60 should give ~6 per instance via round-robin,
#     enough to trigger the threshold (5) on most.
total=60
echo "  Sending $total searches through LB..."
for s in $(seq 1 "$total"); do
  curl -s -o /dev/null --max-time 10 "$LB/search?q=e2e+test+${s}&format=json" || true
  sleep 0.3
done

# 4d. Let controller detect + restart (interval 3s, restart ~5s)
echo "  Waiting for controller to act..."
sleep $((CTRL_INTERVAL + 10))

# 4e. Wait for restarted instances to come back up
wait_healthy 30 || true

# 4f. Count how many instances were restarted
restarted=0
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  post_start=$(get_start "$name")
  [ "$post_start" != "${pre_starts[$name]}" ] && restarted=$((restarted + 1))
done

if [ "$restarted" -ge 5 ]; then
  ok "Controller restarted $restarted/$INSTANCES instances"
else
  nok "Only $restarted/$INSTANCES restarted (expected ≥5)"
fi

########################################
# 5. Counts reset after restart
########################################
section "Count reset"
all_low=true
for i in $(seq 1 "$INSTANCES"); do
  name=$(printf "sxng-%02d" "$i")
  count=$(search_count "$name")
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
