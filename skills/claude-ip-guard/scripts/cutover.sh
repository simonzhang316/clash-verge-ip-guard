#!/usr/bin/env bash
set -Eeuo pipefail

VPS_IP="${CLAUDE_VPS_IP:-}"
VPS_PORT="${CLAUDE_VPS_PORT:-}"
RESIDENTIAL_IP="${CLAUDE_RESIDENTIAL_IP:-38.45.149.73}"
RESIDENTIAL_PORT="${CLAUDE_RESIDENTIAL_PORT:-23695}"
BASE="${CLASH_VERGE_BASE:-/Users/zhangxinran/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
PARAMS_FILE="${CLAUDE_VPS_PARAMS_FILE:-/Users/zhangxinran/Scratch/20260904-bwg/reality_params.txt}"
BACKUP_ROOT="${CLAUDE_CUTOVER_BACKUP_ROOT:-/Users/zhangxinran/Scratch/20260904-bwg}"
WRAPPER="${CLAUDE_HEAL_WRAPPER:-/Users/zhangxinran/.local/bin/claude-ip-heal}"
PLIST="${CLAUDE_ENFORCER_PLIST:-/Users/zhangxinran/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist}"
HEAL_BIN="${CLAUDE_HEAL_BIN:-/Users/zhangxinran/.local/bin/claude-ip-heal}"
ENFORCER_BIN="${CLAUDE_ENFORCER_BIN:-/Users/zhangxinran/.local/bin/claude-ip-enforce}"
NOTIFY_BIN="${CLAUDE_GUARD_NOTIFY_BIN:-/Users/zhangxinran/claudecode_xinran/scripts/notify-master.sh}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
CLAUDE_BIN="${CLAUDE_BIN:-/Users/zhangxinran/.local/bin/claude}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
PLIST_BUDDY_BIN="${PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
LABEL=com.zhangxinran.claude-ip-enforcer
USER_ID="${CLAUDE_CUTOVER_UID:-$(/usr/bin/id -u)}"
STATE_DIR="${CLAUDE_GUARD_STATE_DIR:-/Users/zhangxinran/.local/state}"
GUARD_STATE_JSON="$STATE_DIR/claude-ip-guard/state.json"
STATE_FILE="$STATE_DIR/claude-ip-enforcer.state"
FAIL_COUNT_FILE="$STATE_DIR/claude-ip-enforcer.fail_count"
MIHOMO_TEST_PID_FILE="${CLAUDE_MIHOMO_TEST_PID_FILE:-/Users/zhangxinran/Scratch/20260904-bwg/mihomo-test.pid}"
STABILITY_TEST_PID_FILE="${CLAUDE_STABILITY_TEST_PID_FILE:-/Users/zhangxinran/Scratch/20260904-bwg/stability-test.pid}"
CHROME_TEST_PID_FILE="${CLAUDE_CHROME_TEST_PID_FILE:-/Users/zhangxinran/Scratch/20260904-bwg/chrome-test.pid}"
ACTIVE_MERGE=
BACKUP_DIR=
ENFORCER_WAS_LOADED=0
MUTATION_STARTED=0

log() { printf '[claude-vps-cutover] %s\n' "$*"; }
warn() { printf '[claude-vps-cutover] WARN: %s\n' "$*" >&2; }
die() { printf '[claude-vps-cutover] ERROR: %s\n' "$*" >&2; return 1; }

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

