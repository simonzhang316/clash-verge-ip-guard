# Clash Verge 守护层稳定性修复 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除 Clash Verge / mihomo / 守护脚本自身造成的网络抖动：停止周期性 reload、停止高频 heal、停止守护层自动拨动全局出口；Claude 防封号能力不减，Codex fallback 只做防抖不做测速选线。

**Architecture:** 两阶段。Phase 1 修脚本（enforce 先查运行时不变量再修、heal 停止改写 Verge 生成文件、守护层不再管理 `GLOBAL`），全程不触碰运行中的 mihomo。Phase 2 在 master 在场的受控窗口内做唯一一次配置重载（关订阅自动更新 + Codex 防抖 + 磁盘/运行时同步），前后过验证门。

**Tech Stack:** bash、mihomo REST API（unix socket `/tmp/verge/verge-mihomo.sock`）、launchd、Clash Verge Rev。

**对应设计文档:** `docs/specs/2026-06-10-guard-layer-stability-design.md`

---

## 红线（每个任务执行前默念）

1. 任何时刻不允许 Claude 流量从非家宽 IP 出口；fail-closed（IP 不对 → 拦截 Claude）逻辑必须保留。
2. 不动 TUN 配置、`Claude-Residential` 定义、Claude 域名规则、订阅内容、verge.yaml。
3. Phase 1 不触发任何 core reload；Phase 2 只允许一次，且 master 确认 Claude/Codex 已关闭。
4. 每个文件改动前先备份；验证门不过立即回滚，不带病放行。
5. 本方案不评估机场/家宽延迟，不按测速优劣选线；只修 Clash Verge / mihomo / guard 造成的抖动。
6. Claude IP guard 默认不管理 `GLOBAL`、`主代理`、`狗狗加速.com`，避免把防封号守护变成全局出口拨杆。

## 敏感值约定

家宽 IP/端口不写入任何 git 文件。所有命令用以下方式动态读取：

```bash
PLIST="$HOME/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist"
EXP_IP="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$PLIST")"
EXP_PORT="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$PLIST")"
APPDIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
SOCK=/tmp/verge/verge-mihomo.sock
```

## 涉及文件总览

| 文件 | 动作 | 职责 |
|---|---|---|
| `~/.local/bin/claude-ip-enforce` | 修改 | 30s 周期守卫：先查 Claude 运行时不变量，正确则零动作；不拨动 GLOBAL |
| `~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh` | 修改 | 漂移修复：只改源文件，不碰 Verge 生成物；运行时只修 Claude 必需项 |
| `~/Projects/clash-verge-ip-guard/skills/claude-ip-guard/scripts/claude-ip-heal.sh` | 同步 | git canonical 副本 |
| `$APPDIR/profiles/mUTAPkE8C6o0.yaml` | 修改（Phase 2） | mitce merge：Codex-Stable 防抖 |
| `$APPDIR/profiles.yaml` | UI 间接修改（Phase 2） | mitce `allow_auto_update: false` |
| `$APPDIR/clash-verge-guard-expanded.yaml` | 生成（Phase 2/漂移修复时） | 展开 `prepend-*` 后给 mihomo reload |
| `~/Scratch/20260610-clash-guard-rollback/` | 创建 | 回滚仓 |
| `~/Archive/2026/clash-verge-bak-20260610/` | 创建 | 历史 .bak 归档 |

---

# Phase 1 — 脚本修复（无 reload，随时可做）

### Task 1: 备份与基线采集

**Files:**
- Create: `~/Scratch/20260610-clash-guard-rollback/`（回滚仓）
- Create: `~/Scratch/20260610-clash-guard-rollback/BASELINE.txt`

- [ ] **Step 1: 建回滚仓并备份全部目标文件**

```bash
RB=~/Scratch/20260610-clash-guard-rollback
/bin/mkdir -p "$RB"
cp ~/.local/bin/claude-ip-enforce "$RB/claude-ip-enforce"
cp ~/.local/bin/claude-ip-heal "$RB/claude-ip-heal.wrapper"
cp ~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh "$RB/claude-ip-heal.sh"
cp ~/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist "$RB/"
cp "$APPDIR/profiles.yaml" "$RB/profiles.yaml"
cp "$APPDIR/profiles/mUTAPkE8C6o0.yaml" "$RB/mUTAPkE8C6o0.yaml"
ls -la "$RB"
```

