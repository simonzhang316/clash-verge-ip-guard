# 任务书：Claude 出口切换至自建 VPS（vless+reality 直连）

> 委托对象：codex（可派 subagent）。review 出口：Claude（十七）。裁决人：master。
> 执行日期：2026-09-04。预算：单日。规格冻结：本文档即冻结规格，偏离先报 BLOCKED，不自作主张。

---

## 0. 背景与 done condition

言茜/master 的 Claude 流量长期日均 1-5 次 "API Error: terminated"（跨境长流被掐）。已建成自建 VPS 专线并完成 8h53m/108 轮过夜验证（出口零漂移、长流零中断）。本任务把 Claude 出口从「家宽 socks5（借机场第一跳）」切换为「VPS vless+reality 直连」。

**Done condition（全部满足才算完）**：
1. `curl https://api.ipify.org` 与 `https://ipv4.icanhazip.com`（走 Claude 组）双源返回本地参数文件中的 VPS server
2. `claude --model claude-fable-5 -p "回复ok"` 正常返回
3. `claude-ip-enforce.sh "$VPS_IP" "$VPS_PORT" --silent` 跑一轮后 `~/.local/state/claude-ip-guard/state.json` 为 OK
4. 手动破坏一次拓扑（把 Claude 组切到 REJECT）→ 跑 heal → 自动恢复到 Claude-VPS 且 state 回 OK
5. 家宽回滚路径演练通过：`rollback.sh` 执行后出口回 `38.45.149.73`，再 `cutover.sh` 切回 VPS
6. 言茜 bridge bot（yanqian-claude）发一条测试消息正常回复
7. repo 分支 PR 建好，含本任务全部代码改动；运行时非 git 文件的改动在 PR 描述中列明

## 1. 现状拓扑与文件地图（真相分层）

```
Claude 域名/进程 → [Claude 组 select: Claude-Residential, REJECT]
                     → [Claude-Residential 组 fallback: 4个家宽克隆]
                        每个克隆 = socks5 38.45.149.73:23695 + dialer-proxy 机场第一跳(JP3/JP1/SG5/SG4-HY2)
                     → 家宽出口 38.45.149.73
```

| 层 | 文件 | git |
|---|---|---|
| 守护脚本真相 | `~/Projects/clash-verge/skills/claude-ip-guard/scripts/{claude-ip-heal.sh, claude-ip-enforce.sh}` | ✅（当前部署分支 `feat/claude-residential-sg-backup-0902`，从它开新分支） |
| 入口 wrapper | `~/.local/bin/{claude-ip-heal, claude-ip-enforce}`（heal wrapper 内硬编码默认参数 38.45.149.73 23695） | ❌ 本地 |
| launchd | `~/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist`（args: 38.45.149.73 23695 --silent） | ❌ 本地 |
| merge 模板源 | `$BASE/profiles/` 下由 `resolve_active_merge_source()` 解析的活动 merge yaml（heal 会重写为管理态） | ❌ 本地，含家宽凭据 |
| 运行时展开 | `$BASE/clash-verge-guard-expanded.yaml`（heal `write_expanded_runtime_config()` 生成后 PUT reload） | ❌ 本地 |
| statusline | `~/claudecode_xinran/scripts/claude-statusline.py` 行25 `RESIDENTIAL_MARK = b"38.45.149.73:23695"` | ✅ claudecode_xinran repo |

`$BASE` = `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev`

VPS 连接参数（uuid / publicKey / shortId / sni / server / port）在 `~/Scratch/20260904-bwg/reality_params.txt`。**这些是凭据：只允许写入 $BASE 下的本地 yaml，禁止进 git、禁止进日志、禁止进任务产出文档。**

## 2. 目标拓扑

```
Claude 域名/进程 → [Claude 组 select: Claude-VPS, Claude-Residential, REJECT]  ← 钉 Claude-VPS
                     ├→ [Claude-VPS] vless+reality 直连本地参数文件中的 server:port → VPS 出口
                     └→ [Claude-Residential 组]（整套原样保留 = 回滚位，不再是活动路径）
```

设计裁决（已过 master）：
- VPS 与家宽之间**不做自动 fallback**（两出口 IP 不同，自动切会撞"出口恒定"守护 → enforcer 判 mismatch 拦断）。VPS 失效 = enforcer 三连败 fail-closed REJECT + 飞书告警，人工跑 rollback.sh 切回。
- 家宽 4 克隆 + Claude-Residential 组 + 其 dialer-proxy 机场链**全部原样保留**。
- 外星人（Windows）不在本任务范围；它的 Claude 线仍钉家宽，退订家宽前需二期迁移（本文 §8 已记）。

