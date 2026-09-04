# 任务书：出口监控生态迁移 VPS + 双克隆真相合并

> 委托对象：codex。review 出口：Claude（十七）。前置：taskbook-vps-cutover-0904.md 已完成（出口已切 VPS，enforcer/heal 已迁移，运行分支 feat/claude-vps-cutover-0904）。
> 预算：半日。规格冻结，偏离报 BLOCKED。

## 0. 背景与 done condition

主守护已随 cutover 迁移，但外围监控还钉着旧世界：cockpit（ip-monitor 面板）从一个停在 0807 的陈旧克隆运行，statusline 的出口告警标记还是家宽端点。另发现真相分裂：`~/Projects/clash-verge`（现役）与 `~/Projects/clash-verge-ip-guard`（陈旧 main@9ea76f7）是同一 repo 的两个克隆，违反"真相唯一"，本任务一并合并。

**Done condition**：
1. cockpit launchd 从 `~/Projects/clash-verge/ip-monitor/` 运行，dashboard HTTP 可达且出口显示 `23.106.156.254`
2. cockpit 的 recheck（launchctl kickstart enforcer）实测一轮，state.json 保持 OK
3. statusline 渲染正常且出口段反映 VPS 端点（跑一次真实 statusline 调用验证，耗时预算 ≤50ms 不回归）
4. `~/Projects/clash-verge-ip-guard/` 整目录归档至 `~/Archive/2026/clash-verge-ip-guard-stale-clone-0904/`（master 已在本任务书批准此移动；只 mv 不 rm）
5. 全机 `grep -r "38.45.149.73" 活动代码路径` 仅剩合法引用（heal/enforce/rollback 的 RESIDENTIAL_* 常量与回滚脚本、备份/归档文件）
6. 改动分别落 PR：clash-verge 仓（本仓，追加到 feat/claude-vps-cutover-0904 或新分支均可，报告选择）；claudecode_xinran 仓（statusline，走分支+PR）

## 1. 改动清单

### 1.1 双克隆合并（运行时，非 git）

- `~/Library/LaunchAgents/com.zhangxinran.cockpit.plist` 中 `ProgramArguments` 的脚本路径：`/Users/zhangxinran/Projects/clash-verge-ip-guard/ip-monitor/ip_monitor_server.py` → `/Users/zhangxinran/Projects/clash-verge/ip-monitor/ip_monitor_server.py`；同 plist 内如有其他引用旧克隆路径的项一并换
- 重挂：`launchctl bootout gui/$UID/com.zhangxinran.cockpit` + `bootstrap`
- 面板 token / 状态文件如存于旧克隆目录内（先查 `load_or_create_token` 的落点），迁至新路径同位置，保持 token 值不变
- 验证 done-1/2 后，把 `~/Projects/clash-verge-ip-guard/` `mv` 到 `~/Archive/2026/clash-verge-ip-guard-stale-clone-0904/`（严禁 rm；mv 前确认无未推送 commit / 未跟踪文件——`git status` 干净即可动，不干净报 BLOCKED）

### 1.2 `ip-monitor/ip_monitor_server.py`（本仓）

- `op_select_group` 的保护判断（行145 附近）：现为 `if "Claude-Residential" in (info.get("all") or [])`，扩展为 Claude-VPS 同级保护：`any(x in (info.get("all") or []) for x in ("Claude-VPS", "Claude-Residential"))`——防止有人从面板把 Claude 组切走
- 通读全文，凡显示/注释语义仍假设"出口=家宽"处做最小适配（display 字段直接透传 state.json 的可不动）
- `index.html` 内 1 处 residential 字样文案核对，语义过时则改为中性的"Claude 出口"

### 1.3 `~/claudecode_xinran/scripts/claude-statusline.py`（claudecode_xinran 仓）

沿用上一本任务书 §3.6 冻结规格：行25 `RESIDENTIAL_MARK = b"38.45.149.73:23695"` → 改名 `CLAUDE_EXIT_MARK`，值改为**运行时从 enforcer plist ProgramArguments 读取**（`/Users/zhangxinran/Library/LaunchAgents/com.zhangxinran.claude-ip-enforcer.plist`，读 args[1]:args[2] 拼 `ip:port`，带异常兜底：读不到时该告警段静默跳过勿抛错）。生产端点真值不进 git。只改该变量、其读取逻辑与引用；耗时预算敏感（现 31ms），plist 读取加 mtime 缓存或一次性读取。清 `__pycache__`。

## 2. 已核事实（避免重查）

- 现役克隆 = `~/Projects/clash-verge`（wrappers 与 cutover 均指此），分支 feat/claude-vps-cutover-0904，PR #13 未合并
- 陈旧克隆 = `~/Projects/clash-verge-ip-guard`，main@9ea76f7（0807），git 关系已确认同 remote
- cockpit 现役 PID 存在，从陈旧克隆运行 homebrew python3.14
- ip_monitor_server.py 626 行，核心为读 state.json + mihomo unix socket + kickstart，无家宽 IP 硬编码
- 全机残余 38.45.149.73 活动引用仅 statusline 一处（scripts 扫描已做）

## 3. 禁改清单

- 不动 heal/enforce/cutover/rollback（上一任务已收）；不动 TUN/网络其他 launchd；不碰 wechat-proxy-tunnel
- statusline 其他段（额度/agent-board）一行不碰
- 不升级 python/依赖；ip-monitor 不换框架不重构
- 陈旧克隆只 mv 不 rm；发现其工作树不干净立即 BLOCKED

## 4. 执行序列

1. 本仓改 1.2 → 测试（现有 tests 若覆盖不到 ip-monitor，补最小单测或给出手测记录）
2. claudecode_xinran 仓开分支改 1.3 → `python3 claude-statusline.py` 冒烟（构造最小 stdin payload）+ 计时
3. 停下等 review
4. review 过后执行 1.1（launchd 重挂 + 验证 done-1/2）→ 归档陈旧克隆 → done-5 全机扫描输出
5. 报告 + PR