Expected: 7 个文件全部就位。

- [ ] **Step 2: 采集基线指标（验收对照用）**

```bash
RB=~/Scratch/20260610-clash-guard-rollback
{
  echo "captured: $(date '+%F %T')"
  echo "core_reloads_total: $(grep -c 'core reloaded' ~/.local/log/claude-ip-enforcer.log)"
  echo "enforce_starts_total: $(grep -c 'enforce start' ~/.local/log/claude-ip-enforcer.log)"
  echo "err_log_lines: $(wc -l < ~/.local/log/claude-ip-enforcer.launchd.err.log)"
  echo "bak_files_appdir: $(ls "$APPDIR" | grep -c '\.bak-' || true)"
  echo "bak_files_profiles: $(ls "$APPDIR/profiles" | grep -c '\.bak-' || true)"
} > "$RB/BASELINE.txt"
cat "$RB/BASELINE.txt"
```

Expected: 5 项指标有值（core_reloads_total 约 1191+）。

### Task 2: 修复 claude-ip-enforce

**Files:**
- Modify: `~/.local/bin/claude-ip-enforce`

四处改动：line 246 算术 bug、新增 Claude 运行时不变量快速路径、默认关闭全局出口 failover、选择器 PUT 改为差异时才发。

- [ ] **Step 1: 修 line 246 算术 bug**

原文（line 246）：

```bash
  fail_count=$(( "$(current_fail_count)" + 1 ))
```

改为（`$(( ))` 内不得有引号，这是每 30 秒崩一次的根源）：

```bash
  fail_count=$(( $(current_fail_count) + 1 ))
```

- [ ] **Step 2: 在 `notify()` 函数之后新增快速路径函数**

插入位置：line 57（`notify` 的收尾 `}` 之后）。

```bash
# Runtime invariant: Claude traffic must still be pinned to Claude-Residential.
# Do not depend on current probe-domain rules here; some are repaired only in
# the controlled Phase 2 reload.
runtime_claude_rules_ok() {
  local rules
  [[ -S "$SOCK" ]] || return 1
  rules="$(/usr/bin/curl -s --unix-socket "$SOCK" http://localhost/rules 2>/dev/null || true)"
  [[ "$rules" == *"anthropic.com"* ]] || return 1
  [[ "$rules" == *"claude.ai"* ]] || return 1
  [[ "$rules" == *"claude.com"* ]] || return 1
  [[ "$rules" == *"clau.de"* ]] || return 1
  [[ "$rules" == *"claudeusercontent.com"* ]] || return 1
  [[ "$rules" == *"claude.exe"* ]] || return 1
}

# Mode/TUN invariant: rules only apply in rule mode, and terminal traffic only
# enters mihomo via TUN. A silent switch to global mode bypasses Claude rules
# while group/rules/SOCKS checks still pass -> must be part of the invariant.
runtime_mode_tun_ok() {
  [[ -S "$SOCK" ]] || return 1
  /usr/bin/curl -s --unix-socket "$SOCK" http://localhost/configs 2>/dev/null | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
ok = d.get("mode") == "rule" and bool(d.get("tun", {}).get("enable"))
sys.exit(0 if ok else 1)
' 2>/dev/null
}

runtime_claude_guard_ok() {
  runtime_mode_tun_ok || return 1
  [[ "$(current_group_choice "Claude" 2>/dev/null || true)" == "Claude-Residential" ]] || return 1
  runtime_claude_rules_ok || return 1
}

residential_proxy_auth() {
  local base line server port user pass
  base="${CLASH_VERGE_BASE:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
  line="$(/usr/bin/grep -Eh 'Claude-Residential.*server: [^,}]+.*port: [0-9]+.*username: [^,}]+.*password: [^,}]+' \
    "$base/clash-verge.yaml" "$base"/profiles/*.yaml 2>/dev/null | /usr/bin/head -n1 || true)"
  [[ -n "$line" ]] || return 1
  server="$(printf '%s' "$line" | sed -E 's/.*server: ([^,}]+).*/\1/')"
  port="$(printf '%s' "$line" | sed -E 's/.*port: ([0-9]+).*/\1/')"
  user="$(printf '%s' "$line" | sed -E 's/.*username: ([^,}]+).*/\1/')"
  pass="$(printf '%s' "$line" | sed -E 's/.*password: ([^,}]+).*/\1/')"
  [[ -n "$server" && -n "$port" && -n "$user" && -n "$pass" ]] || return 1
  printf '%s:%s@%s:%s' "$user" "$pass" "$server" "$port"
}

# Validate the residential SOCKS endpoint itself. This avoids false negatives
# from currently-missing mihomo probe rules while still preserving fail-closed.
residential_socks_ip_ok() {
  local auth hits=0 ip src
  auth="$(residential_proxy_auth)" || return 1
  for src in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ip.sb"; do
    ip="$(/usr/bin/curl -4 -s --max-time 8 --socks5-hostname "$auth" "$src" 2>/dev/null | tr -d '\r\n')"
    if [[ "$ip" == "$TARGET_IP" ]]; then
      hits=$((hits + 1))
      [[ "$hits" -ge 2 ]] && return 0
    fi
  done
  return 1
}

guard_fast_path_ok() {
  runtime_claude_guard_ok && residential_socks_ip_ok
}

# Set a selector only when its current choice differs (avoids selector churn).
ensure_group_quiet() {
  local group="$1" choice="$2" now
  now="$(current_group_choice "$group" 2>/dev/null || true)"
  [[ "$now" == "$choice" ]] && return 0
  set_group_choice "$group" "$choice" >/dev/null 2>&1 || true
}
```