## 3. 改动清单（逐文件）

### 3.1 `skills/claude-ip-guard/scripts/claude-ip-heal.sh`

新 TARGET 语义：`TARGET_IP/TARGET_PORT` 来自本地参数文件，并同步到 wrapper/plist。家宽 IP 38.45.149.73 在脚本内新增常量 `RESIDENTIAL_IP=38.45.149.73 RESIDENTIAL_PORT=23695`（回滚位仍需 DIRECT/route-exclude 保护）。

a) `validate_full_chain_topology()`：
   - expected 4 家宽克隆校验**保留不变**（仍校验 socks5 + dialer-proxy + 凭据齐全）
   - 新增校验：存在名为 `Claude-VPS` 的 proxy，`type: vless`、`server == TARGET_IP`、`port == TARGET_PORT`、`tls: true`、`reality-opts` 含非空 `public-key`/`short-id`、`uuid` 非空、`flow: xtls-rprx-vision`、`servername` 非空、`network: tcp`、`client-fingerprint: chrome`、`udp: true`
   - Claude 组校验改为 `claude.get("proxies") == ["Claude-VPS", "Claude-Residential", "REJECT"]`
   - Claude-Residential 组校验保留原样

b) `repair_full_chain_topology()`：
   - 家宽克隆重建逻辑保留，但克隆的 server/port 用 `RESIDENTIAL_IP/RESIDENTIAL_PORT` 常量（不再用 TARGET_*，语义已让位给 VPS）
   - Claude-VPS 节点**凭据自愈**：从现有配置文件里找已存在的 `Claude-VPS` 定义（模式同 `credential_source`——在 `$BASE/clash-verge.yaml` + `$BASE/profiles/*.yaml` 的 prepend-proxies/proxies 里找 name==Claude-VPS 且 uuid/reality-opts 齐全者）作为凭据源；找到→放入 managed_proxies 首位（server/port 纠为 TARGET_*）；找不到→报错退出（exit 13，凭据不可再生，宁可失败可见，禁止造空值）
   - managed_groups 的 Claude 组改为 `["Claude-VPS", "Claude-Residential", "REJECT"]`

c) `ensure_empty_merge_templates_have_claude()`（灾难恢复 bootstrap）：
   - bootstrap 产物加入 Claude-VPS 节点（凭据源同上，找不到时保持现行为：warn + skip，并在 warn 文案注明 VPS credentials missing）
   - bootstrap 的 Claude 组含 `[Claude-VPS, Claude-Residential]`
   - `IP-CIDR,$TARGET_IP/32,DIRECT` 与 `IP-CIDR,$RESIDENTIAL_IP/32,DIRECT` 两条都写入

d) `write_expanded_runtime_config()`：
   - `qualified_names` 前插 `Claude-VPS`（缺失同样 SystemExit）
   - clean_groups 的 Claude 组 proxies 改 `["Claude-VPS", "Claude-Residential", "REJECT"]`
   - claude_rules 首条 DIRECT 改为两条：`IP-CIDR,{target_ip}/32,DIRECT,no-resolve` + `IP-CIDR,{residential_ip}/32,DIRECT,no-resolve`（residential_ip 作为新增 argv 传入）
   - `is_claude_rule()` 的 term 列表加入 residential_ip（保证旧 DIRECT 规则被归并不重复）

e) `reload_core()`：
   - route-exclude-address 改为 `["$TARGET_IP/32", "$RESIDENTIAL_IP/32", "100.64.0.0/10", "fd7a:115c:a1e0::/48"]`（家宽排除保留，回滚路径不废）
   - `set_proxy_group_choice "Claude" "Claude-Residential"` 改为 `set_proxy_group_choice "Claude" "Claude-VPS"`

f) `runtime_claude_needs_reload()`：Claude 组 all 期望改 `["Claude-VPS", "Claude-Residential", "REJECT"]`

g) `check_ip()`：活跃代码路径（前 20 行）语义不变——egress 必须 == TARGET_IP（现在即 VPS IP），无需改；**函数后半段 return 之后的死代码禁止顺手清理**（最小 diff 纪律，patch_file/harden_file 同理）

### 3.2 `skills/claude-ip-guard/scripts/claude-ip-enforce.sh`

