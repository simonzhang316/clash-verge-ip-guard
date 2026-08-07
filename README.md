# clash-verge-ip-guard

Clash Verge + Claude 家宽静态 IP 的守护与观测项目（canonical location）。

## 组件

- `skills/claude-ip-guard/` — Claude IP 守卫 skill、配置说明、heal 修复脚本
- `ip-monitor/` — **Cockpit 网络驾驶舱**：家宽 IP 漂移状态、代理组/延迟、模式/TUN/订阅、
  事故时间线、连接取证视图、全局出口探测（见 `CONTEXT.md` 与 `docs/adr/`）

## Cockpit 访问

- 本机：`http://127.0.0.1:8765`
- Tailscale 网内（手机/异地）：`http://<本机TailscaleIP>:8765`
- 操作类端点（切组/测速/重检）需要 token：`~/.local/state/claude-ip-guard/cockpit-token`

## 运行管理

Cockpit 由 LaunchAgent `com.zhangxinran.cockpit` 常驻（RunAtLoad + KeepAlive）：

```bash
launchctl kickstart -k gui/$(id -u)/com.zhangxinran.cockpit   # 重启
launchctl bootout gui/$(id -u)/com.zhangxinran.cockpit        # 停止
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.zhangxinran.cockpit.plist  # 重新装载
```

`ip-monitor/start_ip_monitor.sh` 仅用于 LaunchAgent 未装载时的手动调试。

## 守护层

```bash
# 修复家宽 IP 漂移（守护层是唯一修复者，见 ADR-0002）
skills/claude-ip-guard/scripts/claude-ip-heal.sh <EXPECTED_IP> <EXPECTED_PORT>
```

enforcer（`~/.local/bin/claude-ip-enforce`，LaunchAgent 30s 周期）负责校验与 fail-closed，
并向 Cockpit 导出 `state.json` / `events.jsonl`（`~/.local/state/claude-ip-guard/`）。

## 安全约定

仓库 PUBLIC：家宽 IP/端口一律占位符；token/凭据不入 git。
