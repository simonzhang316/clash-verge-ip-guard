# Cockpit 基于现有 ip-monitor 扩展，而非采用现成 Clash 面板

需要一个统一视图同时看：家宽静态 IP 漂移状态、节点延迟、代理组、模式/TUN、订阅状态、守护层（enforcer）状态与事故时间线。现成面板（zashboard / metacubexd）只覆盖 Clash 运行时那一半，IP 漂移与守护状态是本项目独有数据，没有任何现成面板能展示——用现成面板必然变成「看两个地方」，违背统一视图的初衷。因此选择在现有 `ip-monitor` Python server（纯标准库）上扩展为 Cockpit：加 mihomo unix socket 桥 + 单页前端，零新依赖。独立桌面 app（Tauri/Electron）因工程量对单机自用无回报而否决。

## Considered Options

- zashboard / metacubexd + 独立 IP 监控页：界面成熟白拿，但数据合不到一处，且需开 external-controller TCP 端口。
- 独立桌面 app：工程量大一个数量级，无对应回报。
