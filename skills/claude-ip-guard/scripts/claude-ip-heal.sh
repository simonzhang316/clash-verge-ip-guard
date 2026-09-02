#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="${1:-${CLAUDE_STATIC_IP:-}}"
TARGET_PORT="${2:-${CLAUDE_STATIC_PORT:-}}"
BASE="${CLASH_VERGE_BASE:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
SOCK="${CLASH_SOCK:-/tmp/verge/verge-mihomo.sock}"
TS="$(date +%Y%m%d-%H%M%S)"

log() { printf '[claude-ip-heal] %s\n' "$*"; }
warn() { printf '[claude-ip-heal] WARN: %s\n' "$*" >&2; }
err() { printf '[claude-ip-heal] ERROR: %s\n' "$*" >&2; }

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

trim_left() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "$s"
}

file_contains() {
  local needle="$1"
  local file="$2"
  if has_cmd rg; then
    rg -q --fixed-strings "$needle" "$file"
  else
    grep -Fq -- "$needle" "$file"
  fi
}

file_matches_regex() {
  local pattern="$1"
  local file="$2"
  if has_cmd rg; then
    rg -q -e "$pattern" "$file"
  else
    grep -Eq -- "$pattern" "$file"
  fi
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    ((o >= 0 && o <= 255)) || return 1
  done
}

extract_ipv4() {
  local raw="$1"
  local ip
  if has_cmd rg; then
    ip="$(printf '%s' "$raw" | rg -o -m1 '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)"
  else
    ip="$(printf '%s' "$raw" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
  fi
  printf '%s' "$ip"
}

