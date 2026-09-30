#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="${CLAUDE_STATIC_IP:-}"
TARGET_PORT="${CLAUDE_STATIC_PORT:-}"
RESIDENTIAL_IP="${CLAUDE_RESIDENTIAL_IP:-38.45.149.73}"
SOCK="${CLASH_SOCK:-/tmp/verge/verge-mihomo.sock}"
BASE="${CLASH_VERGE_BASE:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
HEAL_BIN="${CLAUDE_HEAL_BIN:-$HOME/.local/bin/claude-ip-heal}"
STATE_DIR="${CLAUDE_GUARD_STATE_DIR:-$HOME/.local/state}"
STATE_FILE="$STATE_DIR/claude-ip-enforcer.state"
FAIL_COUNT_FILE="$STATE_DIR/claude-ip-enforcer.fail_count"
GUARD_STATE_DIR="$STATE_DIR/claude-ip-guard"
GUARD_STATE_JSON="$GUARD_STATE_DIR/state.json"
GUARD_EVENTS_JSONL="$GUARD_STATE_DIR/events.jsonl"
NOTIFY_BIN="${CLAUDE_GUARD_NOTIFY_BIN:-$HOME/claudecode_xinran/scripts/notify-master.sh}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
FAIL_THRESHOLD="${CLAUDE_ENFORCE_FAIL_THRESHOLD:-3}"
ANTHROPIC_URL="${CLAUDE_ANTHROPIC_HEALTH_URL:-https://api.anthropic.com/}"
ANTHROPIC_EXPECTED_STATUS="${CLAUDE_ANTHROPIC_EXPECTED_STATUS:-404}"
MAINTENANCE_GATE_SECONDS="${CLAUDE_MAINTENANCE_GATE_SECONDS:-30}"
FULL_CHAIN_CANDIDATES_CSV="${CLAUDE_FULL_CHAIN_CANDIDATES:-Claude-Residential-JP3,Claude-Residential-JP1,Claude-Residential-SG5,Claude-Residential-SG4}"

OPEN_ON_OK=false
SILENT=false
QUIT_ON_FAIL=true

CURRENT_CHAIN_CANDIDATE="unknown"
ANTHROPIC_RESULT="unknown"
FULL_PATH_IP_RESULT="unknown"
RESIDENTIAL_DIRECT_RESULT="unknown"
FAST_PATH_FAILURE="unknown"

notify_local() {
  local msg="$1"
  $SILENT && return 0
  /usr/bin/osascript -e "display notification \"$msg\" with title \"Claude IP Guard\"" >/dev/null 2>&1 || true
}

notify_master_transition() {
  local msg="$1" dedup_key="$2"
  [[ -x "$NOTIFY_BIN" ]] || return 0
  "$NOTIFY_BIN" -m "$msg" --dedup-key "$dedup_key" --dedup-window 30 >/dev/null 2>&1 || true
}

api_get_group() {
  local group="$1"
  [[ -S "$SOCK" ]] || return 1
  "$CURL_BIN" -s --path-as-is --unix-socket "$SOCK" "http://localhost/proxies/$group" || return 1
}

