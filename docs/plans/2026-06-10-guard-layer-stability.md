# Clash Verge 守护层稳定性修复 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除 mihomo core 每 ~105 秒一次的周期性 reload，守护（防封号）能力不减，Codex fallback 兜底加强。

**Architecture:** 两阶段。Phase 1 修脚本（enforce 先查后修、heal 停止改写 Verge 生成文件），全程不触碰运行中的 mihomo。Phase 2 在 master 在场的受控窗口内做唯一一次配置重载（关订阅自动更新 + Codex 防抖 + 磁盘/运行时同步），前后过验证门。

**Tech Stack:** bash、mihomo REST API（unix socket `/tmp/verge/verge-mihomo.sock`）、launchd、Clash Verge Rev。

**对应设计文档:** `docs/specs/2026-06-10-guard-layer-stability-design.md`

---

## 红线（每个任务执行前默念）

1. 任何时刻不允许 Claude 流量从非家宽 IP 出口；fail-closed（IP 不对 → 拦截 Claude）逻辑必须保留。
2. 不动 TUN 配置、`Claude-Residential` 定义、Claude 域名规则、订阅内容、verge.yaml。
3. Phase 1 不触发任何 core reload；Phase 2 只允许一次，且 master 确认 Claude/Codex 已关闭。
4. 每个文件改动前先备份；验证门不过立即回滚，不带病放行。

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
| `~/.local/bin/claude-ip-enforce` | 修改 | 30s 周期守卫：先查 IP，正确则零动作 |
| `~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh` | 修改 | 漂移修复：只改源文件，不碰 Verge 生成物 |
| `~/Projects/clash-verge-ip-guard/skills/claude-ip-guard/scripts/claude-ip-heal.sh` | 同步 | git canonical 副本 |
| `$APPDIR/profiles/mUTAPkE8C6o0.yaml` | 修改（Phase 2） | mitce merge：Codex-Stable 防抖 |
| `$APPDIR/profiles.yaml` | UI 间接修改（Phase 2） | mitce `allow_auto_update: false` |
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

三处改动：line 246 算术 bug、新增 `egress_ip_ok` 快速路径、选择器 PUT 改为差异时才发。

- [ ] **Step 1: 修 line 246 算术 bug**

原文（line 246）：

```bash
  fail_count=$(( "$(current_fail_count)" + 1 ))
```

改为（`$(( ))` 内不得有引号，这是每 30 秒崩一次的根源）：

```bash
  fail_count=$(( $(current_fail_count) + 1 ))
```

- [ ] **Step 2: 在 `notify()` 函数之后新增两个函数**

插入位置：line 57（`notify` 的收尾 `}` 之后）。

```bash
# Fast-path egress check: 3 sources, pass when >=2 return the target IP.
# Single-source failure is treated as source outage, not drift (runbook rule).
egress_ip_ok() {
  local hits=0 ip src
  for src in "https://ifconfig.me" "http://ping0.cc/ip" "https://api.ipify.org"; do
    ip="$(/usr/bin/curl -4 -s --max-time 6 "$src" 2>/dev/null | tr -d '\r\n')"
    if [[ "$ip" == "$TARGET_IP" ]]; then
      hits=$((hits + 1))
      [[ "$hits" -ge 2 ]] && return 0
    fi
  done
  return 1
}

# Set a selector only when its current choice differs (avoids selector churn).
ensure_group_quiet() {
  local group="$1" choice="$2" now
  now="$(current_group_choice "$group" 2>/dev/null || true)"
  [[ "$now" == "$choice" ]] && return 0
  set_group_choice "$group" "$choice" >/dev/null 2>&1 || true
}
```

注意：`egress_ip_ok` 引用了 `current_group_choice`/`set_group_choice` 之前定义的 `TARGET_IP`，而 `ensure_group_quiet` 引用的两个函数定义在 line 93-109 —— 函数体在调用时才解析，bash 中此顺序合法。

- [ ] **Step 3: `manage_egress_failover` 内 3 处无条件 PUT 改为 quiet 版**

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

- [ ] **Step 4: 主流程加快速路径**

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

# Fast path: egress already correct -> keep failover watch, zero heal, zero reload.
if egress_ip_ok; then
  manage_egress_failover || true
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
  echo "[$(date '+%F %T')] egress mismatch -> invoking heal"
} >> "$LOG_FILE"

