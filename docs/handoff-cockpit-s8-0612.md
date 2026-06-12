# Handoff: Cockpit 网络驾驶舱 — S8 收口 + 扫尾

```
Previous session: 56625aba-e7ae-4ef8-94b8-4e13554ca47f
JSONL: ~/claudecode_xinran/.claude/projects/-Users-zhangxinran/56625aba-e7ae-4ef8-94b8-4e13554ca47f.jsonl
To review: use /agent-log skill with the JSONL path above
```

## Context

为 master 搭建 Cockpit 网络驾驶舱（统一看家宽 IP 漂移 / 代理组延迟 / 模式订阅 / 守护状态），
并修复向日葵/UU 远程秒断问题。需求经 /grill-with-docs 沉淀（决策见 `CONTEXT.md` glossary +
`docs/adr/0001、0002`），拆为 8 个切片（GitHub issue #1 父工单，#2-#9 切片）。

## Current state

- **S1-S7 全部完成并验收**（#2 #3 #4 #5 #6 #7 #8，验收证据在各 issue 评论里）。
  面板 `http://127.0.0.1:8765` + Tailscale `http://100.105.215.124:8765`，
  LaunchAgent `com.zhangxinran.cockpit` 常驻（KeepAlive 已验证，RunAtLoad 待下次真实重启确认）。
- **S8（#9）取证已推翻原假设**：AweSun（向日葵）与 UURemoteServer（UU）的 TCP+UDP 全部已走
  China 规则 DIRECT，不需要受控窗口加规则。历史秒断根因指向 6/10 已修复的 reload 风暴。
  结论详见 #9 的 2026-06-12 23:00 评论。
- **进行中**：远程会话稳定性复测。监视器 `/tmp/s8-monitor.sh`（nohup，~23:37 自动结束）
  每 20s 把 AweSun/UURemoteServer 会话集合变化写到 `/tmp/s8-monitor.log`；
  master 正用另一设备远程连本机 20-30 分钟。判定：同会话 start 时间戳不变 = 不掉线。
- **git**：本地 7 个提交未 push（push 是红线，等 master 发话）。
  本会话最后一个 UI 改动（连接视图加 network/udp 列）**尚未提交**。

## Key files

- `~/Projects/clash-verge-ip-guard/ip-monitor/ip_monitor_server.py` — Cockpit 服务端（guard 桥/只读白名单桥/ops+token/全局出口探测/多网口绑定）
- `~/Projects/clash-verge-ip-guard/ip-monitor/index.html` — 单页前端（有未提交的 network 列改动）
- `~/Projects/clash-verge-ip-guard/ip-monitor/com.zhangxinran.cockpit.plist` — LaunchAgent（已装载于 ~/Library/LaunchAgents/）
- `~/.local/bin/claude-ip-enforce` — enforcer（本会话加了 state.json/events.jsonl 导出、飞书推送、日志轮转；备份在 ~/Scratch/20260612-cockpit-s1-rollback/）
- `~/.local/state/claude-ip-guard/{state.json,events.jsonl,cockpit-token}` — 守护状态/事件流/操作 token（token 不入 git）
- `~/claudecode_xinran/scripts/notify-master.sh` — 飞书告警通道（enforcer 状态变迁复用它）
- `CONTEXT.md` + `docs/adr/0001、0002` — 术语与架构红线（单一修复者规则）
- `/tmp/s8-monitor.log` — 本次稳定性复测记录（临时文件，结论要落回 #9）

## Next steps

1. master 回报远程测试结果后读 `/tmp/s8-monitor.log`：
   - 不掉线 → #9 按「根因已消除」收口（评论 + 可关闭），S8 完结
   - 掉线 → 用日志里掉线时刻 ±1min 的会话变化 + `/api/events` + enforcer 日志定位，走 /bugfix
2. 提交未提交的 index.html（network 列）+ 本 handoff（`git add ip-monitor/index.html docs/ && git commit`）
3. 问 master 是否 push（红线）
4. 明天复查：S7 24h 轮转无报错（`ls ~/.local/log/archive/`，enforcer err 日志行数对照 865）
5. 哪天重启 Mac 后确认 RunAtLoad（面板自动在跑）
6. 可选优化（master 提过才做）：NO_PROXY 加 100.64.0.0/10；pipeline 后续阶段 /thermo-nuclear-code-quality-review + /e2e-verify 还没跑过

## Suggested skills

- `/bugfix` — 仅当稳定性复测出现掉线
- `/thermo-nuclear-code-quality-review` — Cockpit 代码独立审查（写审分离，尚未做）
- `/e2e-verify` — 全面板端到端验证（尚未做）