probe_ip_direct() {
  local raw ip url
  for url in "$@"; do
    raw="$(curl -4 -s --max-time 10 "$url" || true)"
    ip="$(extract_ipv4 "$raw")"
    if is_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

probe_ip_via_socks() {
  local proxy_auth="$1"
  shift
  local raw ip url
  for url in "$@"; do
    raw="$(curl -4 -s --max-time 12 --socks5-hostname "$proxy_auth" "$url" || true)"
    ip="$(extract_ipv4 "$raw")"
    if is_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

list_yaml_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  if has_cmd rg; then
    rg --files "$dir" -g '*.yaml'
  else
    find "$dir" -type f -name '*.yaml' | sort
  fi
}

resolve_active_merge_source() {
  local profiles_file="$BASE/profiles.yaml"
  [[ -f "$profiles_file" ]] || return 1
  /usr/bin/python3 - "$profiles_file" "$BASE/profiles" <<'PY' 2>/dev/null
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

validate_full_chain_topology() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  /usr/bin/python3 - "$file" <<'PY' 2>/dev/null
import sys
import yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
proxies = (data.get("prepend-proxies") or []) + (data.get("proxies") or [])
groups = (data.get("prepend-proxy-groups") or []) + (data.get("proxy-groups") or [])
proxy_by_name = {p.get("name"): p for p in proxies if isinstance(p, dict)}
group_by_name = {g.get("name"): g for g in groups if isinstance(g, dict)}

expected = {
    "Claude-Residential-JP3": "JP3-HY2",
    "Claude-Residential-JP1": "JP1-HY2",
    "Claude-Residential-SG5": "SG5-HY2",
    "Claude-Residential-SG4": "SG4-HY2",
}
for name, dialer in expected.items():
    proxy = proxy_by_name.get(name) or {}
    if proxy.get("type") != "socks5" or proxy.get("dialer-proxy") != dialer:
        raise SystemExit(1)
    if not all(proxy.get(k) is not None for k in ("server", "port", "username", "password")):
        raise SystemExit(1)

residential = group_by_name.get("Claude-Residential") or {}
claude = group_by_name.get("Claude") or {}
ok = (
    residential.get("type") == "fallback"
    and residential.get("proxies") == list(expected)
    and residential.get("url") == "https://api.anthropic.com/"
    and residential.get("interval") == 15
    and residential.get("lazy") is False
    and residential.get("max-failed-times") == 2
    and residential.get("expected-status") == 404
    and claude.get("type") == "select"
    and claude.get("proxies") == ["Claude-Residential", "REJECT"]
    and "Claude-Tunnel" not in group_by_name
)
raise SystemExit(0 if ok else 1)
PY
}

repair_full_chain_topology() {
  local file="$1" tmp mode
  [[ -f "$file" ]] || return 1
  mode="$(/usr/bin/stat -f %Lp "$file" 2>/dev/null || printf 600)"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"

  if ! /usr/bin/python3 - "$file" "$tmp" "$TARGET_IP" "$TARGET_PORT" <<'PY'
import sys
import yaml

src, dst, target_ip, target_port = sys.argv[1:5]
with open(src) as f:
    data = yaml.safe_load(f) or {}

proxy_key = "prepend-proxies" if "prepend-proxies" in data else "proxies"
group_key = "prepend-proxy-groups" if "prepend-proxy-groups" in data else "proxy-groups"
proxies = [p for p in (data.get(proxy_key) or []) if isinstance(p, dict)]
groups = [g for g in (data.get(group_key) or []) if isinstance(g, dict)]

credential_source = next(
    (p for p in proxies if str(p.get("name", "")).startswith("Claude-Residential")),
    None,
)
if credential_source is None:
    raise SystemExit("Claude residential credentials not found")

credentials = {
    "type": "socks5",
    "server": target_ip,
    "port": int(target_port),
    "username": credential_source.get("username"),
    "password": credential_source.get("password"),
    "udp": True,
}
if not credentials["username"] or not credentials["password"]:
    raise SystemExit("Claude residential credentials incomplete")

managed_proxies = [
    {"name": "Claude-Residential-JP3", **credentials, "dialer-proxy": "JP3-HY2"},
    {"name": "Claude-Residential-JP1", **credentials, "dialer-proxy": "JP1-HY2"},
    {"name": "Claude-Residential-SG5", **credentials, "dialer-proxy": "SG5-HY2"},
    {"name": "Claude-Residential-SG4", **credentials, "dialer-proxy": "SG4-HY2"},
]
proxies = [p for p in proxies if not str(p.get("name", "")).startswith("Claude-Residential")]
data[proxy_key] = managed_proxies + proxies

managed_groups = [
    {
        "name": "Claude-Residential",
        "type": "fallback",
        "proxies": [
            "Claude-Residential-JP3",
            "Claude-Residential-JP1",
            "Claude-Residential-SG5",
            "Claude-Residential-SG4",
        ],
        "url": "https://api.anthropic.com/",
        "interval": 15,
        "lazy": False,
        "max-failed-times": 2,
        "expected-status": 404,
    },
    {
        "name": "Claude",
        "type": "select",
        "proxies": ["Claude-Residential", "REJECT"],
    },
]
managed_names = {"Claude", "Claude-Residential", "Claude-Tunnel"}
groups = [g for g in groups if g.get("name") not in managed_names]
data[group_key] = managed_groups + groups

with open(dst, "w") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
PY
  then
    rm -f "$tmp"
    return 1
  fi

  /bin/chmod "$mode" "$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  cp -p "$file" "$file.bak-$TS"
  mv "$tmp" "$file"
  HEAL_CHANGED=$((HEAL_CHANGED + 1))
  log "full-chain-topology-repaired: $file"
}

api_get_proxy_group() {
  local group="$1"
  [[ -S "$SOCK" ]] || return 1
  curl --unix-socket "$SOCK" -s --path-as-is "http://localhost/proxies/$group" || return 1
}

proxy_group_now() {
  local group="$1"
  local out
  out="$(api_get_proxy_group "$group" 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | sed -n 's/.*"now":"\([^"]*\)".*/\1/p'
}

set_proxy_group_choice() {
  local group="$1"
  local choice="$2"
  [[ -S "$SOCK" ]] || return 1

  curl --unix-socket "$SOCK" -s --path-as-is -X PUT -H 'Content-Type: application/json' \
    -d "{\"name\":\"$choice\"}" "http://localhost/proxies/$group" >/dev/null || return 1

  [[ "$(proxy_group_now "$group" || true)" == "$choice" ]]
}

extract_residential_proxy_map() {
  local f line
  local files=()
  [[ -f "$BASE/clash-verge.yaml" ]] && files+=("$BASE/clash-verge.yaml")
  [[ -f "$BASE/clash-verge-check.yaml" ]] && files+=("$BASE/clash-verge-check.yaml")
  if [[ -d "$BASE/profiles" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(list_yaml_files "$BASE/profiles")
  fi

  for f in "${files[@]}"; do
    while IFS= read -r line; do
      if [[ "$line" == *"Claude-Residential"* && "$line" == *"server:"* && "$line" == *"port:"* && "$line" == *"username:"* && "$line" == *"password:"* ]]; then
        line="$(trim_left "$line")"
        line="${line#- }"
        line="$(printf '%s' "$line" | sed -E "s/server: [^,}]+/server: $TARGET_IP/; s/port: [0-9]+/port: $TARGET_PORT/")"
        printf '%s' "$line"
        return 0
      fi
    done < "$f"
  done

  return 1
}

ensure_empty_merge_templates_have_claude() {
  local proxy_map
  proxy_map="$(extract_residential_proxy_map || true)"
  if [[ -z "$proxy_map" ]]; then
    warn "cannot find Claude-Residential credentials in existing configs; skip merge template bootstrap"
    return 0
  fi

  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    file_contains "Profile Enhancement Merge Template for Clash Verge" "$f" || continue
    file_contains "Claude-Residential" "$f" && continue

    cp "$f" "$f.bak-$TS"
    # bootstrap 产物是保底直连版:剥掉 dialer-proxy(链式引用订阅组名,灾难恢复
    # 场景下订阅未知,带上会造成组引用断链);常规链式态由 merge 源 + Verge 管理
    local proxy_map_bare
    proxy_map_bare="$(printf '%s' "$proxy_map" | sed -E 's/,[[:space:]]*dialer-proxy:[[:space:]]*[^,}]+//')"
    cat > "$f" <<EOF
# Profile Enhancement Merge Template for Clash Verge

prepend-proxies:
  - $proxy_map_bare

prepend-proxy-groups:
  - name: Claude
    type: select
    proxies:
      - Claude-Residential

prepend-rules:
  - 'DOMAIN,ifconfig.me,Claude'
  - 'DOMAIN-SUFFIX,ping0.cc,Claude'
  - 'DOMAIN,api.ipify.org,Claude'
  - 'DOMAIN,ipv4.icanhazip.com,Claude'
  - 'DOMAIN-SUFFIX,ip.sb,Claude'
  - 'PROCESS-NAME,curl,Claude'
  - 'PROCESS-NAME,claude.exe,Claude'
  - 'PROCESS-NAME,claude,Claude'
  - 'DOMAIN-SUFFIX,anthropic.com,Claude'
  - 'DOMAIN-SUFFIX,claude.ai,Claude'
  - 'DOMAIN-SUFFIX,claude.com,Claude'
  - 'DOMAIN-SUFFIX,clau.de,Claude'
  - 'DOMAIN-SUFFIX,claudeusercontent.com,Claude'
  - 'DOMAIN-SUFFIX,modelcontextprotocol.io,Claude'
  - 'DOMAIN,anthropic.statuspage.io,Claude'
  - 'IP-CIDR,160.79.104.0/21,Claude,no-resolve'
  - 'IP-CIDR6,2607:6bc0::/48,Claude,no-resolve'
  - 'IP-CIDR,$TARGET_IP/32,DIRECT,no-resolve'
EOF
    log "bootstrapped-merge-template: $f"
  done < <(list_yaml_files "$BASE/profiles")
}

ensure_full_config_has_claude() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  file_contains "proxies:" "$file" || return 0
  file_contains "proxy-groups:" "$file" || return 0
  file_contains "rules:" "$file" || return 0

  local proxy_map server port user pass
  proxy_map="$(extract_residential_proxy_map || true)"
  [[ -n "$proxy_map" ]] || return 0

  server="$(printf '%s' "$proxy_map" | sed -E "s/.*server: ([^,}]+).*/\\1/")"
  port="$(printf '%s' "$proxy_map" | sed -E "s/.*port: ([0-9]+).*/\\1/")"
  user="$(printf '%s' "$proxy_map" | sed -E "s/.*username: ([^,}]+).*/\\1/")"
  pass="$(printf '%s' "$proxy_map" | sed -E "s/.*password: ([^,}]+).*/\\1/")"
  [[ -n "$server" && -n "$port" && -n "$user" && -n "$pass" ]] || return 0

  local flags has_proxy has_group has_rule
  flags="$(awk '
    BEGIN { sec=""; has_proxy=0; has_group=0; has_rule=0 }
    /^proxies:[[:space:]]*$/ { sec="proxies"; next }
    /^proxy-groups:[[:space:]]*$/ { sec="groups"; next }
    /^rules:[[:space:]]*$/ { sec="rules"; next }
    /^rule-providers:[[:space:]]*$/ {
      if (sec == "groups") sec="after-groups";
      next
    }
    {
      if (sec == "proxies" && $0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*'\''?Claude-Residential'\''?[[:space:]]*$/) has_proxy=1
      if (sec == "groups" && $0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*'\''?Claude'\''?[[:space:]]*$/) has_group=1
      if (sec == "rules" && index($0, "DOMAIN-SUFFIX,anthropic.com,Claude") > 0) has_rule=1
    }
    END { print has_proxy, has_group, has_rule }
  ' "$file")"
  has_proxy="$(printf '%s' "$flags" | awk '{print $1}')"
  has_group="$(printf '%s' "$flags" | awk '{print $2}')"
  has_rule="$(printf '%s' "$flags" | awk '{print $3}')"

  if [[ "$has_proxy" -eq 1 && "$has_group" -eq 1 && "$has_rule" -eq 1 ]]; then
    return 0
  fi

  cp "$file" "$file.bak-$TS"
  local tmp
  tmp="$(mktemp)"

  awk \
    -v has_proxy="$has_proxy" \
    -v has_group="$has_group" \
    -v has_rule="$has_rule" \
    -v ip="$TARGET_IP" \
    -v server="$server" \
    -v port="$port" \
    -v user="$user" \
    -v pass="$pass" \
    '
  BEGIN {
    inserted_proxy = 0
    inserted_group = 0
    inserted_rule = 0
  }
  {
    if ($0 ~ /^proxy-groups:[[:space:]]*$/ && has_proxy == 0 && inserted_proxy == 0) {
      print "- name: Claude-Residential"
      print "  type: socks5"
      print "  server: " server
      print "  port: " port
      print "  username: " user
      print "  password: " pass
      print "  udp: true"
      inserted_proxy = 1
    }

    if (($0 ~ /^rule-providers:[[:space:]]*$/ || $0 ~ /^rules:[[:space:]]*$/) && has_group == 0 && inserted_group == 0) {
      print "- name: Claude"
      print "  type: select"
      print "  proxies:"
      print "  - Claude-Residential"
      inserted_group = 1
    }

    print $0

    if ($0 ~ /^rules:[[:space:]]*$/ && has_rule == 0 && inserted_rule == 0) {
      print "- DOMAIN,ifconfig.me,Claude"
      print "- DOMAIN-SUFFIX,ping0.cc,Claude"
      print "- DOMAIN,api.ipify.org,Claude"
      print "- DOMAIN,ipv4.icanhazip.com,Claude"
      print "- DOMAIN-SUFFIX,ip.sb,Claude"
      print "- PROCESS-NAME,curl,Claude"
      print "- PROCESS-NAME,claude.exe,Claude"
      print "- PROCESS-NAME,claude,Claude"
      print "- DOMAIN-SUFFIX,anthropic.com,Claude"
      print "- DOMAIN-SUFFIX,claude.ai,Claude"
      print "- DOMAIN-SUFFIX,claude.com,Claude"
      print "- DOMAIN-SUFFIX,clau.de,Claude"
      print "- DOMAIN-SUFFIX,claudeusercontent.com,Claude"
      print "- DOMAIN-SUFFIX,modelcontextprotocol.io,Claude"
      print "- DOMAIN,anthropic.statuspage.io,Claude"
      print "- IP-CIDR,160.79.104.0/21,Claude,no-resolve"
      print "- IP-CIDR6,2607:6bc0::/48,Claude,no-resolve"
      print "- IP-CIDR," ip "/32,DIRECT,no-resolve"
      inserted_rule = 1
    }
  }
  ' "$file" > "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
    log "injected-claude-core: $file"
    HEAL_CHANGED=$((HEAL_CHANGED + 1))
  else
    rm -f "$tmp"
  fi
}

