#!/bin/sh
set -eu

MAX_REQUESTS="${MAX_REQUESTS:-5}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3}"

echo "Controller started: max_requests=$MAX_REQUESTS interval=${CHECK_INTERVAL}s"

while true; do
  for i in $(seq 1 10); do
    name=$(printf "sxng-%02d" "$i")

    # Skip containers that aren't running (e.g. mid-restart)
    state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null) || continue
    [ "$state" = "running" ] || continue

    # Count search requests since this container's last start.
    # docker logs persists across restarts (same container ID), so
    # --since filters to only the current lifecycle's entries.
    started=$(docker inspect --format '{{.State.StartedAt}}' "$name")
    count=$(docker logs --since "$started" "$name" 2>&1 | grep -c '"GET /search' || true)

    if [ "$count" -ge "$MAX_REQUESTS" ]; then
      echo "$(date -Iseconds) Restarting $name ($count searches)"
      docker restart -t 5 "$name" > /dev/null 2>&1 &
    fi
  done

  sleep "$CHECK_INTERVAL"
done
