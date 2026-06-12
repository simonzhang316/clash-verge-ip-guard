# Clash Verge 守护层稳定性修复 — 设计文档

日期：2026-06-10
状态：已获 master 批准
范围：方案 A（守护层修复 + Codex fallback 防抖），不动 Claude 出口链路；
目标只覆盖 Clash Verge / mihomo / 守护脚本造成的抖动，不评估机场或家宽线路质量。

> 安全约定：本文档入库，所有敏感值用占位符。
> `<EXPECTED_IP>` / `<EXPECTED_PORT>` = 家宽静态出口 IP / SOCKS5 端口（真实值仅存在于本地
> LaunchAgent plist 与本地配置中，不入 git）。

---

## 1. 背景与诊断结论

体感症状：Claude Code 请求中断、全网抖动、IP 漂移告警频繁、延迟测试爆红。

诊断实锤（2026-06-10，日志与运行时 API 取证）：

1. **mihomo core 被每 ~105 秒 reload 一次，全天持续**。
   `claude-ip-enforcer`（LaunchAgent，StartInterval=30s）几乎每轮都调用 `claude-ip-heal`，
   heal 每轮都对 `profiles.yaml` 做 `state-updated` 改写并触发 core reload
   （日志 `HEAL_CHANGED=2`，累计 1191 次 reload、6.5 万次 enforce、日志 200 万行）。
   每次 reload 冲击所有在途连接——这是断流/抖动的第一来源，且对防封号毫无贡献。
2. **heal 与 Clash Verge 互相改写 `profiles.yaml`，永不收敛**；配置目录堆积数百个 `.bak`。
3. **mitce 订阅 `allow_auto_update: true`（60 分钟）**，违反本项目文档「检查一」硬性要求，
   每小时制造一次 drift 窗口。
4. **运行时配置与磁盘 merge 不一致**：运行规则缺失磁盘 merge 中的 5 条
   （`api.ipify.org`、`ipv4.icanhazip.com`、`ip.sb`、`PROCESS-NAME,curl`、家宽 IP DIRECT 条目），
   导致多源 IP 检测结果不一致（ifconfig.me 返回家宽 IP，api.ipify.org 返回 HK 节点 IP）。
5. **enforcer 脚本 line 246 bash 算术语法错误**（`"0" + 1`），失败计数路径每 30 秒崩一次，
   真故障时的 failover / 拦截升级逻辑从未真正生效。
6. **守护脚本越权管理全局出口**：`claude-ip-enforce` / `claude-ip-heal` 每轮都尝试设置
   `主代理`、`狗狗加速.com`、`GLOBAL`，并按延迟探测自动切换全局出口。日志里已有大量
   `egress switch`，这会把 Claude 固定 IP 守护扩大成全局网络拨杆，是抖动来源之一。
7. **Codex-Stable fallback 缺少防抖**，偶发超时即可触发切换。这里仅修 Clash fallback
   行为，不做机场节点测速优化。

结论：出口链路设计（TUN → 置顶规则 → 家宽 SOCKS5）本身健康，当前出口 IP 正确。
不稳定性集中在 Clash Verge 生成配置、mihomo reload、自动化守护层越权拨动全局出口；
修复无需触碰任何决定 Claude 出口 IP 的配置。

## 2. 目标与非目标

**目标**

- 消除周期性 core reload（修复后日常 reload 次数 ≈ 0）。
- 防封号守护能力不减：fail-closed（IP 不对 → 拦截 Claude）全程保留。
- Codex 兜底防抖：保留既有候选列表语义，只增加连续失败阈值，避免偶发超时切换。
- Claude IP 守护只管理 Claude 相关运行时状态，不再自动拨动 `GLOBAL` / 主代理 / 狗狗出口。
- 每一步可回滚，验证门不过不放行。

**非目标 / 不动产清单（红线）**

