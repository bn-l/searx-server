#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Defaults ---
DELAY=2
ROUNDS=3

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delay) DELAY="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Load queries ---
QUERIES_FILE="$SCRIPT_DIR/queries.txt"
if [[ ! -f "$QUERIES_FILE" ]]; then
  echo "ERROR: queries.txt not found" >&2
  exit 1
fi

mapfile -t QUERIES < <(grep -v '^\s*$' "$QUERIES_FILE")
NUM_QUERIES=${#QUERIES[@]}
echo "Loaded $NUM_QUERIES queries, running $ROUNDS rounds with ${DELAY}s delay."

# --- Discover live instances ---
PORTS_FILE="$SCRIPT_DIR/logs/live-ports.txt"
if [[ ! -f "$PORTS_FILE" ]]; then
  echo "ERROR: logs/live-ports.txt not found. Run health check first." >&2
  exit 1
fi

mapfile -t PORTS < <(grep -v '^\s*$' "$PORTS_FILE")
NUM_INSTANCES=${#PORTS[@]}
echo "Using $NUM_INSTANCES live instances."

if [[ "$NUM_INSTANCES" -eq 0 ]]; then
  echo "ERROR: No live instances found." >&2
  exit 1
fi

# --- Setup logging ---
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
JSONL="$LOG_DIR/search-results.jsonl"
> "$JSONL"

# --- Round-robin search ---
instance_idx=0

for round in $(seq 1 "$ROUNDS"); do
  echo ""
  echo "=== Round $round/$ROUNDS ==="

  for qi in $(seq 0 $((NUM_QUERIES - 1))); do
    query="${QUERIES[$qi]}"
    port="${PORTS[$((instance_idx % NUM_INSTANCES))]}"
    instance_name="sxng-exp-$(printf '%02d' $((port - 8080)))"
    instance_idx=$((instance_idx + 1))

    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # URL-encode the query (pipe through stdin to avoid shell quoting issues)
    encoded_query=$(printf '%s' "$query" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo "$query")

    # Curl the JSON API
    http_code=0
    timed_out=false
    response=""

    response_file=$(mktemp)
    set +e
    http_code=$(curl -s -o "$response_file" -w '%{http_code}' \
      --max-time 20 \
      "http://127.0.0.1:${port}/search?q=${encoded_query}&format=json" 2>/dev/null)
    curl_exit=$?
    set -e

    if [[ "$curl_exit" -eq 28 ]]; then
      timed_out=true
      http_code=0
    elif [[ "$curl_exit" -ne 0 || -z "$http_code" ]]; then
      http_code=0
    fi

    if [[ -f "$response_file" && -s "$response_file" ]]; then
      response=$(cat "$response_file")
    fi
    rm -f "$response_file"

    # Parse response with jq
    result_count=0
    engines="[]"
    unresponsive_engines="[]"
    google_blocked=false

    if [[ -n "$response" && "$http_code" == "200" ]]; then
      result_count=$(echo "$response" | jq '.results | length' 2>/dev/null || echo 0)
      engines=$(echo "$response" | jq -c '[.results[].engines[]] | unique' 2>/dev/null || echo '[]')
      unresponsive_engines=$(echo "$response" | jq -c '[.unresponsive_engines[]?] // []' 2>/dev/null || echo '[]')

      # Check if google is in unresponsive_engines
      if echo "$unresponsive_engines" | jq -e 'map(select(. == "google")) | length > 0' &>/dev/null; then
        google_blocked=true
      fi
    fi

    # Write JSONL entry
    jq -n -c \
      --arg ts "$ts" \
      --argjson round "$round" \
      --arg instance "$instance_name" \
      --argjson port "$port" \
      --arg query "$query" \
      --argjson http_code "$http_code" \
      --argjson result_count "$result_count" \
      --argjson engines "$engines" \
      --argjson unresponsive "$unresponsive_engines" \
      --argjson google_blocked "$google_blocked" \
      --argjson timed_out "$timed_out" \
      '{ts:$ts, round:$round, instance:$instance, port:$port, query:$query,
        http_code:$http_code, result_count:$result_count, engines:$engines,
        unresponsive_engines:$unresponsive, google_blocked:$google_blocked,
        timed_out:$timed_out}' >> "$JSONL"

    # Live output
    status="OK"
    [[ "$timed_out" == "true" ]] && status="TIMEOUT"
    [[ "$google_blocked" == "true" ]] && status="GOOGLE_BLOCKED"
    [[ "$http_code" == "0" && "$timed_out" == "false" ]] && status="CONN_FAIL"

    printf "[R%d Q%02d] %-16s port:%-5s results:%-4s status:%s  %s\n" \
      "$round" "$((qi + 1))" "$instance_name" "$port" "$result_count" "$status" "$query"

    sleep "$DELAY"
  done
done

echo ""
echo "=== Search complete. Generating summary... ==="

# --- Generate summary ---
SUMMARY="$LOG_DIR/summary.txt"
{
  echo "============================================"
  echo "  SearXNG 20-Instance Round-Robin Results"
  echo "============================================"
  echo ""
  echo "Configuration:"
  echo "  Instances:  $NUM_INSTANCES"
  echo "  Queries:    $NUM_QUERIES"
  echo "  Rounds:     $ROUNDS"
  echo "  Delay:      ${DELAY}s"
  echo "  Total searches: $(wc -l < "$JSONL" | tr -d ' ')"
  echo ""

  echo "--- Aggregate ---"
  total=$(jq -s 'length' "$JSONL")
  google_ok=$(jq -s '[.[] | select(.google_blocked == false and .timed_out == false and .http_code == 200)] | length' "$JSONL")
  google_blocked_count=$(jq -s '[.[] | select(.google_blocked == true)] | length' "$JSONL")
  timeouts=$(jq -s '[.[] | select(.timed_out == true)] | length' "$JSONL")
  conn_fails=$(jq -s '[.[] | select(.http_code == 0 and .timed_out == false)] | length' "$JSONL")

  echo "  Total searches:         $total"
  echo "  Successful (HTTP 200):  $google_ok"
  echo "  Google blocked:         $google_blocked_count"
  echo "  Timeouts:               $timeouts"
  echo "  Connection failures:    $conn_fails"
  echo ""

  echo "--- Per-Instance Breakdown ---"
  printf "  %-18s  %-8s  %-8s  %-14s  %-10s\n" "Instance" "Total" "Success" "Google-Blocked" "First-Block"

  jq -s -r '
    group_by(.instance) | sort_by(.[0].instance) | .[] |
    . as $group |
    $group[0].instance as $name |
    ($group | length) as $total |
    ([$group[] | select(.google_blocked == false and .timed_out == false and .http_code == 200)] | length) as $ok |
    ([$group[] | select(.google_blocked == true)] | length) as $blocked |
    (
      [$group | to_entries[] | select(.value.google_blocked == true)] |
      if length > 0 then (.[0].key + 1 | tostring) else "-" end
    ) as $first_block |
    "  \($name)  \($total)        \($ok)        \($blocked)              \($first_block)"
  ' "$JSONL" 2>/dev/null || echo "  (could not parse per-instance data)"

  echo ""
  echo "--- Engine Health ---"
  echo "  Engines that appeared in results:"
  jq -s '[.[].engines[]?] | group_by(.) | map({engine: .[0], count: length}) | sort_by(-.count) | .[] | "    \(.engine): \(.count)"' "$JSONL" 2>/dev/null | sed 's/"//g' || echo "    (none)"
  echo ""
  echo "  Engines marked unresponsive (across all searches):"
  jq -s '[.[].unresponsive_engines[]?] | group_by(.) | map({engine: .[0], count: length}) | sort_by(-.count) | .[] | "    \(.engine): \(.count) times"' "$JSONL" 2>/dev/null | sed 's/"//g' || echo "    (none)"

  echo ""
  echo "--- Timeline (first 10 Google blocks) ---"
  jq -s '[to_entries[] | select(.value.google_blocked == true)] | sort_by(.key) | .[:10] | .[] |
    "  Search #\(.key+1): \(.value.ts) \(.value.instance) — \(.value.query)"' "$JSONL" 2>/dev/null | sed 's/"//g' || echo "  (no blocks observed)"

} > "$SUMMARY"

cat "$SUMMARY"
echo ""
echo "Full log: $JSONL"
echo "Summary:  $SUMMARY"