if "$HEAL_BIN" "$TARGET_IP" "$TARGET_PORT" >> "$LOG_FILE" 2>&1; then
```

慢速路径（heal 成功后的 `ensure_group_choice "Claude" "Claude-Residential"`、二次核验、`handle_enforce_failure`）全部保留原样——这是 fail-closed 的主干。

- [ ] **Step 5: 语法检查**

```bash
bash -n ~/.local/bin/claude-ip-enforce && echo SYNTAX-OK
```

Expected: `SYNTAX-OK`

- [ ] **Step 6: 手动跑一次（非 silent、不杀 Claude）验证快速路径**

```bash
~/.local/bin/claude-ip-enforce "$EXP_IP" "$EXP_PORT" --no-quit; echo "exit=$?"
tail -3 ~/.local/log/claude-ip-enforcer.log
```

Expected: `exit=0`；日志末尾出现 `enforce OK (fast-path)`；**没有** `[claude-ip-heal]` 行。

- [ ] **Step 7: 确认 err 日志不再新增语法错误**

```bash
wc -l < ~/.local/log/claude-ip-enforcer.launchd.err.log; sleep 70; wc -l < ~/.local/log/claude-ip-enforcer.launchd.err.log
```

Expected: 两次行数相同（launchd 的 30s 周期跑了 2 次都没报错）。

### Task 3: 修复 claude-ip-heal.sh（实际生效副本）

**Files:**
- Modify: `~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh`

三处改动：main() 不再改写 Verge 生成文件、profiles.yaml 改写不触发 reload、加 .bak 保留上限。

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

- [ ] **Step 3: 新增 prune_baks 函数并在 main() 中调用**

在 `reload_core()` 函数定义之前（line 706 前）插入：

```bash
# Cap .bak retention at 20 per source file (approved design 3.1).
prune_baks() {
  local src keep=20
  for src in "$BASE"/*.yaml "$BASE"/profiles/*.yaml; do
    [[ -f "$src" ]] || continue
    ls -t "$src".bak-* 2>/dev/null | tail -n +$((keep + 1)) | while IFS= read -r f; do
      rm -f "$f"
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
  prune_baks
  reload_core
  sleep 1
  check_ip
```

- [ ] **Step 4: 语法检查**

```bash
bash -n ~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh && echo SYNTAX-OK
```

Expected: `SYNTAX-OK`

- [ ] **Step 5: 手动跑一次 heal 验证幂等**

```bash
~/.local/bin/claude-ip-heal "$EXP_IP" "$EXP_PORT"; echo "exit=$?"
```

Expected: `exit=0`；输出中**没有** `injected-claude-core`/`injected-doggo-fallback`/`hardened:` 指向 `clash-verge.yaml` 或 `clash-verge-check.yaml` 的行；出现 `core reload skipped (no on-disk change this run)`；最后 `OK: static residential IP restored`。

- [ ] **Step 6: 出口 IP 复核（红线检查）**

```bash
curl -4 -s --max-time 8 ifconfig.me; echo; curl -4 -s --max-time 8 ping0.cc/ip; echo
```

Expected: 两个都返回 `$EXP_IP`。

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

Expected: 日志全部为 `enforce start` + `enforce OK (fast-path)` 成对出现；reload 计数与 Step 1 完全相同；无 `[claude-ip-heal]` 行。

任一不符 → 停止，按 Task 9 回滚脚本，重新诊断。

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

Expected: 归档前两个计数为数百，归档后为 0。

- [ ] **Step 2: 同步 heal.sh 到 canonical 仓库并提交**

```bash
cp ~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh \
   ~/Projects/clash-verge-ip-guard/skills/claude-ip-guard/scripts/claude-ip-heal.sh
cd ~/Projects/clash-verge-ip-guard
git add skills/claude-ip-guard/scripts/claude-ip-heal.sh docs/plans/2026-06-10-guard-layer-stability.md
git commit -m "fix(heal): stop mutating verge-generated configs; ui-state writes no longer trigger core reload

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

提交前自查：`grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' skills/claude-ip-guard/scripts/claude-ip-heal.sh` 确认无个人 IP 入库（脚本经参数/环境变量取值）。

---

# Phase 2 — 受控窗口（需 master 在场，唯一一次 reload）

**进入条件：** Task 4 验收门通过，且观察期内无异常。

### Task 6: 窗口前 Codex 节点体检

- [ ] **Step 1: 列出 mitce 订阅中的候选节点并逐个测延迟**

```bash
curl --unix-socket $SOCK -s http://localhost/proxies | python3 -c "
import json,sys
ps=json.load(sys.stdin)['proxies']
names=[n for n,p in ps.items() if p.get('type') in ('Hysteria2','AnyTLS','Trojan','Vless') and any(k in n for k in ('JP','SG','HK','HY2'))]
print('\n'.join(sorted(names)))
"
```

对列出的每个候选（重点 JP/SG）：

```bash
test_node() {
  enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1")
  curl --unix-socket $SOCK -s --max-time 12 \
    "http://localhost/proxies/$enc/delay?url=https%3A%2F%2Fchatgpt.com%2Fcdn-cgi%2Ftrace&timeout=8000"
  echo " <= $1"
}
test_node "JP2-HY2"; test_node "JP3-HY2"; # ...对全部候选执行
```

- [ ] **Step 2: 定新列表**

选择规则：返回 `{"delay":N}` 的节点中取延迟最低的 5 个，JP/SG 优先（与 OpenAI 出口地区一致性好），首选 = 最低延迟者。记录到窗口记录文件 `~/Scratch/20260610-clash-guard-rollback/WINDOW-NOTES.txt`。

### Task 7: 编辑 merge（Codex-Stable 防抖）

**Files:**
- Modify: `$APPDIR/profiles/mUTAPkE8C6o0.yaml`

- [ ] **Step 1: 替换 Codex-Stable 组定义**

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

改为（节点列表用 Task 6 实测结果替换，下面是格式示例）：

```yaml
  - name: Codex-Stable
    type: fallback
    proxies:
      - <实测最优节点>
      - <实测次优节点>
      - <实测第三>
      - <实测第四>
      - <实测第五>
    url: 'https://chatgpt.com/cdn-cgi/trace'
    interval: 300
    lazy: true
    max-failed-times: 3
```

语义：fallback 自动切换/自动切回保留；`max-failed-times: 3` = 连续 3 次健康检查失败才判死（防偶发超时抖动）；`interval: 300` = 真故障最迟 5 分钟检出。

- [ ] **Step 2: YAML 语法校验**

```bash
python3 -c "import yaml; yaml.safe_load(open('$APPDIR/profiles/mUTAPkE8C6o0.yaml')); print('YAML-OK')"
```

Expected: `YAML-OK`。此时只改了磁盘文件，运行时尚未受影响。

### Task 8: master 现场操作 + 唯一一次 reload

- [ ] **Step 1: master 确认三件事并口头回复**

1. Claude 桌面端已退出；2. 所有 Claude Code CLI 会话已结束（本 session 除外，它走 `NO_PROXY` 不受影响——仍建议空闲）；3. Codex CLI 已退出。

- [ ] **Step 2: master 在 Verge UI 关闭 mitce 订阅自动更新**

操作：Clash Verge → 订阅页 → mitce 卡片右键/编辑 → 关闭「自动更新」开关。

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

Verge 会从 profile + merge 源重新生成 `clash-verge.yaml` 并重载 core。这同时完成：merge 改动生效、运行时找回缺失的 5 条规则、清掉历史注入造成的重复定义。

### Task 9: 验证门（全过才放行）

- [ ] **Step 1: 多源出口 IP（≥2/3 == $EXP_IP）**

```bash
for src in "https://ifconfig.me" "http://ping0.cc/ip" "https://api.ipify.org"; do
  printf '%s => ' "$src"; curl -4 -s --max-time 8 "$src"; echo
done
```

Expected: 三源全部返回 `$EXP_IP`（Phase 2 后 `api.ipify.org` 规则已恢复，应三源一致）。

- [ ] **Step 2: 运行时规则对账**

```bash
curl --unix-socket $SOCK -s http://localhost/rules | python3 -c "
import json,sys
rules=json.load(sys.stdin)['rules']
want=['api.ipify.org','ipv4.icanhazip.com','ip.sb','curl']
for w in want:
    hit=any(w in r['payload'] for r in rules)
    print(('OK  ' if hit else 'MISS'), w)
"
```

Expected: 4 行全 `OK`。

- [ ] **Step 3: Codex-Stable 状态**

```bash
curl --unix-socket $SOCK -s http://localhost/proxies/Codex-Stable | python3 -c "
import json,sys; d=json.load(sys.stdin); print('now =', d['now']); print('all =', d['all'])
"
```

Expected: `now` == Task 6 选出的首选节点；`all` == 新 5 节点列表。

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

同上命令，另加订阅开关检查（Task 8 Step 2 的 python 命令），Expected `False` 保持。通过后在 git 仓库提交一条验收记录，方案 B（中转链）是否评估由 master 决定。
