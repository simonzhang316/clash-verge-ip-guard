# 任务书：家宽时代网络监控遗产大扫除 + 仓库收账

> 委托对象：codex。review 出口：Claude（十七）。前置：VPS cutover 与监控迁移均已完成。
> 性质：**只扫描不动手**——产出清单与处置建议，一切修改/删除/归档由 review 后另行放行。

## 0. done condition

1. 全机扫描报告落 `~/Scratch/20260904-bwg/legacy-sweep-report.md`：每条发现含【路径 / 内容摘要 / 是否活跃（launchd·cron·进程）/ 处置建议（保留·改造·归档·废弃）】
2. 零漏扫声明：报告末尾列出扫过的全部范围清单
3. 不改任何文件（报告本身除外）

## 1. 扫描范围（全部要过）

- `~/Library/LaunchAgents/*.plist` 全量：凡引用 38.45.149.73、23695、claude-ip、ip-monitor、heartbeat、网络探测类脚本的
- `crontab -l`（预期为空，确认即可）
- `~/claudecode_xinran/scripts/` 全量：出口/IP/网络监控相关脚本（statusline 已迁，其余待查）
- `~/Projects/` 一级目录名含 network/ip/monitor/guard/proxy 者 + `~/Projects/clash-verge/` 内除已交付脚本外的旧监控残件（ip-monitor/start_ip_monitor.sh、stop_ip_monitor.sh 是否还被引用）
- `~/.local/bin/` 全量可执行：网络探测/heal/enforce 相关（wrapper 已迁，查其他）
- `~/.zshrc` + `~/.zprofile`：网络相关 alias/function（home-guard 除外）
- `~/.lark-channel/` 各 profile 配置：proxy 相关字段（只读列出，不碰）
- `~/.hermes/`、`~/.codex/config.toml`、`~/.gemini/config`：proxy/网络端点配置
- guard 状态目录 `~/.local/state/claude-ip-guard/` 与 `~/.local/state/` 顶层：孤儿状态文件
- `~/Scratch/` 内本次迁移之外的历史网络调试目录（只列，30 天 TTL 自会清）
- 备注排除项：`~/Archive/`（已冻结）、订阅 profile 内容、wechat-proxy-tunnel（红线不读）、外星人（二期）

## 2. 判定基准

- "针对家宽 IP 的监控/守护/探测" 且未随 cutover 迁移 = 漏网之鱼
- 活跃（launchd loaded / 进程在跑）的漏网之鱼标 ⚠ 优先级
- 引用已归档陈旧克隆路径（Projects/clash-verge-ip-guard）的任何东西 = 必列
- 拿不准的列为"待裁决"，不要自行定性废弃

## 3. 仓库收账（扫描完成、review 通过后执行）

- clash-verge 仓：工作树若有未跟踪杂物先报告；PR #13 合并、本地切回 main 由宿主执行（gh 认证在沙箱不可用）
- 报告中列出合并后需要宿主验证的点（运行时脚本路径是否随分支切换失效等——wrapper 指向工作树文件，切分支后文件仍在 main 上，需确认 main 已含全部改动）