注意：这些函数引用的 `current_group_choice`/`set_group_choice` 定义在 line 93-109 —— 函数体在调用时才解析，bash 中此顺序合法。`residential_socks_ip_ok` 不输出 proxy auth，不把凭据写入日志。

- [ ] **Step 3: 默认关闭 `GLOBAL` 自动 failover，只在显式打开时运行**

在变量区新增：

```bash
MANAGE_GLOBAL_FAILOVER="${CLAUDE_GUARD_MANAGE_GLOBAL:-false}"
```

在 `manage_egress_failover()` 定义之后新增：

```bash
maybe_manage_egress_failover() {
  $MANAGE_GLOBAL_FAILOVER || return 0
  manage_egress_failover || true
}
```

理由：Claude IP guard 的职责是保护 Claude 出口，不应该每 30 秒探测并切换 `GLOBAL`。这一步直接消除守护层造成的全局出口跳变；如以后确实需要全局 failover，必须通过环境变量显式打开。

- [ ] **Step 4: `manage_egress_failover` 内 3 处无条件 PUT 改为 quiet 版（仅对显式打开时生效）**

原文（lines 195-196）：

```bash
  $mitce_present && set_group_choice "$MITCE_GROUP" "$MITCE_CHOICE" >/dev/null 2>&1 || true
  $doggo_present && set_group_choice "$DOGGO_GROUP" "$DOGGO_CHOICE" >/dev/null 2>&1 || true
```

改为：

```bash
  $mitce_present && ensure_group_quiet "$MITCE_GROUP" "$MITCE_CHOICE" || true
  $doggo_present && ensure_group_quiet "$DOGGO_GROUP" "$DOGGO_CHOICE" || true
```

原文（line 211，PRIMARY 分支的 else）：

```bash
      set_group_choice "$GLOBAL_GROUP" "$MITCE_GROUP" >/dev/null 2>&1 || true
```

改为：

```bash
      ensure_group_quiet "$GLOBAL_GROUP" "$MITCE_GROUP" || true
```

（lines 205、232 两处切换分支保留原样——它们只在状态真变化时执行。）

- [ ] **Step 5: 主流程加快速路径**

原文（lines 281-305）：

```bash
{
  echo "[$(date '+%F %T')] enforce start target=${TARGET_IP}:${TARGET_PORT}"
} >> "$LOG_FILE"

if "$HEAL_BIN" "$TARGET_IP" "$TARGET_PORT" >> "$LOG_FILE" 2>&1; then
```

改为（在 enforce start 日志后插入快速路径，heal 调用保持原样作为慢速路径）：

