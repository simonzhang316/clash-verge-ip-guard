#!/usr/bin/env bash
set -Eeuo pipefail

VPS_IP="${CLAUDE_VPS_IP:-}"
VPS_PORT="${CLAUDE_VPS_PORT:-}"
RESIDENTIAL_IP="${CLAUDE_RESIDENTIAL_IP:-38.45.149.73}"
RESIDENTIAL_PORT="${CLAUDE_RESIDENTIAL_PORT:-23695}"
SOCK="${CLASH_SOCK:-/tmp/verge/verge-mihomo.sock}"
PARAMS_FILE="${CLAUDE_VPS_PARAMS_FILE:-/Users/zhangxinran/Scratch/20260904-bwg/reality_params.txt}"
WRAPPER="${CLAUDE_HEAL_WRAPPER:-/Users/zhangxinran/.local/bin/claude-ip-heal}"
PLIST="${CLAUDE_ENFORCER_PLIST:-/Users/zhangxinran/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist}"
HEAL_BIN="${CLAUDE_HEAL_BIN:-/Users/zhangxinran/.local/bin/claude-ip-heal}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
PLIST_BUDDY_BIN="${PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
LABEL=com.zhangxinran.claude-ip-enforcer
USER_ID="${CLAUDE_CUTOVER_UID:-$(/usr/bin/id -u)}"
ROLLBACK_STARTED=0

log() { printf '[claude-vps-rollback] %s\n' "$*"; }
die() { printf '[claude-vps-rollback] ERROR: %s\n' "$*" >&2; return 1; }

load_vps_endpoint() {
  local endpoint
  endpoint="$("$PYTHON_BIN" - "$PARAMS_FILE" "$VPS_IP" "$VPS_PORT" <<'PY'
import re
import sys

params_path, ip_override, port_override = sys.argv[1:4]
params = {}
with open(params_path) as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*)\s*[:=]\s*(.+?)\s*$", line)
        if match:
            params[match.group(1)] = match.group(2)

server = ip_override or params.get("server", "")
port_text = port_override or params.get("port", "")
if not server or any(char.isspace() for char in server):
    raise SystemExit("VPS server missing or invalid")
try:
    port = int(port_text)
except ValueError:
    raise SystemExit("VPS port missing or invalid")
if not 1 <= port <= 65535:
    raise SystemExit("VPS port out of range")
print(server)
print(port)
PY
)" || die "unable to load VPS endpoint from local params"
  VPS_IP="${endpoint%%$'\n'*}"
  VPS_PORT="${endpoint#*$'\n'}"
}

set_claude_choice() {
  local choice="$1" now
  [[ -S "$SOCK" ]] || die "Clash socket missing"
  "$CURL_BIN" -s --path-as-is --unix-socket "$SOCK" -X PUT \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$choice\"}" http://localhost/proxies/Claude >/dev/null
  now="$($CURL_BIN -s --path-as-is --unix-socket "$SOCK" http://localhost/proxies/Claude | \
    "$PYTHON_BIN" -c 'import json,sys; print((json.load(sys.stdin) or {}).get("now", ""))')"
  [[ "$now" == "$choice" ]] || die "Claude selector change failed"
}

set_wrapper_defaults() {
  local ip="$1" port="$2"
  "$PYTHON_BIN" - "$WRAPPER" "$ip" "$port" <<'PY'
import os
import re
import stat
import sys
import tempfile

path, ip, port = sys.argv[1:4]
with open(path) as f:
    text = f.read()
text, ip_count = re.subn(r'^ip="\$\{1:-[^}]+\}"$', f'ip="${{1:-{ip}}}"', text, count=1, flags=re.M)
text, port_count = re.subn(r'^port="\$\{2:-[^}]+\}"$', f'port="${{2:-{port}}}"', text, count=1, flags=re.M)
if ip_count != 1 or port_count != 1:
    raise SystemExit("heal wrapper defaults not found")
mode = stat.S_IMODE(os.stat(path).st_mode)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f:
    f.write(text)
os.chmod(tmp, mode)
os.replace(tmp, path)
PY
}

set_plist_target() {
  local ip="$1" port="$2"
  "$PLIST_BUDDY_BIN" -c "Set :ProgramArguments:1 $ip" "$PLIST"
  "$PLIST_BUDDY_BIN" -c "Set :ProgramArguments:2 $port" "$PLIST"
}

reload_launch_agent() {
  if "$LAUNCHCTL_BIN" print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
    "$LAUNCHCTL_BIN" bootout "gui/$USER_ID/$LABEL"
  fi
  "$LAUNCHCTL_BIN" bootstrap "gui/$USER_ID" "$PLIST"
}

restore_failed_rollback() {
  local original_rc="$1"
  trap - ERR
  set +e
  if [[ "$ROLLBACK_STARTED" == 1 ]]; then
    set_wrapper_defaults "$VPS_IP" "$VPS_PORT"
    set_plist_target "$VPS_IP" "$VPS_PORT"
    reload_launch_agent
    CLAUDE_MAINTENANCE_APPROVED=1 "$HEAL_BIN" "$VPS_IP" "$VPS_PORT" >/dev/null 2>&1
    set_claude_choice Claude-VPS
    printf '[claude-vps-rollback] ERROR: rollback failed; VPS restoration attempted\n' >&2
  fi
  exit "$original_rc"
}

main() {
  [[ -f "$PARAMS_FILE" ]] || die "VPS params file missing"
  load_vps_endpoint
  [[ -x "$WRAPPER" ]] || die "heal wrapper missing or not executable"
  [[ -x "$HEAL_BIN" ]] || die "heal command missing or not executable"
  [[ -f "$PLIST" ]] || die "enforcer plist missing"
  trap 'restore_failed_rollback $?' ERR
  ROLLBACK_STARTED=1
  set_claude_choice Claude-Residential
  set_wrapper_defaults "$RESIDENTIAL_IP" "$RESIDENTIAL_PORT"
  set_plist_target "$RESIDENTIAL_IP" "$RESIDENTIAL_PORT"
  reload_launch_agent
  CLAUDE_MAINTENANCE_APPROVED=1 "$HEAL_BIN" "$RESIDENTIAL_IP" "$RESIDENTIAL_PORT"
  ROLLBACK_STARTED=0
  trap - ERR
  log "residential rollback applied"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