- 不动 TUN 配置、verge.yaml。
- 不动 `Claude-Residential` 节点定义与 Claude 域名规则。
- 不动订阅内容本身（只关其自动更新开关）。
- 不做家宽前中转链（方案 B 内容，A 稳定运行一周后另行评估）。
- 不合并 Claude / Codex 出口（已评估并否决：配额、故障域、暴露面三重代价）。
- 不按机场/家宽延迟选择节点，不以测速优劣作为本方案验收标准。

## 3. 设计

### 3.1 Phase 1 — 脚本修复（不触碰运行中的 mihomo）

**`~/.local/bin/claude-ip-enforce`**

- 修复 line 246 算术 bug（引号进入 `$(( ))` 导致 `set -e` 下整脚本崩溃）。
- 控制流重构为「先查运行时不变量，再修」：
  1. 先检查 mihomo 运行时：socket 可达、mode == `rule`、TUN 开启、
     `Claude` 组指向 `Claude-Residential`、Claude 域名规则与 Claude Code 进程规则存在
     （含 `claudeusercontent.com`，否则 bridge 连接会落回通用代理）、
     住宅 SOCKS 本体出口 IP == `<EXPECTED_IP>`。
     这一步不依赖 `api.ipify.org` / `ip.sb` 等当前缺失的 probe 规则。
     住宅 SOCKS 本体校验中，空响应/超时按检测源故障处理；至少 1 个源明确命中且没有源
     明确返回非目标 IPv4，即可走 fast-path。
     mode/TUN 必须纳入不变量：global 模式回归会绕过全部 Claude 规则，
     而组指向/规则列表/SOCKS 本体三项检查在该状态下仍会通过（fail-open 洞）。
  2. 不变量正确 → 记录 `enforce OK (fast-path)`，**零写入、零 heal、零 reload、零 GLOBAL 切换**，退出。
  3. 仅当 Claude 运行时不变量损坏或住宅 SOCKS 出口不对 → 调用 heal；heal 后二次核验；
     仍失败 → 现有 fail-closed 路径（Claude 组切 REJECT + 退出 Claude 应用 + 告警）原样保留。
  4. 移除默认全局出口 failover。`GLOBAL` / `主代理` / `狗狗加速.com` 不属于 Claude IP 守护职责，
     不再由 30s enforcer 周期自动切换。

**`claude-ip-heal`（`~/.local/bin/claude-ip-heal` 与项目内副本同步修改）**

- 幂等化：逐文件比对，内容无差异 → 不写文件、不产生 `.bak`。
- **仅当本轮实际写入过核心源配置才 reload core**；`profiles.yaml` 的 state 写入逻辑改为
  「目标字段值已正确则跳过」，消除与 Verge 的互写循环。
- heal 的运行时修复只保留 Claude 必需项：rule mode、TUN enable、route exclude、Claude 组。
  不再设置 `主代理`、`狗狗加速.com`、`GLOBAL`。
- 当运行时丢失 Claude 组或 Claude 规则时，heal 从 `clash-verge.yaml` 生成
  `clash-verge-guard-expanded.yaml`：展开 Verge 的 `prepend-*` merge 键后再交给 mihomo
  reload，避免 mihomo 直接忽略 `prepend-*` 导致 Claude 组/规则缺失。
- `.bak` 活跃目录保留上限 20 份，超出部分移动归档；现存历史 `.bak` 归档至
  `~/Archive/2026/clash-verge-bak-20260610/`。

Phase 1 完成判定：连续 3 个 enforcer 周期日志为 `enforce OK`，无 heal 调用、无 reload、
err 日志无新增报错。

### 3.2 Phase 2 — 受控窗口配置修正（唯一一次 reload）

前置条件：master 确认 Claude（桌面端 + CLI）与 Codex CLI 全部关闭。

窗口内顺序执行：