```bash
{
  echo "[$(date '+%F %T')] enforce start target=${TARGET_IP}:${TARGET_PORT}"
} >> "$LOG_FILE"

# Fast path: Claude runtime invariant already correct -> zero heal, zero reload,
# and no GLOBAL/primary/doggo selector movement.
if guard_fast_path_ok; then
  set_fail_count 0
  set_state "OK"
  {
    echo "[$(date '+%F %T')] enforce OK (fast-path)"
  } >> "$LOG_FILE"
  if $OPEN_ON_OK; then
    /usr/bin/open -a 'Claude' >/dev/null 2>&1 || true
  fi
  exit 0
fi

{
  echo "[$(date '+%F %T')] guard invariant mismatch -> invoking heal"
} >> "$LOG_FILE"

if "$HEAL_BIN" "$TARGET_IP" "$TARGET_PORT" >> "$LOG_FILE" 2>&1; then
```

慢速路径（heal 成功后的 `ensure_group_choice "Claude" "Claude-Residential"`、二次核验、`handle_enforce_failure`）全部保留原样——这是 fail-closed 的主干。原主流程里的 `manage_egress_failover || true` 改成 `maybe_manage_egress_failover || true`，默认不切 `GLOBAL`。

- [ ] **Step 6: 语法检查**

```bash
bash -n ~/.local/bin/claude-ip-enforce && echo SYNTAX-OK
```

Expected: `SYNTAX-OK`

- [ ] **Step 7: 手动跑一次（非 silent、不杀 Claude）验证快速路径**

```bash
~/.local/bin/claude-ip-enforce "$EXP_IP" "$EXP_PORT" --no-quit; echo "exit=$?"
tail -3 ~/.local/log/claude-ip-enforcer.log
```

Expected: `exit=0`；日志末尾出现 `enforce OK (fast-path)`；**没有** `[claude-ip-heal]` 行；没有新增 `egress switch` 行。

- [ ] **Step 8: 确认 err 日志不再新增语法错误**

```bash
wc -l < ~/.local/log/claude-ip-enforcer.launchd.err.log; sleep 70; wc -l < ~/.local/log/claude-ip-enforcer.launchd.err.log
```

Expected: 两次行数相同（launchd 的 30s 周期跑了 2 次都没报错）。

### Task 3: 修复 claude-ip-heal.sh（实际生效副本）

**Files:**
- Modify: `~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh`

四处改动：main() 不再改写 Verge 生成文件、profiles.yaml 改写不触发 reload、`.bak` 超额移动归档、heal 不再拨动全局出口。

- [ ] **Step 1: main() 的文件列表剔除 Verge 生成物**

原文（lines 853-858）：

```bash
  local files=()
  [[ -f "$BASE/clash-verge.yaml" ]] && files+=("$BASE/clash-verge.yaml")
  [[ -f "$BASE/clash-verge-check.yaml" ]] && files+=("$BASE/clash-verge-check.yaml")
  if [[ -d "$BASE/profiles" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(list_yaml_files "$BASE/profiles")
  fi
```

改为：

```bash
  # clash-verge.yaml / clash-verge-check.yaml are Verge-GENERATED artifacts.
  # Verge regenerates them from profile+merge sources; mutating them here
  # created a rewrite/regenerate oscillation (core reload every ~105s).
  # Heal only mutates SOURCE files under profiles/; runtime enforcement is
  # handled by the PATCH/group calls in apply_runtime below.
  local files=()
  if [[ -d "$BASE/profiles" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(list_yaml_files "$BASE/profiles")
  fi
```

- [ ] **Step 2: patch_profiles_state 不再触发 core reload**

原文（lines 772-780）：

```bash
  if ! cmp -s "$file" "$tmp"; then
    cp "$file" "$file.bak-$TS"
    mv "$tmp" "$file"
    log "state-updated: $file"
    HEAL_CHANGED=$((HEAL_CHANGED + 1))
  else
    rm -f "$tmp"
    log "state-no-change: $file"
  fi
```

改为（`profiles.yaml` 是 Verge 的 UI 状态文件，mihomo core 不读它，改它不需要 reload）：

```bash
  if ! cmp -s "$file" "$tmp"; then
    cp "$file" "$file.bak-$TS"
    mv "$tmp" "$file"
    log "state-updated: $file (verge ui-state only, no core reload needed)"
  else
    rm -f "$tmp"
    log "state-no-change: $file"
  fi
```