a) `claude_group_candidates_ok()`：期望 `now == "Claude-VPS"` 且 `all == ["Claude-VPS", "Claude-Residential", "REJECT"]`
b) `claude_residential_group_ok()` 保留原样（回滚位就绪度监控）
c) `residential_socks_direct_ok()`：语义改为"回滚位健康检查"——比对目标从 `$TARGET_IP` 改为新增环境变量 `RESIDENTIAL_IP`（默认 38.45.149.73）；仅写诊断字段不参与判死
d) 其余（fail-closed / REJECT / 三连败 / 通知）全部不动。TARGET_IP 语义随 plist 参数自然切换

### 3.3 `~/.local/bin/claude-ip-heal`（wrapper，非 git）

默认参数从家宽端点切换为本地参数文件中的 VPS server/port

### 3.4 launchd plist（非 git）

`com.zhangxinran.claude-ip-enforcer.plist` ProgramArguments：家宽端点 → 本地参数文件中的 VPS server/port。改完 `launchctl bootout gui/$UID/com.zhangxinran.claude-ip-enforcer && launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist`

### 3.5 活动 merge yaml（非 git，含凭据）

heal 的凭据自愈只认已存在的 Claude-VPS 定义，所以 cutover 时须先做一次性注入：从 `~/Scratch/20260904-bwg/reality_params.txt` 读参数，把 Claude-VPS 节点写入活动 merge 的 prepend-proxies 首位（inline map 风格与现有 Claude-Residential 行一致），Claude 组同步改。之后交给 heal 走正常修复/展开流程。

节点形状（值从 params 文件读，禁止把真值写进本任务书或 commit）：
```yaml
- { name: 'Claude-VPS', type: vless, server: <server>, port: <port>, uuid: <uuid>, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: <sni>, client-fingerprint: chrome, reality-opts: { public-key: <publicKey>, short-id: <shortId> } }
```

### 3.6 `~/claudecode_xinran/scripts/claude-statusline.py`（claudecode_xinran repo）

行25 `RESIDENTIAL_MARK` 改为 `CLAUDE_EXIT_MARK`，从本地 enforcer plist 的目标参数动态读取（生产端点不写入 Git）；仅改该变量、读取函数及引用，不碰其他段。清 `__pycache__`。

### 3.7 新增 `skills/claude-ip-guard/scripts/{cutover.sh, rollback.sh}`（git）

- `cutover.sh`：①从本地参数文件读取 VPS server/port（允许环境变量显式覆盖，不把默认端点写进 Git）②备份 `$BASE/clash-verge.yaml`、活动 merge、expanded、plist 到 `~/Scratch/20260904-bwg/cutover-backup-<ts>/` ③执行 3.5 注入（若 Claude-VPS 已在则跳过）④改 wrapper + plist 参数并重挂 launchd ⑤`CLAUDE_MAINTENANCE_APPROVED=1 claude-ip-heal "$VPS_IP" "$VPS_PORT"` ⑥按 §0 done condition 1-3 自检并输出结果
- `rollback.sh`：①Claude 组切回 Claude-Residential（unix socket API）②wrapper + plist 参数回 `38.45.149.73 23695` 并重挂 ③`CLAUDE_MAINTENANCE_APPROVED=1 claude-ip-heal 38.45.149.73 23695`——注意 heal 的 validate 在两种 TARGET 语义下都必须能通过（3.1a 的校验逻辑不得依赖"TARGET 一定是 VPS"；Claude-VPS server 校验应对照 merge 内定义而非 TARGET_IP，两脚本参数仅决定 egress 期望与 route-exclude 主项。实现时若发现此处与 3.1a 冲突，按本条优先，validate 中 Claude-VPS 的 server/port 改为"与其自身定义自洽+非空"即可，报 BLOCKED 确认）
- 两脚本均须 `set -euo pipefail`、纯 ASCII 注释或英文（规避 bash 3.2 中文标点坑）、绝对路径

## 4. 全机网络耦合点扫描结果（已扫，供避坑）