1. 备份（见 3.3）。
2. mitce 订阅 `option.allow_auto_update: false`、`update_interval` 保留但不再自动触发。
3. Codex-Stable 防抖（merge 文件 `mUTAPkE8C6o0.yaml`）：
   - 不做测速选线；节点列表以当前已在运行时使用的列表为准，避免 reload 后回退到过期磁盘列表。
   - 增加 `max-failed-times: 3`（连续 3 次健康检查失败才判死）。
   - `interval: 600` → `300`（真故障检出更快），保留 `lazy: true`。
   - 组类型保持 `fallback`（自动切换 + 首选恢复自动切回，兜底语义不变）。
   - 同窗口内把 `IP-CIDR,<EXPECTED_IP>/32,DIRECT` 移至 prepend-rules 首位：
     `PROCESS-NAME,curl` 规则恢复后会先于它匹配，把 enforcer fast-path 的
     SOCKS 本体直测拉进家宽自环；置顶恢复该规则本意，并使 fast-path 测试
     路径与 mihomo 拨家宽的真实路径一致。
4. 一次 core reload，同步磁盘 ↔ 运行时；reload 输入为展开后的
   `clash-verge-guard-expanded.yaml`，自然找回缺失的 Claude 组与 probe 规则。
5. 验证门（全部通过才通知 master 可重开应用）：
   - Claude 运行时不变量正确，住宅 SOCKS 本体出口 IP == `<EXPECTED_IP>`。
   - 运行时规则数量与磁盘 merge 对账（含此前缺失的 5 条）。
   - `Codex-Stable` 组 `all` 与窗口前 runtime 列表一致，`now` 不因 reload 回退到旧磁盘列表。
   - enforcer 下一周期 `enforce OK`。

### 3.3 回滚设计

- 改动前所有目标文件复制到 `~/Scratch/20260610-clash-guard-rollback/`
  （脚本 2 份、LaunchAgent plist、profiles.yaml、merge yaml）。
- 回滚操作 = 整体复制回原位 + `launchctl unload/load` enforcer + 一次 reload。
- Phase 2 验证门失败 → 立即回滚配置 → reload → 重新验证；验证不过，Claude 保持关闭，
  绝不带病放行。
- 最坏失败模式分析：脚本改坏 = 退回「过度修复」的现状；不存在「放行非家宽 IP」的
  失败路径——拦截是 enforcer 的默认分支。

### 3.4 错误处理

- enforcer 住宅 SOCKS 本体校验中单源超时：按运行手册既有约定，2/3 一致即放行，
  单源故障不算漂移；不再用当前运行时缺失的 probe 规则作为 Phase 1 fast-path 前置条件。
- 受控窗口中 reload 后 mihomo 不可达：等待 10s 重试 3 次；仍失败 → 回滚 + 通过
  Clash Verge 应用层重启核心。
- 订阅自动更新开关被 Verge UI 操作覆盖回 true：验收期每日检查一次，连续 7 天保持 false
  视为稳定。

## 4. 验收标准

| 项 | 现状基线 | 目标 |
|---|---|---|
| core reload 频率 | ~每 105 秒一次（日均数百次） | 日常 0 次（仅受控窗口 1 次） |
| enforcer err 日志 | 每 30s 一条语法错误 | 零新增 |
| `.bak` 增长 | 每小时新增 | 零增长 |
| Claude 运行时不变量 | probe 规则缺失，fast-path 不可用 | Claude 组/规则/SOCKS 本体均正确，`claudeusercontent.com` 与 `claude.exe` 不外漏 |
| 全局出口拨动 | 守护层频繁切 GLOBAL | 守护层 0 次切 GLOBAL |
| Codex-Stable 防抖 | 偶发失败即可切换 | 连续失败才切换，不做测速优化 |
| 体感 | 断流/爆红/告警频繁 | 24h 观察无断流，7 天复查 |

## 5. 实施顺序与门禁

1. Phase 1 脚本修复 → 观察 3 周期 → 通过才进 Phase 2。
2. Phase 2 需 master 在场确认应用关闭（涉及唯一一次 reload）。
3. 验收期 24h + 7 天两次复查（reload 计数、.bak、err 日志、订阅开关）。
4. 方案 B（中转链提速）冻结，A 稳定一周后由 master 决定是否评估。