- [ ] **Step 3: 新增 archive_old_baks 函数并在 main() 中调用**

在 `reload_core()` 函数定义之前（line 706 前）插入：

```bash
# Cap active .bak retention at 20 per source file by moving old files out of
# Clash Verge's hot config directory. Do not delete backups here.
archive_old_baks() {
  local src keep=20 archive="${BAK_ARCHIVE:-$HOME/Archive/2026/clash-verge-bak-20260610}"
  /bin/mkdir -p "$archive"
  for src in "$BASE"/*.yaml "$BASE"/profiles/*.yaml; do
    [[ -f "$src" ]] || continue
    ls -t "$src".bak-* 2>/dev/null | tail -n +$((keep + 1)) | while IFS= read -r f; do
      mv "$f" "$archive/" 2>/dev/null || true
    done
  done
}
```

main() 内原文（lines 872-875）：

```bash
  patch_profiles_state
  reload_core
  sleep 1
  check_ip
```

改为：

```bash
  patch_profiles_state
  archive_old_baks
  reload_core
  sleep 1
  check_ip
```

- [ ] **Step 4: reload_core 不再拨动全局出口**

在 `reload_core()` 中保留：

```bash
  # Ensure Claude group points to Claude-Residential
  set_proxy_group_choice "Claude" "Claude-Residential" || true
```

删除/注释以下全局出口拨动逻辑：

```bash
  # Main egress preference: mitce first (主代理), doggo as auxiliary.
  set_proxy_group_choice "主代理" "自动选择" || true
  set_proxy_group_choice "狗狗加速.com" "♻️自动选择" || true

  # Fallback when mitce group is absent in the currently loaded profile.
  if ! set_proxy_group_choice "GLOBAL" "主代理"; then
    set_proxy_group_choice "GLOBAL" "狗狗加速.com" || true
  fi
```

理由：heal 的职责是修 Claude 固定 IP，不应该在慢速修复路径里改变全局出口。

- [ ] **Step 5: runtime 缺 Claude 组/规则时 reload 展开配置**

在 `reload_core()` 前新增：

```bash
runtime_claude_needs_reload() { ... }
write_expanded_runtime_config() { ... }
```

语义：

- 检测运行时 `Claude` group 是否存在且包含 `Claude-Residential`。
- 检测 Claude 域名规则、Claude Code 进程规则与 probe 规则是否存在；`claudeusercontent.com` 是 Claude Code bridge 流量，`claude.exe` 可访问 Datadog 等非 Claude 域名，二者都必须纳入 Claude 规则。
- 如缺失，从 `$APPDIR/clash-verge.yaml` 生成 `$APPDIR/clash-verge-guard-expanded.yaml`：
  展开 `prepend-proxies`、`prepend-proxy-groups`、`prepend-rules`，移除 `append-*`/`prepend-*`
  merge 键，再交给 mihomo reload。
- 展开时同步给 `Codex-Stable` 写入 `interval: 300`、`lazy: true`、`max-failed-times: 3`。

理由：mihomo 不理解 Clash Verge 的 `prepend-*` merge 键。直接把带 `prepend-*` 的
`clash-verge.yaml` 交给 mihomo 会导致运行时缺 Claude 组/规则。

- [ ] **Step 6: 语法检查**

```bash
bash -n ~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh && echo SYNTAX-OK
```

Expected: `SYNTAX-OK`

- [ ] **Step 7: 手动跑一次 heal 验证幂等/漂移修复**

```bash
~/.local/bin/claude-ip-heal "$EXP_IP" "$EXP_PORT"; echo "exit=$?"
```

Expected: `exit=0`；输出中**没有** `injected-claude-core`/`injected-doggo-fallback`/`hardened:` 指向 `clash-verge.yaml` 或 `clash-verge-check.yaml` 的行；出现 `core reload skipped (no on-disk change this run)`；最后 `OK: static residential IP restored`；没有新增 `egress switch` 行。

- [ ] **Step 8: Claude 运行时复核（红线检查）**