resolve_active_merge_source() {
  "$PYTHON_BIN" - "$BASE/profiles.yaml" "$BASE/profiles" <<'PY'
import os
import sys
import yaml

profiles_file, profiles_dir = sys.argv[1:3]
with open(profiles_file) as f:
    data = yaml.safe_load(f) or {}
items = [item for item in data.get("items", []) if isinstance(item, dict)]
by_uid = {item.get("uid"): item for item in items}
current = by_uid.get(data.get("current")) or {}
merge_uid = (current.get("option") or {}).get("merge")
merge = by_uid.get(merge_uid) or {}
path = os.path.join(profiles_dir, str(merge.get("file") or ""))
if merge.get("type") == "merge" and os.path.isfile(path):
    print(path)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

backup_file() {
  local src="$1" dst="$2" backup_mode="${3:-600}"
  [[ -f "$src" ]] || die "required backup source missing: $src"
  /bin/cp -p "$src" "$dst"
  /bin/chmod "$backup_mode" "$dst"
}

backup_current_state() {
  local active_merge="$1" ts backup_dir
  ts="$(/bin/date +%Y%m%d-%H%M%S)"
  backup_dir="$BACKUP_ROOT/cutover-backup-$ts"
  /bin/mkdir -p "$BACKUP_ROOT"
  /bin/mkdir -m 700 "$backup_dir"
  backup_file "$BASE/clash-verge.yaml" "$backup_dir/clash-verge.yaml"
  backup_file "$active_merge" "$backup_dir/active-merge.yaml"
  backup_file "$BASE/clash-verge-guard-expanded.yaml" "$backup_dir/clash-verge-guard-expanded.yaml"
  backup_file "$PLIST" "$backup_dir/com.zhangxinran.claude-ip-enforcer.plist"
  backup_file "$WRAPPER" "$backup_dir/claude-ip-heal.wrapper" 700
  printf '%s' "$backup_dir"
}

inject_vps_node() {
  local active_merge="$1"
  "$PYTHON_BIN" - "$PARAMS_FILE" "$active_merge" "$VPS_IP" "$VPS_PORT" <<'PY'
import json
import os
import re
import stat
import sys
import tempfile
import yaml

params_path, merge_path, expected_ip, expected_port = sys.argv[1:5]
params = {}
with open(params_path) as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*)\s*[:=]\s*(.+?)\s*$", line)
        if not match:
            raise SystemExit("invalid VPS params format")
        params[match.group(1)] = match.group(2)

required = {"server", "port", "uuid", "publicKey", "shortId", "sni"}
if not required.issubset(params) or any(not params[key] for key in required):
    raise SystemExit("VPS params incomplete")
try:
    port = int(params["port"])
except ValueError:
    raise SystemExit("invalid VPS port")
if params["server"] != expected_ip or port != int(expected_port):
    raise SystemExit("VPS endpoint does not match cutover target")
with open(merge_path) as f:
    original = f.read()
try:
    data = yaml.safe_load(original) or {}
except yaml.YAMLError:
    raise SystemExit("active merge YAML invalid")
proxies = (data.get("prepend-proxies") or []) + (data.get("proxies") or [])
groups = (data.get("prepend-proxy-groups") or []) + (data.get("proxy-groups") or [])

node = {
    "name": "Claude-VPS",
    "type": "vless",
    "server": params["server"],
    "port": port,
    "uuid": params["uuid"],
    "network": "tcp",
    "udp": True,
    "tls": True,
    "flow": "xtls-rprx-vision",
    "servername": params["sni"],
    "client-fingerprint": "chrome",
    "reality-opts": {"public-key": params["publicKey"], "short-id": params["shortId"]},
}

lines = original.splitlines(keepends=True)
if not any(isinstance(proxy, dict) and proxy.get("name") == "Claude-VPS" for proxy in proxies):
    section = next((i for i, line in enumerate(lines) if line.rstrip("\r\n") == "prepend-proxies:"), None)
    if section is None:
        raise SystemExit("prepend-proxies section missing")
    proxy_item_indent = "  "
    for existing_line in lines[section + 1:]:
        if not existing_line.strip() or existing_line.lstrip().startswith("#"):
            continue
        match = re.match(r"^(\s*)-\s+", existing_line)
        if match:
            proxy_item_indent = match.group(1)
        break
    scalar = lambda value: json.dumps(str(value), ensure_ascii=True)
    node_line = (
        proxy_item_indent + "- { name: 'Claude-VPS', type: vless, server: " + scalar(node["server"])
        + ", port: " + str(node["port"])
        + ", uuid: " + scalar(node["uuid"])
        + ", network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: "
        + scalar(node["servername"])
        + ", client-fingerprint: chrome, reality-opts: { public-key: "
        + scalar(node["reality-opts"]["public-key"])
        + ", short-id: " + scalar(node["reality-opts"]["short-id"])
        + " } }\n"
    )
    lines.insert(section + 1, node_line)

group_start = None
for i, line in enumerate(lines):
    if re.match(r"^\s*-\s*name:\s*['\"]?Claude['\"]?\s*$", line.rstrip("\r\n")):
        group_start = i
        break
if group_start is None:
    raise SystemExit("Claude group missing")

group_indent = len(lines[group_start]) - len(lines[group_start].lstrip(" "))
proxies_line = None
for i in range(group_start + 1, len(lines)):
    text = lines[i].rstrip("\r\n")
    indent = len(lines[i]) - len(lines[i].lstrip(" "))
    if text.strip() and indent <= group_indent and re.match(r"^\s*-\s*name:", text):
        break
    if re.match(r"^\s*proxies:\s*$", text):
        proxies_line = i
        break
if proxies_line is None:
    raise SystemExit("Claude group proxies list missing")

item_start = proxies_line + 1
item_end = item_start
while item_end < len(lines) and re.match(r"^\s+-\s+", lines[item_end]):
    item_end += 1
item_indent = " " * (len(lines[proxies_line]) - len(lines[proxies_line].lstrip(" ")) + 2)
lines[item_start:item_end] = [
    f"{item_indent}- Claude-VPS\n",
    f"{item_indent}- Claude-Residential\n",
    f"{item_indent}- REJECT\n",
]

updated = "".join(lines)
try:
    check = yaml.safe_load(updated) or {}
except yaml.YAMLError:
    raise SystemExit("updated merge YAML invalid")
check_proxies = (check.get("prepend-proxies") or []) + (check.get("proxies") or [])
check_groups = (check.get("prepend-proxy-groups") or []) + (check.get("proxy-groups") or [])
vps = next((proxy for proxy in check_proxies if isinstance(proxy, dict) and proxy.get("name") == "Claude-VPS"), None)
claude = next((group for group in check_groups if isinstance(group, dict) and group.get("name") == "Claude"), None)
if vps is None or claude is None or claude.get("proxies") != ["Claude-VPS", "Claude-Residential", "REJECT"]:
    raise SystemExit("VPS injection validation failed")
if updated == original:
    raise SystemExit(0)

mode = stat.S_IMODE(os.stat(merge_path).st_mode)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(merge_path))
try:
    with os.fdopen(fd, "w") as f:
        f.write(updated)
    os.chmod(tmp, mode)
    os.replace(tmp, merge_path)
