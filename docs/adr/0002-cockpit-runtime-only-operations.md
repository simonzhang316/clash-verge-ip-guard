# Cockpit 只做运行时操作，配置写入权独占于守护层（单一修复者规则）

2026-06-10 的 reload 风暴根因是多个写者（heal 脚本与 Clash Verge）互相改写配置永不收敛。为避免 Cockpit 成为第三个写者：Cockpit 的全部操作仅限 mihomo 运行时 API——切换 Selector 组（Claude 组锁定不可切）、手动延迟测试、手动出口 IP 重检；永不写任何配置文件、不碰订阅、不切模式/TUN。该边界在服务端强制：mihomo 的 external-controller TCP 保持关闭，Cockpit 后端经 unix socket 桥接并只放行白名单端点（`PUT /proxies/Claude`、`PATCH /configs`、订阅类一律拒绝），不依赖前端自觉。

家宽 IP 漂移状态同理不由 Cockpit 独立探测（避免家宽出口探测流量翻倍、避免两套探测结果打架），而是由 enforcer 每轮检查后写 state.json，Cockpit 只读。守护层是唯一的修复者与唯一的配置写者。

## Consequences

- Cockpit 上的组切换是运行时态，core reload 后会回到配置态——可接受，当前日常 reload 为零。
- 任何「面板上加个改配置按钮」的未来需求，必须先推翻本 ADR 再动手。