```bash
curl --unix-socket "$SOCK" -s http://localhost/proxies/Claude | python3 -c "import json,sys; print(json.load(sys.stdin)['now'])"
```

Expected: `Claude-Residential`。住宅 SOCKS 本体出口已由 Step 6 的 `OK: static residential IP restored` 复核；Phase 2 reload 后再恢复裸 curl 多源一致性。

### Task 4: 观察 3 个 enforcer 周期（Phase 1 验收门）

- [ ] **Step 1: 记录当前 reload 计数**

```bash
grep -c "core reloaded" ~/.local/log/claude-ip-enforcer.log
```

- [ ] **Step 2: 等 3 个周期（90s+）后核对**

```bash
sleep 100
tail -8 ~/.local/log/claude-ip-enforcer.log
grep -c "core reloaded" ~/.local/log/claude-ip-enforcer.log
```

Expected: 日志全部为 `enforce start` + `enforce OK (fast-path)` 成对出现；reload 计数与 Step 1 完全相同；无 `[claude-ip-heal]` 行；无新增 `egress switch`。

任一不符 → 停止，按 Task 10 回滚脚本，重新诊断。

### Task 5: 历史 .bak 归档 + 同步 git

- [ ] **Step 1: 归档历史 .bak（move，非删除）**

```bash
/bin/mkdir -p ~/Archive/2026/clash-verge-bak-20260610
cd "$APPDIR"
ls *.bak-* 2>/dev/null | wc -l; ls profiles/*.bak-* 2>/dev/null | wc -l
mv *.bak-* ~/Archive/2026/clash-verge-bak-20260610/ 2>/dev/null || true
for f in profiles/*.bak-*; do mv "$f" ~/Archive/2026/clash-verge-bak-20260610/ 2>/dev/null; done
ls *.bak-* profiles/*.bak-* 2>/dev/null | wc -l
```

Expected: 归档前两个计数可能是数百到数十万，归档后活跃目录为 0。

- [ ] **Step 2: 同步 heal.sh 到 canonical 仓库并提交**

```bash
cp ~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh \
   ~/Projects/clash-verge-ip-guard/skills/claude-ip-guard/scripts/claude-ip-heal.sh
cd ~/Projects/clash-verge-ip-guard
git add skills/claude-ip-guard/scripts/claude-ip-heal.sh \
  docs/plans/2026-06-10-guard-layer-stability.md \
  docs/specs/2026-06-10-guard-layer-stability-design.md
git commit -m "fix(heal): stop mutating verge-generated configs; ui-state writes no longer trigger core reload

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

提交前自查：`grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' skills/claude-ip-guard/scripts/claude-ip-heal.sh` 确认无个人 IP 入库（脚本经参数/环境变量取值）。

---

# Phase 2 — 受控窗口（需 master 在场，唯一一次 reload）

**进入条件：** Task 4 验收门通过，且观察期内无异常。

### Task 6: 窗口前记录 Codex-Stable 当前运行时列表（不测速）

- [ ] **Step 1: 记录当前 Codex-Stable runtime 状态**

```bash
RB=~/Scratch/20260610-clash-guard-rollback
curl --unix-socket $SOCK -s http://localhost/proxies/Codex-Stable > "$RB/codex-stable-runtime.json"
python3 - "$RB/codex-stable-runtime.json" "$RB/WINDOW-NOTES.txt" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
note=sys.argv[2]
lines=[
  'Codex-Stable runtime before window:',
  'now = ' + str(d.get('now')),
  'all = ' + repr(d.get('all')),
]
print('\n'.join(lines))
with open(note, 'a') as f:
    f.write('\n'.join(lines) + '\n')
PY
```

- [ ] **Step 2: 定磁盘列表**

选择规则：不测速、不按延迟排序。优先把 Step 1 的 `all` 原样写回 merge，避免唯一一次 reload 后 Codex-Stable 从当前运行时列表回退到过期磁盘列表。若 Step 1 失败，则保留磁盘现有列表，只加防抖字段。

### Task 7: 编辑 merge（Codex-Stable 防抖）

**Files:**
- Modify: `$APPDIR/profiles/mUTAPkE8C6o0.yaml`

- [ ] **Step 1: 同步 Codex-Stable 组定义并加防抖**

原文：