current_group_choice() {
  local group="$1" out
  out="$(api_get_group "$group" 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | /usr/bin/sed -n 's/.*"now":"\([^"]*\)".*/\1/p'
}

set_group_choice() {
  local group="$1" choice="$2"
  [[ -S "$SOCK" ]] || return 1
  "$CURL_BIN" -s --path-as-is --unix-socket "$SOCK" -X PUT \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$choice\"}" "http://localhost/proxies/$group" >/dev/null
}

claude_group_candidates_ok() {
  local out expected_choice=Claude-VPS
  [[ "$TARGET_IP" == "$RESIDENTIAL_IP" ]] && expected_choice=Claude-Residential
  out="$(api_get_group Claude 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
ok = d.get("now") == sys.argv[1] and d.get("all") == ["Claude-VPS", "Claude-Residential", "REJECT"]
raise SystemExit(0 if ok else 1)
' "$expected_choice" 2>/dev/null
}

claude_residential_group_ok() {
  local out candidate
  out="$(api_get_group Claude-Residential 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  candidate="$(printf '%s' "$out" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
expected = sys.argv[1].split(",")
kind = str(d.get("type", "")).lower()
now = d.get("now")
ok = kind == "fallback" and d.get("all") == expected and now in expected
if ok:
    print(now)
raise SystemExit(0 if ok else 1)
' "$FULL_CHAIN_CANDIDATES_CSV" 2>/dev/null)" || return 1
  CURRENT_CHAIN_CANDIDATE="$candidate"
}

runtime_core_ok() {
  local out
  [[ -S "$SOCK" ]] || return 1
  out="$("$CURL_BIN" -s --unix-socket "$SOCK" http://localhost/configs 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
tun = d.get("tun") or {}
ok = d.get("mode") == "rule" and tun.get("enable") is True and d.get("ipv6") is False
raise SystemExit(0 if ok else 1)
' 2>/dev/null
}

runtime_claude_rules_ok() {
  local rules
  [[ -S "$SOCK" ]] || return 1
  rules="$("$CURL_BIN" -s --unix-socket "$SOCK" http://localhost/rules 2>/dev/null || true)"
  [[ "$rules" == *"anthropic.com"* ]] || return 1
  [[ "$rules" == *"claude.ai"* ]] || return 1
  [[ "$rules" == *"claude.com"* ]] || return 1
  [[ "$rules" == *"clau.de"* ]] || return 1
  [[ "$rules" == *"claudeusercontent.com"* ]] || return 1
  [[ "$rules" == *"claude.exe"* ]] || return 1
}

runtime_claude_guard_ok() {
  runtime_core_ok || return 1
  claude_group_candidates_ok || return 1
  claude_residential_group_ok || return 1
  runtime_claude_rules_ok || return 1
}

anthropic_full_chain_ok() {
  local status
  status="$("$CURL_BIN" -4 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 8 --max-time 15 "$ANTHROPIC_URL" 2>/dev/null)" || {
    ANTHROPIC_RESULT="connect-failed"
    return 1
  }
  ANTHROPIC_RESULT="http-$status"
  [[ "$status" == "$ANTHROPIC_EXPECTED_STATUS" ]]
}

is_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

probe_full_path_ip() {
  local url="$1"
  "$CURL_BIN" -4 -sS --connect-timeout 6 --max-time 10 "$url" 2>/dev/null | /usr/bin/tr -d '\r\n'
}

full_path_ip_status() {
  local ip1 ip2 mismatch=false
  ip1="$(probe_full_path_ip https://api.ipify.org || true)"
  ip2="$(probe_full_path_ip https://ipv4.icanhazip.com || true)"
  FULL_PATH_IP_RESULT="${ip1:-empty},${ip2:-empty}"

  if is_ipv4 "$ip1" && [[ "$ip1" != "$TARGET_IP" ]]; then mismatch=true; fi
  if is_ipv4 "$ip2" && [[ "$ip2" != "$TARGET_IP" ]]; then mismatch=true; fi
  $mismatch && return 2
  [[ "$ip1" == "$TARGET_IP" && "$ip2" == "$TARGET_IP" ]]
}

residential_proxy_auth() {
  "$PYTHON_BIN" - "$BASE/clash-verge.yaml" "$BASE/profiles"/*.yaml <<'PY' 2>/dev/null
import sys
import yaml

for path in sys.argv[1:]:
    try:
        with open(path) as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        continue
    proxies = (data.get("prepend-proxies") or []) + (data.get("proxies") or [])
    for proxy in proxies:
        if not isinstance(proxy, dict):
            continue
        if proxy.get("name") not in {"Claude-Residential-JP3", "Claude-Residential-JP1", "Claude-Residential-SG5", "Claude-Residential-SG4"}:
            continue
        values = [proxy.get(k) for k in ("username", "password", "server", "port")]
        if all(v is not None and str(v) for v in values):
            print(f"{values[0]}:{values[1]}@{values[2]}:{values[3]}")
            raise SystemExit(0)
raise SystemExit(1)
PY
}

residential_socks_direct_ok() {
  local auth ip
  auth="$(residential_proxy_auth)" || {
    RESIDENTIAL_DIRECT_RESULT="credentials-unavailable"
    return 1
  }
  ip="$("$CURL_BIN" -4 -sS --connect-timeout 6 --max-time 10 \
    --socks5-hostname "$auth" https://api.ipify.org 2>/dev/null | /usr/bin/tr -d '\r\n')" || {
    RESIDENTIAL_DIRECT_RESULT="connect-failed"
    return 1
  }
  RESIDENTIAL_DIRECT_RESULT="$ip"
  [[ "$ip" == "$RESIDENTIAL_IP" ]]
}

guard_fast_path_ok() {
  local ip_rc=0
  FAST_PATH_FAILURE="runtime-invariant"
  runtime_claude_guard_ok || return 1
  FAST_PATH_FAILURE="full-chain-anthropic"
  anthropic_full_chain_ok || return 1
  FAST_PATH_FAILURE="full-path-egress-unavailable"
  full_path_ip_status || ip_rc=$?
  case "$ip_rc" in
    0) FAST_PATH_FAILURE="none"; return 0 ;;
    2) FAST_PATH_FAILURE="full-path-egress-mismatch"; return 1 ;;
    *) return 1 ;;
  esac
}

current_state() {
  [[ -f "$STATE_FILE" ]] && /bin/cat "$STATE_FILE" || printf UNKNOWN
}

set_state() {
  printf '%s' "$1" > "$STATE_FILE"
}

current_fail_count() {
  local n=0
  [[ -f "$FAIL_COUNT_FILE" ]] && n="$(/bin/cat "$FAIL_COUNT_FILE" 2>/dev/null || printf 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

set_fail_count() {
  printf '%s' "$1" > "$FAIL_COUNT_FILE"
}

write_guard_state() {
  local status="$1" category="$2" detail="$3"
  "$PYTHON_BIN" - "$GUARD_STATE_JSON" "$status" "$category" "$detail" \
    "$CURRENT_CHAIN_CANDIDATE" "$ANTHROPIC_RESULT" "$FULL_PATH_IP_RESULT" \
    "$RESIDENTIAL_DIRECT_RESULT" "$(current_fail_count)" <<'PY' 2>/dev/null || true
import datetime, json, os, sys, tempfile

(dest, status, category, detail, candidate, anthropic, full_ip,
 direct_socks, fail_count) = sys.argv[1:10]
payload = {
    "status": status,
    "failure_category": category,
    "detail": detail,
    "current_full_chain": candidate,
    "anthropic_probe": anthropic,
    "full_path_egress": full_ip,
    "residential_socks_direct": direct_socks,
    "fail_count": int(fail_count or 0),
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
}
os.makedirs(os.path.dirname(dest), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest))
with os.fdopen(fd, "w") as f:
    json.dump(payload, f, ensure_ascii=False)
os.replace(tmp, dest)
PY
}

append_guard_event() {
  local event_type="$1" detail="$2"
  "$PYTHON_BIN" - "$GUARD_EVENTS_JSONL" "$event_type" "$detail" <<'PY' 2>/dev/null || true
import datetime, json, os, sys
dest, event_type, detail = sys.argv[1:4]
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest, "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "type": event_type,
        "detail": detail,
    }, ensure_ascii=False) + "\n")
PY
}

reject_claude_now() {
  set_group_choice Claude REJECT || return 1
  [[ "$(current_group_choice Claude 2>/dev/null || true)" == REJECT ]]
}

claude_active_connection_count() {
  local out
  [[ -S "$SOCK" ]] || return 1
  out="$("$CURL_BIN" -s --unix-socket "$SOCK" http://localhost/connections 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
count = 0
for conn in d.get("connections", []):
    meta = conn.get("metadata") or {}
    host = str(meta.get("host") or "").lower()
    process = str(meta.get("process") or meta.get("processPath") or "").lower()
    if any(x in host for x in ("anthropic", "claude.ai", "claude.com")) or "claude" in process:
        count += 1
print(count)
' 2>/dev/null
}

maintenance_gate_clear() {
  local elapsed=0 count
  while :; do
    count="$(claude_active_connection_count 2>/dev/null || printf unavailable)"
    [[ "$count" == 0 ]] || return 1
    ((elapsed >= MAINTENANCE_GATE_SECONDS)) && return 0
    /bin/sleep 5
    elapsed=$((elapsed + 5))
  done
}

run_heal() {
  CLAUDE_MAINTENANCE_APPROVED=1 "$HEAL_BIN" "$TARGET_IP" "$TARGET_PORT" >/dev/null 2>&1
}

recover_state_if_needed() {
  local previous count
  previous="$(current_state)"
  count="$(current_fail_count)"
  if [[ "$previous" == OK && "$count" == 0 ]]; then
    return 0
  fi
  set_fail_count 0
  set_state OK
  write_guard_state OK none "full chain and egress verified"
  append_guard_event recovered_ok "full chain and egress verified"
  if [[ "$previous" == BLOCK ]]; then
    notify_master_transition "✅ Claude IP 守护：完整链与固定出口已恢复" claude-guard-recover
  fi
}

block_for_ip_mismatch() {
  residential_socks_direct_ok || true
  if ! reject_claude_now; then
    set_state BLOCK
    write_guard_state BLOCK fail-closed-error "egress mismatch; REJECT selection failed"
    notify_master_transition "🛑 Claude IP 守护：出口不匹配，且 REJECT 切换失败" claude-guard-reject-failed
    return 2
  fi
  set_fail_count "$FAIL_THRESHOLD"
  set_state BLOCK
  write_guard_state BLOCK egress-mismatch "egress mismatch; REJECT verified"
  append_guard_event block_entered "egress mismatch; REJECT verified"
  notify_local "Claude 出口 IP 异常，网络已阻断"
  notify_master_transition "🛑 Claude IP 守护：出口 IP 异常，已验证切到 REJECT" claude-guard-egress-mismatch
  $QUIT_ON_FAIL && /usr/bin/osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1 || true
  return 2
}

handle_availability_failure() {
  local reason="$1" previous count
  previous="$(current_state)"
  count=$(( $(current_fail_count) + 1 ))
  set_fail_count "$count"
  residential_socks_direct_ok || true

  if ((count < FAIL_THRESHOLD)); then
    set_state WARN
    write_guard_state WARN "$reason" "availability failure $count/$FAIL_THRESHOLD"
    [[ "$previous" == WARN ]] || append_guard_event warn_entered "$reason"
    return 1
  fi

  if ! reject_claude_now; then
    set_state BLOCK
    write_guard_state BLOCK fail-closed-error "$reason; REJECT selection failed"
    notify_master_transition "🛑 Claude IP 守护：完整链连续失败，且 REJECT 切换失败" claude-guard-reject-failed
    return 2
  fi

  set_state BLOCK
  write_guard_state BLOCK "$reason" "failure threshold reached; REJECT verified"
  if [[ "$previous" != BLOCK ]]; then
    append_guard_event block_entered "$reason"
    notify_local "Claude 完整链连续失败，网络已阻断"
    notify_master_transition "🛑 Claude IP 守护：完整链连续失败，已验证切到 REJECT" claude-guard-block
  fi
  $QUIT_ON_FAIL && /usr/bin/osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1 || true
  return 2
}

run_enforcer_cycle() {
  local retry_ip_rc=1
  if guard_fast_path_ok; then
    recover_state_if_needed
    $OPEN_ON_OK && /usr/bin/open -a Claude >/dev/null 2>&1 || true
    return 0
  fi

  if [[ "$FAST_PATH_FAILURE" == full-path-egress-mismatch ]]; then
    block_for_ip_mismatch
    return $?
  fi

  if [[ "$FAST_PATH_FAILURE" == runtime-invariant ]]; then
    if maintenance_gate_clear; then
      append_guard_event heal_invoked runtime-invariant
      write_guard_state HEAL runtime-invariant "maintenance gate clear; heal invoked"
      if run_heal && guard_fast_path_ok; then
        recover_state_if_needed
        return 0
      fi
    fi
    handle_availability_failure runtime-invariant
    return $?
  fi

  if [[ "$FAST_PATH_FAILURE" == full-chain-anthropic ]]; then
    /bin/sleep 2
    if anthropic_full_chain_ok; then
      if full_path_ip_status; then
        recover_state_if_needed
        return 0
      else
        retry_ip_rc=$?
      fi
    fi
    case "$retry_ip_rc" in
      2) block_for_ip_mismatch; return $? ;;
    esac
  fi

  handle_availability_failure "$FAST_PATH_FAILURE"
}

main() {
  if [[ ${1:-} != "" && ${1:-} != --* ]]; then
    TARGET_IP="$1"
    shift
  fi
  if [[ ${1:-} != "" && ${1:-} != --* ]]; then
    TARGET_PORT="$1"
    shift
  fi
  for arg in "$@"; do
    case "$arg" in
      --open) OPEN_ON_OK=true ;;
      --silent) SILENT=true ;;
      --no-quit) QUIT_ON_FAIL=false ;;
      *) printf 'Unknown option: %s\n' "$arg" >&2; return 64 ;;
    esac
  done

  if [[ -z "$TARGET_IP" || -z "$TARGET_PORT" ]]; then
    printf 'Target IP/port missing.\n' >&2
    return 11
  fi
  export FULL_CHAIN_CANDIDATES_CSV
  /bin/mkdir -p "$STATE_DIR" "$GUARD_STATE_DIR"

  if guard_fast_path_ok && [[ "$(current_state)" == OK && "$(current_fail_count)" == 0 ]]; then
    # 健康轮也落盘刷新 ts，否则 cockpit 按数据时效误判守护层停摆
    write_guard_state OK none "full chain and egress verified"
    $OPEN_ON_OK && /usr/bin/open -a Claude >/dev/null 2>&1 || true
    return 0
  fi
  run_enforcer_cycle
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