except Exception:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

set_wrapper_defaults() {
  "$PYTHON_BIN" - "$WRAPPER" "$VPS_IP" "$VPS_PORT" <<'PY'
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
  "$PLIST_BUDDY_BIN" -c "Set :ProgramArguments:1 $VPS_IP" "$PLIST"
  "$PLIST_BUDDY_BIN" -c "Set :ProgramArguments:2 $VPS_PORT" "$PLIST"
}

reload_launch_agent() {
  if "$LAUNCHCTL_BIN" print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
    "$LAUNCHCTL_BIN" bootout "gui/$USER_ID/$LABEL"
  fi
  "$LAUNCHCTL_BIN" bootstrap "gui/$USER_ID" "$PLIST"
}

restore_failed_cutover() {
  local original_rc="$1"
  trap - ERR
  set +e
  if [[ "$MUTATION_STARTED" == 1 && -n "$BACKUP_DIR" && -n "$ACTIVE_MERGE" ]]; then
    if "$LAUNCHCTL_BIN" print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
      "$LAUNCHCTL_BIN" bootout "gui/$USER_ID/$LABEL" >/dev/null 2>&1
    fi
    /bin/cp -p "$BACKUP_DIR/clash-verge.yaml" "$BASE/clash-verge.yaml"
    /bin/cp -p "$BACKUP_DIR/active-merge.yaml" "$ACTIVE_MERGE"
    /bin/cp -p "$BACKUP_DIR/clash-verge-guard-expanded.yaml" "$BASE/clash-verge-guard-expanded.yaml"
    /bin/cp -p "$BACKUP_DIR/com.zhangxinran.claude-ip-enforcer.plist" "$PLIST"
    /bin/cp -p "$BACKUP_DIR/claude-ip-heal.wrapper" "$WRAPPER"
    if [[ "$ENFORCER_WAS_LOADED" == 1 ]]; then
      "$LAUNCHCTL_BIN" bootstrap "gui/$USER_ID" "$PLIST" >/dev/null 2>&1
    fi
    CLAUDE_MAINTENANCE_APPROVED=1 "$HEAL_BIN" "$RESIDENTIAL_IP" "$RESIDENTIAL_PORT" >/dev/null 2>&1
    "$NOTIFY_BIN" -m "Claude VPS cutover failed; residential configuration restored" >/dev/null 2>&1
    printf '[claude-vps-cutover] ERROR: cutover failed; restoration attempted from %s\n' "$BACKUP_DIR" >&2
  fi
  exit "$original_rc"
}