```yaml
  - name: Codex-Stable
    type: fallback
    proxies:
      - JP2-HY2
      - JP1-HY2
      - JP3-HY2
      - HK2-HY2
      - HK3-HY2
    url: 'https://chatgpt.com/cdn-cgi/trace'
    interval: 600
    lazy: true
```

改为（节点列表用 Task 6 记录的当前运行时 `all` 原样替换；下面是格式示例）：

```yaml
  - name: Codex-Stable
    type: fallback
    proxies:
      - <Task 6 runtime all[0]>
      - <Task 6 runtime all[1]>
      - <Task 6 runtime all[2]>
      - <...>
    url: 'https://chatgpt.com/cdn-cgi/trace'
    interval: 300
    lazy: true
    max-failed-times: 3
```

语义：fallback 自动切换/自动切回保留；`max-failed-times: 3` = 连续 3 次健康检查失败才判死（防偶发超时抖动）；`interval: 300` = 真故障最迟 5 分钟检出。这里不评估节点快慢，只避免 Clash reload 后把运行时状态回滚成旧磁盘状态。

- [ ] **Step 2: 把家宽 SOCKS 端点的 DIRECT 规则移到 prepend-rules 首位**

原文（prepend-rules 中段，在 PROCESS-NAME 之后）：

```yaml
prepend-rules:
  - 'DOMAIN,ifconfig.me,Claude'
  # ...
  - 'PROCESS-NAME,curl,Claude'
  # ...
  - 'IP-CIDR,<家宽SOCKS服务器IP>/32,DIRECT,no-resolve'
```

改为（DIRECT 规则置顶，其余顺序不变）：

```yaml
prepend-rules:
  - 'IP-CIDR,<家宽SOCKS服务器IP>/32,DIRECT,no-resolve'
  - 'DOMAIN,ifconfig.me,Claude'
  # ...
  - 'PROCESS-NAME,curl,Claude'
  # ...
```

理由：reload 恢复 `PROCESS-NAME,curl,Claude` 后，enforcer fast-path 的 SOCKS 本体直测（curl 直址连接家宽端点）会被 PROCESS-NAME 规则先抓走，变成家宽代理连接它自己的自环，成败不确定。DIRECT 置顶让所有直址访问家宽端点的连接确定性直连——这正是该规则的本意，也让 fast-path 测试路径与 mihomo 拨家宽的真实路径一致。

- [ ] **Step 3: YAML 语法校验**

```bash
python3 -c "import yaml; yaml.safe_load(open('$APPDIR/profiles/mUTAPkE8C6o0.yaml')); print('YAML-OK')"
```

Expected: `YAML-OK`。此时只改了磁盘文件，运行时尚未受影响。

### Task 8: master 现场操作 + 唯一一次 reload

- [ ] **Step 1: master 确认三件事并口头回复**

1. Claude 桌面端已退出；2. 所有 Claude Code CLI 会话已结束（本 session 除外，它走 `NO_PROXY` 不受影响——仍建议空闲）；3. Codex CLI 已退出。

- [ ] **Step 2: 关闭 mitce 订阅自动更新**

操作：优先用 Clash Verge UI 关闭；无人值守时可直接把 `$APPDIR/profiles.yaml` 中
mitce profile（uid `RB69BA9kx9fv`）的 `option.allow_auto_update` 改为 `false`。

验证：

```bash
python3 - "$APPDIR/profiles.yaml" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
it = [i for i in d['items'] if i['uid'] == 'RB69BA9kx9fv'][0]
print('allow_auto_update =', it['option'].get('allow_auto_update'))
EOF
```

Expected: `allow_auto_update = False`

- [ ] **Step 3: master 点击 mitce profile 卡片重新激活（= 本窗口唯一一次 reload）**

执行 `claude-ip-heal` 或等 enforcer 慢速路径生成 `$APPDIR/clash-verge-guard-expanded.yaml`
并对该展开文件执行 `PUT /configs`。这同时完成：运行时找回 Claude 组、找回缺失的 probe
规则、Codex-Stable 防抖进入运行时。

### Task 9: 验证门（全过才放行）

- [ ] **Step 1: 多源出口 IP（≥2/3 == $EXP_IP）**