resolve_doggo_profile_file() {
  local profiles_file="$BASE/profiles.yaml"
  [[ -f "$profiles_file" ]] || return 1

  local doggo_name doggo_file
  doggo_name=""
  doggo_file=""
  while IFS= read -r line; do
    case "$line" in
      "  name: 狗狗加速.com")
        doggo_name="狗狗加速.com"
        ;;
      "  file: "*)
        if [[ "$doggo_name" == "狗狗加速.com" ]]; then
          doggo_file="${line#  file: }"
          break
        fi
        ;;
      "  updated:"*)
        doggo_name=""
        ;;
    esac
  done < "$profiles_file"

  [[ -n "$doggo_file" ]] || return 1
  [[ -f "$BASE/profiles/$doggo_file" ]] || return 1
  printf '%s' "$BASE/profiles/$doggo_file"
}

extract_doggo_fallback_maps() {
  local doggo_file
  doggo_file="$(resolve_doggo_profile_file || true)"
  [[ -n "$doggo_file" ]] || return 1

  local lines=()
  if has_cmd rg; then
    while IFS= read -r l; do lines+=("$l"); done < <(rg -N "^[[:space:]]*-[[:space:]]*\\{ name: .*AnyTLS.*type: anytls" "$doggo_file" | head -n 3)
  else
    while IFS= read -r l; do lines+=("$l"); done < <(grep -E "^[[:space:]]*-[[:space:]]*\{ name: .*AnyTLS.*type: anytls" "$doggo_file" | head -n 3)
  fi

  [[ ${#lines[@]} -ge 3 ]] || return 1

  local i line
  for i in 1 2 3; do
    line="$(trim_left "${lines[$((i-1))]}")"
    line="${line#- }"
    line="$(printf '%s' "$line" | sed -E "s/name: [^,]+/name: Doggo-Fallback-${i}/")"
    printf '%s\n' "$line"
  done
}

ensure_full_config_has_doggo_fallback() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  file_contains "proxies:" "$file" || return 0
  file_contains "proxy-groups:" "$file" || return 0
  file_contains "rules:" "$file" || return 0

  local has_proxy has_group
  has_proxy=0
  has_group=0
  if awk '
    BEGIN { sec="" ; found=0 }
    /^proxies:[[:space:]]*$/ { sec="proxies"; next }
    /^proxy-groups:[[:space:]]*$/ { sec="groups"; next }
    /^rule-providers:[[:space:]]*$/ { sec="rp"; next }
    /^rules:[[:space:]]*$/ { sec="rules"; next }
    sec=="proxies" && /name:[[:space:]]*Doggo-Fallback-1/ { found=1 }
    END { exit(found?0:1) }
  ' "$file"; then
    has_proxy=1
  fi

  if awk '
    BEGIN { sec="" ; found=0 }
    /^proxy-groups:[[:space:]]*$/ { sec="groups"; next }
    /^rule-providers:[[:space:]]*$/ { sec="rp"; next }
    /^rules:[[:space:]]*$/ { sec="rules"; next }
    sec=="groups" && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*狗狗加速\.com[[:space:]]*$/ { found=1 }
    END { exit(found?0:1) }
  ' "$file"; then
    has_group=1
  fi

  if [[ "$has_proxy" -eq 1 && "$has_group" -eq 1 ]]; then
    return 0
  fi

  local maps=()
  while IFS= read -r m; do maps+=("$m"); done < <(extract_doggo_fallback_maps || true)
  if [[ ${#maps[@]} -lt 3 ]]; then
    warn "cannot extract doggo fallback proxies; skip doggo merge for $file"
    return 0
  fi

  cp "$file" "$file.bak-$TS"
  local tmp
  tmp="$(mktemp)"

  awk \
    -v has_proxy="$has_proxy" \
    -v has_group="$has_group" \
    -v p1="${maps[0]}" \
    -v p2="${maps[1]}" \
    -v p3="${maps[2]}" \
    '
  BEGIN {
    inserted_proxy = 0
    inserted_group = 0
  }
  {
    if ($0 ~ /^proxy-groups:[[:space:]]*$/ && has_proxy == 0 && inserted_proxy == 0) {
      print "- " p1
      print "- " p2
      print "- " p3
      inserted_proxy = 1
    }

    if (($0 ~ /^rule-providers:[[:space:]]*$/ || $0 ~ /^rules:[[:space:]]*$/) && has_group == 0 && inserted_group == 0) {
      print "- name: 狗狗加速.com"
      print "  type: select"
      print "  proxies:"
      print "  - ♻️自动选择"
      print "  - Doggo-Fallback-1"
      print "  - Doggo-Fallback-2"
      print "  - Doggo-Fallback-3"
      print "  - DIRECT"
      print "- name: ♻️自动选择"
      print "  type: url-test"
      print "  proxies:"
      print "  - Doggo-Fallback-1"
      print "  - Doggo-Fallback-2"
      print "  - Doggo-Fallback-3"
      print "  url: http://cp.cloudflare.com/generate_204"
      print "  interval: 300"
      inserted_group = 1
    }

    print $0
  }
  ' "$file" > "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
    log "injected-doggo-fallback: $file"
    HEAL_CHANGED=$((HEAL_CHANGED + 1))
  else
    rm -f "$tmp"
  fi
}

patch_file() {
  local file="$1"
  repair_full_chain_topology "$file"
  return $?

  [[ -f "$file" ]] || return 0
  if ! file_contains "Claude-Residential" "$file"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  awk -v ip="$TARGET_IP" -v port="$TARGET_PORT" '
  function indent_of(s,   n) { match(s, /^ */); return RLENGTH }
  {
    line = $0

    # Inline map style: { name: "Claude-Residential", server: ..., port: ..., ... }
    # dialer-proxy(Claude-Tunnel 链式)是常规态,heal 只纠 server/port,不拆链式
    if (line ~ /Claude-Residential/ && line ~ /server:[^,}]+/ && line ~ /port:[[:space:]]*[0-9]+/) {
      gsub(/server:[[:space:]]*[^,}]+/, "server: " ip, line)
      gsub(/port:[[:space:]]*[0-9]+/, "port: " port, line)
      print line
      next
    }

    # Start of block map for Claude-Residential
    if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*\x27?Claude-Residential\x27?[[:space:]]*$/ ||
        line ~ /^[[:space:]]*name:[[:space:]]*\x27?Claude-Residential\x27?[[:space:]]*$/ ||
        line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*\"?Claude-Residential\"?[[:space:]]*$/ ||
        line ~ /^[[:space:]]*name:[[:space:]]*\"?Claude-Residential\"?[[:space:]]*$/) {
      in_block = 1
      block_indent = indent_of($0)
      print line
      next
    }

    if (in_block == 1) {
      cur_indent = indent_of($0)

      # End block when dedent to same/less indent and line is a new key/list item
      if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/ && cur_indent <= block_indent &&
          $0 !~ /^[[:space:]]*server:/ && $0 !~ /^[[:space:]]*port:/ && $0 !~ /^[[:space:]]*dialer-proxy:/) {
        in_block = 0
      }
    }

    if (in_block == 1) {
      if ($0 ~ /^[[:space:]]*server:[[:space:]]*/) {
        sub(/server:[[:space:]]*.*/, "server: " ip, line)
        print line
        next
      }
      if ($0 ~ /^[[:space:]]*port:[[:space:]]*[0-9]+/) {
        sub(/port:[[:space:]]*[0-9]+/, "port: " port, line)
        print line
        next
      }
    }

    print line
  }
  ' "$file" > "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    cp "$file" "$file.bak-$TS"
    mv "$tmp" "$file"
    log "patched: $file"
    HEAL_CHANGED=$((HEAL_CHANGED + 1))
  else
    rm -f "$tmp"
    log "no-change: $file"
  fi
}

harden_file() {
  local file="$1"
  repair_full_chain_topology "$file"
  return $?

  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"

  awk -v ip="$TARGET_IP" '
  BEGIN {
    direct_rule = "IP-CIDR," ip "/32,DIRECT,no-resolve"
    monitor_rule_1 = "DOMAIN,api.ipify.org,Claude"
    monitor_rule_2 = "DOMAIN,ipv4.icanhazip.com,Claude"
    monitor_rule_3 = "DOMAIN-SUFFIX,ip.sb,Claude"
    seen_direct = 0
    seen_curl = 0
    seen_monitor_1 = 0
    seen_monitor_2 = 0
    seen_monitor_3 = 0
    inserted_monitor = 0
  }
  {
    line = $0

    # Persist safe mode in generated configs.
    if (line ~ /^mode:[[:space:]]*global[[:space:]]*$/) {
      line = "mode: rule"
    }

    # Remove conflicting Claude-domain routes that may send traffic to non-Claude groups.
    clean = line
    sub(/^[[:space:]]*-[[:space:]]*'\''?/, "", clean)
    sub(/'\''?[[:space:]]*$/, "", clean)
    if ((clean ~ /^(DOMAIN|DOMAIN-SUFFIX),(anthropic\.com|claude\.ai|claude\.com|clau\.de|claudeusercontent\.com|modelcontextprotocol\.io|anthropic\.statuspage\.io),/ ||
         clean ~ /^IP-CIDR6?,(160\.79\.104\.0\/21|2607:6bc0::\/48),/) &&
        clean !~ /,Claude(,|$)/) {
      next
    }

    # Keep Claude routing focused on core domains to reduce residential endpoint load.
    if (index(line, "DOMAIN-SUFFIX,sentry.io,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,statsigapi.net,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,featureassets.org,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,prodregistryv2.org,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,featuregates.org,Claude") > 0 ||
        index(line, "DOMAIN,api.segment.io,Claude") > 0 ||
        index(line, "DOMAIN,cdn.growthbook.io,Claude") > 0) {
      next
    }

    # De-duplicate managed rules if they already exist multiple times.
    if (index(line, direct_rule) > 0) {
      if (seen_direct) next
      seen_direct = 1
    }
    if (index(line, "PROCESS-NAME,curl,Claude") > 0) {
      if (seen_curl) next
      seen_curl = 1
    }
    if (index(line, monitor_rule_1) > 0) {
      if (seen_monitor_1) next
      seen_monitor_1 = 1
    }
    if (index(line, monitor_rule_2) > 0) {
      if (seen_monitor_2) next
      seen_monitor_2 = 1
    }
    if (index(line, monitor_rule_3) > 0) {
      if (seen_monitor_3) next
      seen_monitor_3 = 1
    }

    print line

    # Ensure monitor domains route through Claude in rule mode.
    if (!inserted_monitor &&
        (index(line, "DOMAIN-SUFFIX,ping0.cc,Claude") > 0 ||
         index(line, "DOMAIN,ifconfig.me,Claude") > 0)) {
      match(line, /^[[:space:]]*/)
      indent = substr(line, 1, RLENGTH)
      if (line ~ /'\''[[:space:]]*$/) {
        if (!seen_monitor_1) print indent "- '\''" monitor_rule_1 "'\''"
        if (!seen_monitor_2) print indent "- '\''" monitor_rule_2 "'\''"
        if (!seen_monitor_3) print indent "- '\''" monitor_rule_3 "'\''"
      } else {
        if (!seen_monitor_1) print indent "- " monitor_rule_1
        if (!seen_monitor_2) print indent "- " monitor_rule_2
        if (!seen_monitor_3) print indent "- " monitor_rule_3
      }
      seen_monitor_1 = 1
      seen_monitor_2 = 1
      seen_monitor_3 = 1
      inserted_monitor = 1
    }

    # Ensure curl-based checks are always routed into Claude group.
    if (!seen_curl && index(line, "DOMAIN-SUFFIX,ping0.cc,Claude") > 0) {
      match(line, /^[[:space:]]*/)
      indent = substr(line, 1, RLENGTH)
      if (line ~ /'\''[[:space:]]*$/) {
        print indent "- '\''PROCESS-NAME,curl,Claude'\''"
      } else {
        print indent "- PROCESS-NAME,curl,Claude"
      }
      seen_curl = 1
    }

    # Ensure outbound connection to residential SOCKS endpoint never gets re-proxied.
    if (!seen_direct && index(line, "IP-CIDR6,2607:6bc0::/48,Claude,no-resolve") > 0) {
      match(line, /^[[:space:]]*/)
      indent = substr(line, 1, RLENGTH)
      if (line ~ /'\''[[:space:]]*$/) {
        print indent "- '\''" direct_rule "'\''"
      } else {
        print indent "- " direct_rule
      }
      seen_direct = 1
    }
  }
  ' "$file" > "$tmp"

  # Apply the remaining perl transforms to the tmp copy (NOT the original),
  # so we can compare-and-swap atomically and only write/.bak when something changed.

  # Ensure curl rule exists in the effective final rules block.
  perl -0777 -i -pe '
    s/(rules:\n- DOMAIN,ifconfig\.me,Claude\n- DOMAIN-SUFFIX,ping0\.cc,Claude\n)
      (?!- PROCESS-NAME,curl,Claude\n)
     /$1- PROCESS-NAME,curl,Claude\n/sx
  ' "$tmp"

  # Keep Claude selector locked to the static residential endpoint.
  perl -0777 -i -pe '
    s/(name:\s*Claude\s*\n\s*type:\s*select\s*\n\s*proxies:\s*\n\s*-\s*Claude-Residential\s*\n)
      \s*-\s*REJECT\s*\n
     /$1/sx
  ' "$tmp"

  # Ensure the residential endpoint bypasses TUN routing recursion.
  perl -i -pe '
    s/^(\s*)route-exclude-address:\s*\[\]\s*$/$1route-exclude-address:\n$1  - '"$TARGET_IP"'\/32/mg
  ' "$tmp"

  # Repair malformed joins like ".../32tcp-concurrent: true" or ".../32global-client-fingerprint: ...".
  perl -i -pe '
    s#([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32)([A-Za-z][A-Za-z0-9-]*:)#$1\n$2#g
  ' "$tmp"

  # Repair wrong indentation under route-exclude-address.
  perl -0777 -i -pe '
    s/^(\s*)route-exclude-address:\s*\n\1-\s*/$1route-exclude-address:\n$1  - /mg
  ' "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    cp "$file" "$file.bak-$TS"
    mv "$tmp" "$file"
    log "hardened: $file"
    HEAL_CHANGED=$((HEAL_CHANGED + 1))
  else
    rm -f "$tmp"
    log "already-hardened: $file"
  fi
}

archive_old_baks() {
  local src keep=20 archive="${BAK_ARCHIVE:-$HOME/Archive/2026/clash-verge-bak-20260610}"
  local baks
  /bin/mkdir -p "$archive"
  for src in "$BASE"/*.yaml "$BASE"/profiles/*.yaml; do
    [[ -f "$src" ]] || continue
    baks="$(ls -t "$src".bak-* 2>/dev/null || true)"
    [[ -n "$baks" ]] || continue
    printf '%s\n' "$baks" | tail -n +$((keep + 1)) | while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      mv "$f" "$archive/" 2>/dev/null || true
    done
  done
}

runtime_claude_needs_reload() {
  local claude_group residential_group topology_ok rules
  [[ -S "$SOCK" ]] || return 1

  claude_group="$(api_get_proxy_group "Claude" 2>/dev/null || true)"
  residential_group="$(api_get_proxy_group "Claude-Residential" 2>/dev/null || true)"
  topology_ok="$(printf '%s\n%s' "$claude_group" "$residential_group" | /usr/bin/python3 -c '
import json, sys
lines = sys.stdin.read().splitlines()
try:
    claude, residential = map(json.loads, lines[:2])
except Exception:
    raise SystemExit(1)
ok = (
    claude.get("all") == ["Claude-Residential", "REJECT"]
    and residential.get("all") == ["Claude-Residential-JP3", "Claude-Residential-JP1", "Claude-Residential-SG5", "Claude-Residential-SG4"]
    and residential.get("now") in residential.get("all", [])
)
raise SystemExit(0 if ok else 1)
' 2>/dev/null && printf OK || true)"
  [[ "$topology_ok" == OK ]] || return 0

  rules="$(curl --unix-socket "$SOCK" -s http://localhost/rules 2>/dev/null || true)"
  [[ "$rules" == *"anthropic.com"* ]] || return 0
  [[ "$rules" == *"claude.ai"* ]] || return 0
  [[ "$rules" == *"claude.com"* ]] || return 0
  [[ "$rules" == *"clau.de"* ]] || return 0
  [[ "$rules" == *"claudeusercontent.com"* ]] || return 0
  [[ "$rules" == *"api.ipify.org"* ]] || return 0
  [[ "$rules" == *"ipv4.icanhazip.com"* ]] || return 0
  [[ "$rules" == *"ip.sb"* ]] || return 0
  [[ "$rules" == *"claude.exe"* ]] || return 0
  return 1
}

claude_active_connection_count() {
  local out
  [[ -S "$SOCK" ]] || return 1
  out="$(curl --unix-socket "$SOCK" -s http://localhost/connections 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
count = 0
for conn in data.get("connections", []):
    meta = conn.get("metadata") or {}
    host = str(meta.get("host") or "").lower()
    process = str(meta.get("process") or meta.get("processPath") or "").lower()
    if any(term in host for term in ("anthropic", "claude.ai", "claude.com")) or "claude" in process:
        count += 1
print(count)
' 2>/dev/null
}

maintenance_gate_clear() {
  local elapsed=0 count gate_seconds="${CLAUDE_MAINTENANCE_GATE_SECONDS:-30}"
  while :; do
    count="$(claude_active_connection_count 2>/dev/null || printf unavailable)"
    [[ "$count" == 0 ]] || return 1
    ((elapsed >= gate_seconds)) && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

write_expanded_runtime_config() {
  local src="$BASE/clash-verge.yaml"
  local dst="$BASE/clash-verge-guard-expanded.yaml"
  local active_merge
  [[ -f "$src" ]] || return 1
  active_merge="$(resolve_active_merge_source || true)"
  [[ -n "$active_merge" && -f "$active_merge" ]] || return 1

  /usr/bin/python3 - "$src" "$dst" "$TARGET_IP" "$active_merge" <<'PY'
import sys
import yaml

src, dst, target_ip, active_merge = sys.argv[1:5]
with open(src) as f:
    data = yaml.safe_load(f)
with open(active_merge) as f:
    merge_data = yaml.safe_load(f) or {}

prepend_proxies = merge_data.get("prepend-proxies") or data.pop("prepend-proxies", []) or []
prepend_groups = merge_data.get("prepend-proxy-groups") or data.pop("prepend-proxy-groups", []) or []
prepend_rules = merge_data.get("prepend-rules") or data.pop("prepend-rules", []) or []
data.pop("prepend-proxies", None)
data.pop("prepend-proxy-groups", None)
data.pop("prepend-rules", None)
data.pop("append-proxies", None)
data.pop("append-proxy-groups", None)
data.pop("append-rules", None)

proxies = data.get("proxies") or []
groups = data.get("proxy-groups") or []
rules = data.get("rules") or []

all_proxies = [p for p in prepend_proxies + proxies if isinstance(p, dict)]
qualified_names = ["Claude-Residential-JP3", "Claude-Residential-JP1", "Claude-Residential-SG5", "Claude-Residential-SG4"]
qualified_proxies = []
for name in qualified_names:
    match = next((p for p in all_proxies if p.get("name") == name), None)
    if match is None:
        raise SystemExit(f"missing full-chain proxy: {name}")
    qualified_proxies.append(match)
data["proxies"] = qualified_proxies + [
    p for p in proxies
    if not str(p.get("name", "")).startswith("Claude-Residential")
]

merged_groups = [g for g in groups + prepend_groups if isinstance(g, dict)]
merged_rules = [r for r in prepend_rules if r not in rules] + rules

claude_rules = [
    f"IP-CIDR,{target_ip}/32,DIRECT,no-resolve",
    "DOMAIN,ifconfig.me,Claude",
    "DOMAIN,api.ipify.org,Claude",
    "DOMAIN,ipv4.icanhazip.com,Claude",
    "DOMAIN-SUFFIX,ip.sb,Claude",
    "DOMAIN-SUFFIX,ping0.cc,Claude",
    "PROCESS-NAME,curl,Claude",
    "PROCESS-NAME,claude.exe,Claude",
    "PROCESS-NAME,claude,Claude",
    "DOMAIN-SUFFIX,anthropic.com,Claude",
    "DOMAIN-SUFFIX,claude.ai,Claude",
    "DOMAIN-SUFFIX,claude.com,Claude",
    "DOMAIN-SUFFIX,clau.de,Claude",
    "DOMAIN-SUFFIX,claudeusercontent.com,Claude",
    "DOMAIN-SUFFIX,modelcontextprotocol.io,Claude",
    "DOMAIN,anthropic.statuspage.io,Claude",
    "IP-CIDR,160.79.104.0/21,Claude,no-resolve",
    "IP-CIDR6,2607:6bc0::/48,Claude,no-resolve",
]

def is_claude_rule(rule):
    text = str(rule)
    return any(term in text for term in [
        target_ip,
        "Claude-Fast",
        "anthropic.com",
        "claude.ai",
        "claude.com",
        "clau.de",
        "claudeusercontent.com",
        "modelcontextprotocol.io",
        "anthropic.statuspage.io",
        "api.ipify.org",
        "ipv4.icanhazip.com",
        "ifconfig.me",
        "ping0.cc",
        "ip.sb",
        "PROCESS-NAME,claude.exe",
        "PROCESS-NAME,claude",
    ])

managed_group_names = {"Claude", "Claude-Fast", "Claude-Tunnel", "Claude-Residential"}
other_groups = []
seen_group_names = set()
for group in merged_groups:
    name = group.get("name")
    if name in managed_group_names or name in seen_group_names:
        continue
    seen_group_names.add(name)
    other_groups.append(group)

clean_groups = [
    {
        "name": "Claude-Residential",
        "type": "fallback",
        "proxies": qualified_names,
        "url": "https://api.anthropic.com/",
        "interval": 15,
        "lazy": False,
        "max-failed-times": 2,
        "expected-status": 404,
    },
    {"name": "Claude", "type": "select", "proxies": ["Claude-Residential", "REJECT"]},
] + other_groups

data["proxy-groups"] = clean_groups
data["rules"] = claude_rules + [r for r in merged_rules if not is_claude_rule(r)]

for group in data["proxy-groups"]:
    if isinstance(group, dict) and group.get("name") == "Codex-Stable":
        group["interval"] = 300
        group["lazy"] = True
        group["max-failed-times"] = 3

with open(dst, "w") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
PY

  printf '%s' "$dst"
}

runtime_core_settings_ok() {
  local out
  out="$(curl --unix-socket "$SOCK" -s http://localhost/configs 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
tun = data.get("tun") or {}
ok = data.get("mode") == "rule" and data.get("ipv6") is False and tun.get("enable") is True
raise SystemExit(0 if ok else 1)
' 2>/dev/null
}

reload_core() {
  if [[ ! -S "$SOCK" ]]; then
    warn "clash socket not found at $SOCK; skip runtime reload"
    return 0
  fi

  if [[ "${CLAUDE_MAINTENANCE_APPROVED:-}" != 1 ]] && ! maintenance_gate_clear; then
    err "Claude requests are active; refuse runtime switch/reload"
    return 20
  fi

  # Do a full reload only when source files changed or runtime lost the Claude
  # guard invariants. Use an expanded config because mihomo does not understand
  # Clash Verge's prepend-* merge keys directly.
  if [[ "${HEAL_CHANGED:-0}" -gt 0 ]] || runtime_claude_needs_reload; then
    local core_cfg
    core_cfg="$(write_expanded_runtime_config || true)"
    [[ -n "$core_cfg" && -f "$core_cfg" ]] || {
      err "cannot generate expanded runtime config"
      return 21
    }
    curl --unix-socket "$SOCK" -s -X PUT -H 'Content-Type: application/json' \
      -d "{\"path\":\"$core_cfg\",\"force\":true}" http://localhost/configs >/dev/null || {
      err "core reload request failed"
      return 22
    }
    log "core reloaded (HEAL_CHANGED=$HEAL_CHANGED, expanded-runtime)"
  else
    log "core reload skipped (no on-disk change this run)"
  fi

  # Enforce rule mode every run so global-mode regressions do not reappear.
  curl --unix-socket "$SOCK" -s -X PATCH -H 'Content-Type: application/json' \
    -d '{"mode":"rule","ipv6":false}' http://localhost/configs >/dev/null || return 23

  # Ensure TUN stays enabled, otherwise terminal traffic bypasses Clash entirely.
  curl --unix-socket "$SOCK" -s -X PATCH -H 'Content-Type: application/json' \
    -d '{"tun":{"enable":true}}' http://localhost/configs >/dev/null || return 23

  # Never route the residential SOCKS endpoint back into TUN/proxy chain.
  # Also exclude Tailscale's CGNAT (100.64.0.0/10) and IPv6 ULA (fd7a:115c:a1e0::/48)
  # so the Tailscale virtual network bypasses mihomo's TUN entirely. This lets
  # the user's Tailscale-based monitoring apps keep working without conflicting
  # with the gvisor stack, and reduces mihomo's connection-tracker pressure.
  curl --unix-socket "$SOCK" -s -X PATCH -H 'Content-Type: application/json' \
    -d "{\"tun\":{\"enable\":true,\"route-exclude-address\":[\"$TARGET_IP/32\",\"100.64.0.0/10\",\"fd7a:115c:a1e0::/48\"]}}" http://localhost/configs >/dev/null || return 23

  # Ensure Claude group points to Claude-Residential
  set_proxy_group_choice "Claude" "Claude-Residential" || return 24
  runtime_core_settings_ok || return 25
  if runtime_claude_needs_reload; then
    err "runtime topology verification failed after repair"
    return 26
  fi
}

patch_profiles_state() {
  local file="$BASE/profiles.yaml"
  [[ -f "$file" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  cp "$file" "$tmp"

  perl -0777 -i -pe '
    s/(- name:\s*主代理\s*\n\s*now:\s*).*/${1}自动选择/g;
    s/(- name:\s*OpenAI\s*\n\s*now:\s*).*/${1}SG自动选择/g;
    s/(- name:\s*狗狗加速\.com\s*\n\s*now:\s*).*/${1}♻️自动选择/g;
    s/(- name:\s*GLOBAL\s*\n\s*now:\s*).*/${1}狗狗加速.com/g;
  ' "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    cp "$file" "$file.bak-$TS"
    mv "$tmp" "$file"
    log "state-updated: $file (verge ui-state only, no core reload needed)"
  else
    rm -f "$tmp"
    log "state-no-change: $file"
  fi
}

check_ip() {
  local status ip1 ip2
  status="$(curl -4 -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 \
    https://api.anthropic.com/ 2>/dev/null)" || {
    err "full-chain Anthropic probe failed"
    return 2
  }
  [[ "$status" == 404 ]] || {
    err "full-chain Anthropic probe returned unexpected status"
    return 3
  }
  ip1="$(curl -4 -sS --connect-timeout 6 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '\r\n' || true)"
  ip2="$(curl -4 -sS --connect-timeout 6 --max-time 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$ip1" == "$TARGET_IP" && "$ip2" == "$TARGET_IP" ]] || {
    err "full-path egress verification failed"
    return 4
  }
  log "OK: full-chain Anthropic and egress verified"
  return 0

  local ip1 ip2
  local proxy_line user pass server port
  local proxy_auth

  local pattern='Claude-Residential.*server: [^,}]+.*port: [0-9]+.*username: [^,}]+.*password: [^,}]+'
  local search_out
  if has_cmd rg; then
    search_out="$(rg -n "$pattern" "$BASE/clash-verge.yaml" "$BASE"/profiles/*.yaml 2>/dev/null || true)"
  else
    search_out="$(grep -En "$pattern" "$BASE/clash-verge.yaml" "$BASE"/profiles/*.yaml 2>/dev/null || true)"
  fi
  proxy_line="$(printf '%s\n' "$search_out" | head -n1 | cut -d: -f2- || true)"

  if [[ -n "$proxy_line" ]]; then
    user="$(printf '%s' "$proxy_line" | sed -E "s/.*username: ([^,}]+).*/\\1/")"
    pass="$(printf '%s' "$proxy_line" | sed -E "s/.*password: ([^,}]+).*/\\1/")"
    server="$(printf '%s' "$proxy_line" | sed -E "s/.*server: ([^,}]+).*/\\1/")"
    port="$(printf '%s' "$proxy_line" | sed -E "s/.*port: ([0-9]+).*/\\1/")"
    proxy_auth="$user:$pass@$server:$port"

    # Validate through the residential SOCKS endpoint itself (HTTPS only).
    ip1="$(probe_ip_via_socks "$proxy_auth" "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ip.sb" || true)"
    ip2="$(probe_ip_via_socks "$proxy_auth" "https://ip.sb" "https://api.ipify.org" "https://ipv4.icanhazip.com" || true)"
  else
    # Fallback when credentials are not found in local config files (HTTPS only).
    ip1="$(probe_ip_direct "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ip.sb" || true)"
    ip2="$(probe_ip_direct "https://ip.sb" "https://api.ipify.org" "https://ipv4.icanhazip.com" || true)"
  fi

  # Treat single-source failure as degraded, not immediate mismatch.
  [[ -z "$ip1" && -n "$ip2" ]] && ip1="$ip2"
  [[ -z "$ip2" && -n "$ip1" ]] && ip2="$ip1"

  log "primary-ip-source=$ip1"
  log "secondary-ip-source=$ip2"

  if [[ -z "$ip1" || -z "$ip2" ]]; then
    err "IP check failed (empty response)."
    return 2
  fi
  if [[ "$ip1" != "$ip2" ]]; then
    err "IP sources mismatch."
    return 3
  fi
  if [[ "$ip1" != "$TARGET_IP" ]]; then
    err "IP is $ip1, expected $TARGET_IP."
    return 4
  fi

  log "OK: static residential IP restored ($TARGET_IP)."
  return 0
}

