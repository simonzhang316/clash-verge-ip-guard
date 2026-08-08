# Claude 容灾建立在完整链上

日期：2026-08-08  
状态：已采纳

Claude 的健康检查对象必须和实际请求对象相同：`第一跳 → 静态住宅 SOCKS → Anthropic`。旧结构分别检查第一跳到 Cloudflare、住宅 SOCKS 直连 IP，无法发现第一跳连接住宅端点失败，因此出现过“检查全绿、Claude 完全不可用”。

生产使用两个经同一资格门槛验证的完整链代理：

- `Claude-Residential-JP3`：`JP3-HY2 → 静态住宅 SOCKS`，固定第一成员。
- `Claude-Residential-JP1`：`JP1-HY2 → 静态住宅 SOCKS`，第二成员。

二者进入 `Claude-Residential` fallback，健康 URL 为 `https://api.anthropic.com/`，正常状态钉为 `404`，`interval: 15`、`lazy: false`、`max-failed-times: 2`。`Claude` selector 只包含 `Claude-Residential` 与 `REJECT`。最终住宅出口身份不因第一跳切换而改变。

enforcer 健康态只读；完整链可用性失败按阈值阻断，出口身份不匹配立即切换并验证 `REJECT`。只有 mode、TUN、IPv6、规则或组拓扑损坏时才调用 heal。heal 只修当前 active merge source，不修改订阅原文、GLOBAL、主代理、Codex-Stable 或 Cockpit。

候选资格门槛是：Anthropic 连续 `20/20`、空闲 10/20/30/60 秒首连 `4/4`、两个 IP 服务一致、无 TLS timeout/reset。`19/20` 不进入 fallback。
