#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="127.0.0.1"
PORT="8765"

cd "$BASE_DIR"

# Stop previous instance on same port if exists.
OLD_PID="$(lsof -ti tcp:$PORT -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "$OLD_PID" ]]; then
  kill "$OLD_PID" >/dev/null 2>&1 || true
  sleep 0.5
fi

# Rotate the cockpit log at restart if oversized (>20MB), same archive dir
# as the enforcer log rotation (issue S7).
LOG="$BASE_DIR/ip_monitor_server.log"
ARCHIVE_DIR="$HOME/.local/log/archive"
if [[ -f "$LOG" && "$(/usr/bin/stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 20971520 ]]; then
  /bin/mkdir -p "$ARCHIVE_DIR"
  mv "$LOG" "$ARCHIVE_DIR/ip_monitor_server.log.$(date '+%Y%m%d-%H%M%S')" || true
fi

# Expected IP comes from the guard's state.json — no argument needed (ADR-0002).
nohup python3 "$BASE_DIR/ip_monitor_server.py" --host "$HOST" --port "$PORT" \
  > "$BASE_DIR/ip_monitor_server.log" 2>&1 &

echo "Cockpit started: http://$HOST:$PORT"
open "http://$HOST:$PORT" >/dev/null 2>&1 || true