check_ip_with_warmup() {
  local attempt max_attempts="${CLAUDE_POST_RELOAD_PROBE_ATTEMPTS:-7}"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if check_ip; then
      return 0
    fi
    ((attempt < max_attempts)) && sleep 5
  done
  return 1
}

main() {
  if [[ -z "$TARGET_IP" || -z "$TARGET_PORT" ]]; then
    err "Target IP/port missing. Usage: claude-ip-heal <ip> <port> or set CLAUDE_STATIC_IP/CLAUDE_STATIC_PORT."
    exit 11
  fi

  # Tracks whether this run produced any on-disk change. Used by reload_core
  # to decide if a full mihomo PUT-reload is necessary (it's only necessary
  # when an on-disk yaml actually changed).
  HEAL_CHANGED=0

  if [[ "${CLAUDE_MAINTENANCE_APPROVED:-}" != 1 ]] && ! maintenance_gate_clear; then
    err "Claude requests are active; refuse source mutation and reload"
    exit 20
  fi

  log "target endpoint configured"
  log "base=$BASE"

  local active_merge
  active_merge="$(resolve_active_merge_source || true)"
  if [[ -z "$active_merge" ]]; then
    err "Cannot resolve active merge source"
    exit 10
  fi

  repair_full_chain_topology "$active_merge"
  validate_full_chain_topology "$active_merge" || {
    err "Full-chain topology validation failed"
    exit 12
  }
  reload_core
  check_ip_with_warmup
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
