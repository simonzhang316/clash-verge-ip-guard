# Clash Verge 守护层稳定性修复 — 设计文档

日期：2026-06-10
状态：已获 master 批准
范围：方案 A（守护层修复 + Codex fallback 防抖），不动 Claude 出口链路

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
6. **Codex-Stable fallback 备选 5 节点实测 3 个不可用**（JP1/HK2/HK3 延迟测试失败），
   实际兜底厚度远低于预期；且偶发超时即切换造成 JP↔HK 出口国家横跳。

结论：出口链路设计（TUN → 置顶规则 → 家宽 SOCKS5）本身健康，当前出口 IP 正确。
不稳定性集中在自动化守护层，修复无需触碰任何决定出口 IP 的配置。

## 2. 目标与非目标

**目标**

- 消除周期性 core reload（修复后日常 reload 次数 ≈ 0）。
- 防封号守护能力不减：fail-closed（IP 不对 → 拦截 Claude）全程保留。
- Codex 兜底加强：备选列表全部健康、真死才切、恢复自动切回。
- 每一步可回滚，验证门不过不放行。

**非目标 / 不动产清单（红线）**

- 不动 TUN 配置、verge.yaml。
- 不动 `Claude-Residential` 节点定义与 Claude 域名规则。
- 不动订阅内容本身（只关其自动更新开关）。
- 不做家宽前中转链（方案 B 内容，A 稳定运行一周后另行评估）。
- 不合并 Claude / Codex 出口（已评估并否决：配额、故障域、暴露面三重代价）。

## 3. 设计

### 3.1 Phase 1 — 脚本修复（不触碰运行中的 mihomo）

**`~/.local/bin/claude-ip-enforce`**

- 修复 line 246 算术 bug（引号进入 `$(( ))` 导致 `set -e` 下整脚本崩溃）。
- 控制流重构为「先查后修」：
  1. 多源校验当前出口 IP（≥2/3 源一致判定）。
  2. IP == `<EXPECTED_IP>` → 记录 `enforce OK`，**零写入、零 heal、零 reload**，退出。
  3. 仅当 IP 漂移或校验失败 → 调用 heal；heal 后二次核验；仍失败 → 现有 fail-closed
     路径（Claude 组切 REJECT + 退出 Claude 应用 + 告警）原样保留。

**`claude-ip-heal`（`~/.local/bin/claude-ip-heal` 与项目内副本同步修改）**

- 幂等化：逐文件比对，内容无差异 → 不写文件、不产生 `.bak`。
- **仅当本轮实际写入过文件才 reload core**；`profiles.yaml` 的 state 写入逻辑改为
  「目标字段值已正确则跳过」，消除与 Verge 的互写循环。
- `.bak` 保留上限 20 份，超出自动清理；现存历史 `.bak` 归档至
  `~/Archive/2026/clash-verge-bak-20260610/`。

Phase 1 完成判定：连续 3 个 enforcer 周期日志为 `enforce OK`，无 heal 调用、无 reload、
err 日志无新增报错。

### 3.2 Phase 2 — 受控窗口配置修正（唯一一次 reload）

前置条件：master 确认 Claude（桌面端 + CLI）与 Codex CLI 全部关闭。

窗口内顺序执行：

1. 备份（见 3.3）。
2. mitce 订阅 `option.allow_auto_update: false`、`update_interval` 保留但不再自动触发。
3. Codex-Stable 防抖（merge 文件 `mUTAPkE8C6o0.yaml`）：
   - 备选列表替换为窗口当时实测健康的节点（实测命令：mihomo API delay test）。
   - 增加 `max-failed-times: 3`（连续 3 次健康检查失败才判死）。
   - `interval: 600` → `300`（真故障检出更快），保留 `lazy: true`。
   - 组类型保持 `fallback`（自动切换 + 首选恢复自动切回，兜底语义不变）。
4. 一次 core reload，同步磁盘 ↔ 运行时（自然找回缺失的 5 条规则）。
5. 验证门（全部通过才通知 master 可重开应用）：
   - 多源出口 IP 一致且 == `<EXPECTED_IP>`（ifconfig.me / api.ipify.org / icanhazip ≥2/3）。
   - 运行时规则数量与磁盘 merge 对账（含此前缺失的 5 条）。
   - `Codex-Stable` 组 `now` == 首选健康节点。
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

- enforcer 多源校验中单源超时：按运行手册既有约定，2/3 一致即放行，单源故障不算漂移。
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
| 多源 IP 检测 | 源间不一致（规则缺失） | 全源一致 == `<EXPECTED_IP>` |
| Codex-Stable 备选健康度 | 5 中 3 死 | 全部健康，首选不跳变 |
| 体感 | 断流/爆红/告警频繁 | 24h 观察无断流，7 天复查 |

## 5. 实施顺序与门禁

1. Phase 1 脚本修复 → 观察 3 周期 → 通过才进 Phase 2。
2. Phase 2 需 master 在场确认应用关闭（涉及唯一一次 reload）。
3. 验收期 24h + 7 天两次复查（reload 计数、.bak、err 日志、订阅开关）。
4. 方案 B（中转链提速）冻结，A 稳定一周后由 master 决定是否评估。