reset_guard_state() {
  /bin/mkdir -p "$STATE_DIR/claude-ip-guard"
  printf 'UNKNOWN' > "$STATE_FILE"
  printf '0' > "$FAIL_COUNT_FILE"
}

verify_cutover() {
  local ip1 ip2 claude_response status
  ip1="$($CURL_BIN -4 -sS --connect-timeout 6 --max-time 10 https://api.ipify.org | /usr/bin/tr -d '\r\n')"
  ip2="$($CURL_BIN -4 -sS --connect-timeout 6 --max-time 10 https://ipv4.icanhazip.com | /usr/bin/tr -d '\r\n')"
  [[ "$ip1" == "$VPS_IP" && "$ip2" == "$VPS_IP" ]] || die "egress self-check failed"
  log "egress self-check: PASS"

  claude_response="$($CLAUDE_BIN --model claude-fable-5 -p "回复ok")"
  [[ -n "$claude_response" ]] || die "Claude CLI self-check returned an empty response"
  log "Claude CLI self-check: PASS"

  "$ENFORCER_BIN" "$VPS_IP" "$VPS_PORT" --silent
  status="$($PYTHON_BIN - "$GUARD_STATE_JSON" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    print((json.load(f) or {}).get("status", ""))
PY
)"
  [[ "$status" == OK ]] || die "guard state self-check failed"
  log "guard state self-check: PASS"
}

stop_test_process() {
  local pid_file="$1" expected="$2" pid command
  [[ -f "$pid_file" ]] || return 0
  pid="$(/bin/cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"$expected"* ]] || return 0
  /bin/kill "$pid" 2>/dev/null || return 0
  local attempt
  for attempt in 1 2 3 4 5; do
    /bin/kill -0 "$pid" 2>/dev/null || break
    /bin/sleep 1
  done
  if /bin/kill -0 "$pid" 2>/dev/null; then
    warn "test process did not stop: $pid_file"
    return 0
  fi
  log "stopped test process from $pid_file"
}

cleanup_test_processes() {
  stop_test_process "$MIHOMO_TEST_PID_FILE" mihomo
  stop_test_process "$STABILITY_TEST_PID_FILE" stability-test.sh
  stop_test_process "$CHROME_TEST_PID_FILE" "Google Chrome"
}

main() {
  umask 077
  [[ -f "$PARAMS_FILE" ]] || die "VPS params file missing"
  load_vps_endpoint
  [[ -x "$WRAPPER" ]] || die "heal wrapper missing or not executable"
  [[ -x "$HEAL_BIN" ]] || die "heal command missing or not executable"
  [[ -x "$ENFORCER_BIN" ]] || die "enforcer command missing or not executable"
  [[ -x "$NOTIFY_BIN" ]] || die "notify command missing or not executable"
  [[ -x "$CLAUDE_BIN" ]] || die "Claude CLI missing or not executable"
  [[ -f "$PLIST" ]] || die "enforcer plist missing"

  ACTIVE_MERGE="$(resolve_active_merge_source)" || die "active merge source unavailable"
  BACKUP_DIR="$(backup_current_state "$ACTIVE_MERGE")"
  log "backup created: $BACKUP_DIR"
  if "$LAUNCHCTL_BIN" print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
    ENFORCER_WAS_LOADED=1
  fi

  "$NOTIFY_BIN" -m "Claude VPS cutover maintenance is starting"
  trap 'restore_failed_cutover $?' ERR
  MUTATION_STARTED=1
  inject_vps_node "$ACTIVE_MERGE"
  set_wrapper_defaults
  set_plist_target
  reload_launch_agent
  CLAUDE_MAINTENANCE_APPROVED=1 "$HEAL_BIN" "$VPS_IP" "$VPS_PORT"
  reset_guard_state
  verify_cutover
  MUTATION_STARTED=0
  trap - ERR
  cleanup_test_processes
  log "cutover self-checks: PASS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
