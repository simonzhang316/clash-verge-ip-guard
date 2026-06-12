#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="8765"
LABEL="com.zhangxinran.cockpit"

# If the LaunchAgent owns the cockpit, manual start would just fight its
# KeepAlive. Use launchctl in that case.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo "Cockpit 由 LaunchAgent 管理，请用："
  echo "  launchctl kickstart -k gui/$(id -u)/$LABEL   # 重启"
  echo "  launchctl bootout gui/$(id -u)/$LABEL        # 停止"
  exit 0
fi

cd "$BASE_DIR"

# Stop previous manual instance on same port if exists.
OLD_PID="$(lsof -ti tcp:$PORT -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "$OLD_PID" ]]; then
  kill "$OLD_PID" >/dev/null 2>&1 || true
  sleep 0.5
fi

# Rotate the cockpit access log at restart if oversized (>20MB); the server
# also self-rotates while running (issue S7).
LOG="$BASE_DIR/ip_monitor_server.log"
ARCHIVE_DIR="$HOME/.local/log/archive"
if [[ -f "$LOG" && "$(/usr/bin/stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 20971520 ]]; then
  /bin/mkdir -p "$ARCHIVE_DIR"
  mv "$LOG" "$ARCHIVE_DIR/ip_monitor_server.log.$(date '+%Y%m%d-%H%M%S')" || true
fi

# Expected IP comes from the guard's state.json — no argument needed (ADR-0002).
# Startup lines go to the launchd-style log; access log is self-managed by the server.
/bin/mkdir -p "$HOME/.local/log"
nohup python3 "$BASE_DIR/ip_monitor_server.py" --port "$PORT" \
  > "$HOME/.local/log/cockpit.startup.log" 2>&1 &

sleep 0.5
echo "Cockpit started: http://127.0.0.1:$PORT"
open "http://127.0.0.1:$PORT" >/dev/null 2>&1 || true