```bash
for src in "https://ifconfig.me" "http://ping0.cc/ip" "https://api.ipify.org"; do
  printf '%s => ' "$src"; curl -4 -s --max-time 8 "$src"; echo
done
```

Expected: 至少 2/3 返回 `$EXP_IP`；单源空返回或超时按检测源故障处理，不按网络波动处理。Phase 2 后 `api.ipify.org` 规则应恢复。

- [ ] **Step 2: 运行时规则对账**

```bash
curl --unix-socket $SOCK -s http://localhost/rules | python3 -c "
import json,sys
rules=json.load(sys.stdin)['rules']
want=['api.ipify.org','ipv4.icanhazip.com','ip.sb','curl']
for w in want:
    hit=any(w in r['payload'] for r in rules)
    print(('OK  ' if hit else 'MISS'), w)
r0=rules[0]
print(('OK  ' if r0['proxy']=='DIRECT' and r0['type']=='IPCIDR' else 'MISS'), 'first-rule = socks-endpoint DIRECT')
"
```

Expected: 5 行全 `OK`（第 5 行确认 DIRECT 规则已置顶，fast-path 直测路径成立）。

- [ ] **Step 3: Codex-Stable 状态**

```bash
curl --unix-socket $SOCK -s http://localhost/proxies/Codex-Stable | python3 -c "
import json,sys; d=json.load(sys.stdin); print('now =', d['now']); print('all =', d['all'])
"
```

Expected: `all` == Task 6 记录的 runtime `all`；`now` 不要求最低延迟，只要求属于 `all` 且不因本窗口 reload 回退到旧磁盘列表。

- [ ] **Step 4: 生成文件无重复定义**

```bash
grep -c "^- name: Claude-Residential" "$APPDIR/clash-verge.yaml"
```

Expected: `1`（窗口前是 2）。

- [ ] **Step 5: enforcer 下一周期 OK + Claude 组指向正确**

```bash
sleep 35; tail -2 ~/.local/log/claude-ip-enforcer.log
curl --unix-socket $SOCK -s http://localhost/proxies/Claude | python3 -c "import json,sys; print('Claude now =', json.load(sys.stdin)['now'])"
```

Expected: `enforce OK (fast-path)`；`Claude now = Claude-Residential`。

- [ ] **Step 6: 放行**

全部通过 → 通知 master 可重开 Claude / Codex（保留开 App 前 `myip` 习惯）。把 Task 6-9 结果追记到 `WINDOW-NOTES.txt`。

### Task 10: 回滚程序（仅验证门失败时执行）

- [ ] **配置回滚**

```bash
RB=~/Scratch/20260610-clash-guard-rollback
cp "$RB/mUTAPkE8C6o0.yaml" "$APPDIR/profiles/mUTAPkE8C6o0.yaml"
```

然后 master 重新点击 mitce profile 卡片（再生成 + reload），重跑 Task 9 全部步骤。Claude 在验证通过前保持关闭。

- [ ] **脚本回滚（如 Phase 1 改动被怀疑）**

```bash
RB=~/Scratch/20260610-clash-guard-rollback
cp "$RB/claude-ip-enforce" ~/.local/bin/claude-ip-enforce
cp "$RB/claude-ip-heal.sh" ~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh
launchctl unload ~/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist
launchctl load ~/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist
```

### Task 11: 验收（24h + 7d 两次复查）

- [ ] **24h 复查**

```bash
RB=~/Scratch/20260610-clash-guard-rollback
echo "baseline:"; cat "$RB/BASELINE.txt"
echo "now:"
echo "core_reloads_total: $(grep -c 'core reloaded' ~/.local/log/claude-ip-enforcer.log)"
echo "err_log_lines: $(wc -l < ~/.local/log/claude-ip-enforcer.launchd.err.log)"
ls "$APPDIR" "$APPDIR/profiles" 2>/dev/null | grep -c '\.bak-' || echo 0
```

Expected: core_reloads_total 与窗口结束时相同（零新增）；err 行数不变；.bak 零新增。master 体感确认无断流。

- [ ] **7d 复查**

同上命令，另加订阅开关检查（Task 8 Step 2 的 python 命令），Expected `False` 保持。通过后在 git 仓库提交一条验收记录；方案 B（中转链）保持本方案范围外。