| 项 | 现状 | 影响 | 动作 |
|---|---|---|---|
| bridge 6 bot（yanqian-claude 等） | claude CLI 流量走 TUN Claude 规则 | 切换瞬间掐一次流 | 无需改；cutover 卡 maintenance gate |
| yanqian-claude / vault-snapshot plist | HTTP(S)_PROXY=127.0.0.1:7897（clash mixed 端口，按规则出） | 无（出口随规则切换） | 不动 |
| statusline | 硬编码家宽 mark（§3.6） | 切后误报 | 改 |
| `PROCESS-NAME,curl,Claude` 规则 | 全机 curl 一律走 Claude 出口 | 切后所有 curl 出口 IP 变 VPS | 保留（守护探测依赖它）；已确认微信发布线休眠、无 curl 调用微信 API；微信线复活时需核对 IP 白名单（二期备忘） |
| wechat-proxy-tunnel launchd | 未加载（休眠） | 无 | **红线：不读不碰** |
| 外星人 Windows | Claude 线独立钉家宽 38.45.149.73 | 本任务不影响；**退订家宽会断它** | 二期迁移，本次只记录 |
| 听脑 sync / home-audit / lark-cli | 国内域名或走飞书 NO_PROXY | 无 | 不动 |
| codex CLI | Codex-Stable 组（机场），与 Claude 组无交集 | 无（这正是 codex 执行本任务的理由） | 不动 |
| 测试残留 | 本机 17890 mihomo 测试实例 + stability-test.sh + Chrome 测试实例 | cutover 验证通过后停掉（pid 文件在 ~/Scratch/20260904-bwg/） | cutover.sh 末尾清理 |
| 订阅自动更新 | Verge 更新订阅会重写 profile | prepend 不展开 bug（见 §5） | heal 已治，Claude-VPS 放 merge 模板内随 heal 重建 |

## 5. 历史事故清单（同类迁移翻过的车，必读）

1. **Verge prepend-* 不展开**（merge+script 组合下）：改 merge 不 reload expanded = 白改。一切运行时生效必须走 heal 的 `write_expanded_runtime_config` + PUT reload 路径。
2. **reload 风暴 / guard 打架**（0611 Claude-Fast 偏离）：只改配置不同步 heal/enforce 的期望拓扑，下一轮 heal 会把改动修回去。**三层（merge/脚本期望/plist 参数）必须在同一次 cutover 里原子切换。**
3. **maintenance gate**：heal/reload 在有活跃 Claude 连接时拒绝执行。cutover 用 `CLAUDE_MAINTENANCE_APPROVED=1` 显式越闸，越闸前先 lark 通知 master（`~/claudecode_xinran/scripts/notify-master.sh -m "..."`）。
4. **bash 3.2 中文标点吞变量名**：脚本内中文注释邻接 `$VAR` 会炸。新脚本纯 ASCII 注释。
5. **launchd PATH 无 /usr/local/bin**：脚本内用绝对路径或显式 export PATH。
6. **REALITY dest 禁用微软/谷歌系**（ML-KEM 后量子握手把 xray 带坑，0903 实翻车）：当前 dest 只存本地参数文件，任何人（含 heal）不得"顺手"改回 microsoft/google 系。
7. **敏感值不进 git/日志**（家宽 socks 凭据曾泄露进 settings.local.json）：reality uuid/publicKey/shortId 同级对待。
8. **fail_count/state 残留**：cutover 完成后 `set_fail_count 0` + state OK（cutover.sh 里显式清 `~/.local/state/claude-ip-enforcer.{state,fail_count}`），避免旧 WARN 计数把新链路顶进 BLOCK。

## 6. 执行序列

1. codex 从 `feat/claude-residential-sg-backup-0902` 开分支 `feat/claude-vps-cutover-0904`
2. 完成 §3 全部代码改动（3.1/3.2/3.7 进 repo；3.3/3.4/3.5 写成 cutover.sh 内动作，不直接执行）
3. `bash -n` 全部脚本 + 用临时 BASE fixture 跑 validate/repair 的 dry 测试（fixture 里 Claude-VPS 用假凭据，fixture 放 /tmp，用完删）
4. 提 PR（不合并）→ **停，等 Claude review**（BLOCKED 裁决环：规格冲突/不明处在 PR 描述列问题，不自行拍板）
5. review 通过后：lark 通知 master → codex 执行 `cutover.sh`（含 §0 done 1-3 自检）
6. Claude 侧恢复连接后做 done 4-6 验证（拓扑破坏恢复演练、回滚演练、言茜 bot 冒烟）
7. statusline 改动在 claudecode_xinran repo 单独 commit

## 7. 禁改清单

- 网络红线原文有效：clash-verge service/TUN 其他设置、wechat-proxy-tunnel、claude-ip-enforcer 之外的 launchd 项一律不碰
- 不删任何 .bak；不清 heal/enforce 里的死代码；不 reformat；不动订阅 profile 内容
- 不升级 Verge/mihomo 内核（已验证 stable 1.19.21 兼容）
- Claude Code CLI 版本（npm 2.1.112）本任务不动（版本试验是切换稳定后的独立变量）

## 8. 二期备忘（本任务不做）

- 外星人 Windows Claude 线迁 VPS（退订家宽前必须完成）
- 微信发布线复活时核对 API IP 白名单 vs 新出口
- Claude Code 最新版试验（先查 issue #84404 现状）
- 家宽订阅观察两周后退订（master 裁决）
