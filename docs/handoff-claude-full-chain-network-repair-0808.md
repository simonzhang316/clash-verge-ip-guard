# Handoff: Claude 完整链容灾与网络永久修复

日期：2026-08-08（同日晚修订：第一轮实施按门槛止步于资格测试，本文已改写为第二轮任务书）  
状态：第二轮实施与即时验收通过；24 小时观察中  
范围：Clash Verge / Mihomo / Claude 静态住宅出口守护；不碰 Claude Code 版本（master 已于 0808 另行降至 native 2.1.220 进入观察期，版本事务与本任务无关）

> 安全约定：本仓库公开。本文中的住宅 IP、端口、用户名和密码一律使用
> `<EXPECTED_IP>` / `<EXPECTED_PORT>` / `<USERNAME>` / `<PASSWORD>`，真实值只允许留在本机
> Clash 配置和 LaunchAgent 参数中，不进入 Git、测试输出或日志。

## 接手前必须读

- `~/CLAUDE.md`：本机红线、网络链路改动审批、生产服务器约束
- `~/Projects/clash-verge/CONTEXT.md`：Claude static egress、单一修复者规则
- `~/Projects/clash-verge/docs/adr/0002-cockpit-runtime-only-operations.md`：Cockpit 只读、guard 唯一写者
- `~/Projects/clash-verge/merge-profile-example.yaml`：现役链式架构的脱敏示例
- `~/.local/bin/claude-ip-enforce`：当前生产 enforcer；尚未进入 Git
- `~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh`：当前 canonical heal

任何运行时切组、配置写入、core reload、LaunchAgent 调整都属于网络红线。本 handoff 不是实施授权；
必须等 master 明确批准方案后再动手。

## 任务目标

解决 Claude Code 与 Claude 官网在两跳链空闲、第一跳故障时频繁 TLS 失败、`ECONNRESET`、
OAuth 刷新失败和反复要求用户输入“继续”的问题，同时保持 Claude 所有请求的最终住宅出口不变。

完成判定：

1. 至少两条“第一跳 → 静态住宅 SOCKS → Anthropic”完整链通过资格测试。
2. Claude 实际路径的出口 IP 始终等于 `<EXPECTED_IP>`。
3. Anthropic API 连续 30 次 TLS 建连成功，空闲 60 秒后的首个请求成功。
4. 某条完整链失效时自动换到另一条完整链，最终住宅出口不变。
5. 健康状态正常时 enforcer 不写配置、不调用 heal、不 reload core。
6. 出口 IP 错误时确实切到 `REJECT`，而不是只在日志里声称 fail-closed。
7. 连续 10 个 enforcer 周期无 heal、reload、误报；24 小时内无新的网络层中断。

以上第 1、4 条仅适用于双链分支。若扩大候选池后仍只有一条合格链，完成判定改按
「第二轮任务」分支二：单链钉 JP3 + fail-closed 真实可用 + 失败可见告警，其余各条不变。

## 事故与取证

### 用户症状

- Claude Code 2.1.223 频繁报 API 连接失败、`ECONNRESET`，长任务被打断。
- Claude 官网、控制台、API 和状态页一度同时无法建立 TLS。
- 2.1.68 时几乎没有这种体感；家宽、机房和静态住宅服务器均未更换。

### 2026-08-08 实测

- 09:00—09:23，Mihomo 记录 1048 次 Anthropic 连接超时，成功 0 次。
- 统一错误为连接住宅 SOCKS 端点 `context deadline exceeded`；没有 `connection refused`，
  没有静态 IP 漂移。
- enforcer 同期 48/48 报 OK，`fail_count=0`。
- 住宅 SOCKS 端口本身可达，直接通过住宅 SOCKS 访问 Anthropic 10/10 成功。
- `SG5-HY2`、`JP4-HY2` 已被 Mihomo 标记为不可用。
- `SG4-HY2` 单独访问 Anthropic 5/5 成功；JP2、JP3 单跳探测也成功，但尚未完成住宅完整链资格测试。
- 当前 Claude 路径卡在已经失效的 `SG5-HY2`，Fallback 没有自动切换。
- 同一台机器改走主代理或 SG4 后，Claude 官网、控制台、API、状态页均能建立 TLS，排除 Anthropic 全站故障。

### 已执行的临时恢复

在连续 15 秒、15 次 Claude 请求计数均为 0 后，通过 Mihomo 运行时 API 将
`Claude-Tunnel` 从 `SG5-HY2` 手动切到 `SG4-HY2`。没有修改 YAML、LaunchAgent 或 Claude 版本。

切换后：

- Claude 官网、控制台和 API 恢复 TLS。
- `Claude-Tunnel`、`Claude-Residential`、`SG4-HY2` 健康状态转绿。
- 两个独立 IP 服务均返回 `<EXPECTED_IP>`。
- 现有 Claude Code 和 Chrome 会话随后恢复请求与下载。
- 准备对 JP2 做 A/B 时发现 Claude 请求持续存在，因此按 master 要求取消切换；JP2 完整链未测。

临时恢复仍有残留：两轮测试都出现“空闲后首个 TLS 连接失败，随后连续成功”，其中一轮为
9/10 成功。住宅 SOCKS 直测 10/10、SG4 单跳 5/5，因此残留故障位于 Mihomo 两跳嵌套链的
冷启动，而不是住宅服务器本身。

## 为什么升级后体感变差

不能把 2.1.223 当成唯一根因，因为两项变化几乎同时发生：

- Claude Code 2.1.223 安装时间：2026-08-06 23:52。
- `Claude-Tunnel → 住宅 SOCKS` 链式配置恢复时间：2026-08-07 01:55 左右。
- Git 证据：`7d77525` 恢复 chained `dialer-proxy`，`9ea76f7` 同步 merge 示例。

版本是放大器：2.1.214 起 stale connection 后会关闭 keep-alive 池并新建 socket；断路时更容易形成
新建连接与重试风暴。2.1.221 起另有公开流式连接回归：
<https://github.com/anthropics/claude-code/issues/84404>。

顺序已由 master 于 0808 拍板调整：版本先行——现役已降至 native 2.1.220 并进入观察期；网络修复
随后独立实施。两边归因靠流量隔离保证：本任务全部验收用 curl 完成，不用 Claude Code 发请求
（见「第二轮任务」C）。

## 根因

当前配置把健康检查拆在了两个不同对象上：

```text
Claude 实际请求
  → Claude-Residential
  → Claude-Tunnel
  → 第一跳节点
  → 静态住宅 SOCKS
  → Anthropic

Claude-Tunnel 健康检查
  → 第一跳节点
  → Cloudflare

enforcer 健康检查
  → 直接访问静态住宅 SOCKS
  → IP 查询服务
```

两套检查都没有覆盖 Claude 真正使用的完整链：

```text
第一跳节点 → 静态住宅 SOCKS → Anthropic
```

因此 SG5 无法连接住宅 SOCKS 时，第一套检查仍可能认为 SG5 能访问 Cloudflare；第二套检查又绕过
SG5，证明住宅 SOCKS 自身正常。最终出现“仪表盘全绿、Claude 完全不可用”。

只把健康 URL 从 Cloudflare 换成 Anthropic仍然不够，因为它仍只测试第一跳直接访问 Anthropic，
没有测试第一跳能否连接住宅 SOCKS 端口。永久修复必须把 fallback 建在完整链节点之上。

## 额外发现的守护缺陷

### fail-closed 实际不可用

当前 `Claude` 组只有 `Claude-Residential` 一个候选，但 enforcer 连续失败后试图把组切到 `REJECT`。
`REJECT` 不在组内，运行时切换无法成立。永久配置必须显式包含：

```yaml
proxies:
  - Claude-Residential
  - REJECT
```

### 生产 enforcer 没有代码真相

`~/.local/bin/claude-ip-enforce` 是独立生产脚本，没有 tracked source；heal 已通过 wrapper 指向
`~/Projects/clash-verge/`。本次修复应把 enforcer 收回 canonical 仓库，再让 `.local/bin` 只保留
薄 wrapper。

### 两个项目副本并存

- `~/Projects/clash-verge/`：README 明确声明 canonical，HEAD 含 2026-08-07 链式恢复提交；heal wrapper 指向这里。
- `~/Projects/clash-verge-ip-guard/`：旧副本，Cockpit LaunchAgent 仍从这里运行。

本次只改 canonical `~/Projects/clash-verge/` 与生产 wrapper，不双写旧副本，不顺手迁 Cockpit。

## 推荐架构

```text
Claude
  │
  ▼
Claude-Residential（完整链 fallback）
  ├─ Claude-Residential-JP3
  │    └─ JP3-HY2 → 静态住宅 SOCKS → Anthropic（第一轮唯一满分链，固定第一成员）
  ├─ Claude-Residential-<第二条合格链>
  │    └─ <合格第一跳> → 静态住宅 SOCKS → Anthropic
  └─ 其他通过资格测试的完整链
  │
  ▼
Anthropic；最终出口始终为 <EXPECTED_IP>
```

脱敏配置形状：

```yaml
prepend-proxies:
  - name: Claude-Residential-JP3
    type: socks5
    server: <EXPECTED_IP>
    port: <EXPECTED_PORT>
    username: <USERNAME>
    password: <PASSWORD>
    udp: true
    dialer-proxy: JP3-HY2

  - name: Claude-Residential-<QUALIFIED2>
    type: socks5
    server: <EXPECTED_IP>
    port: <EXPECTED_PORT>
    username: <USERNAME>
    password: <PASSWORD>
    udp: true
    dialer-proxy: <QUALIFIED2 的第一跳>

prepend-proxy-groups:
  - name: Claude-Residential
    type: fallback
    proxies:
      - Claude-Residential-JP3
      - Claude-Residential-<QUALIFIED2>
    url: https://api.anthropic.com/
    interval: 15
    lazy: false
    max-failed-times: 2
    expected-status: <实测记录的正常返回码>

  - name: Claude
    type: select
    proxies:
      - Claude-Residential
      - REJECT
```

候选列表不能预先写死。第一轮已测 SG4、JP2、JP3、主代理，仅 JP3 合格（结果见下节）；第二轮扩大
候选池后，只有通过者进入正式 fallback，JP3 固定为第一成员。SG5、JP4 当前已知不可用，默认排除。

`interval: 15`、`max-failed-times: 2` 的意图：完整链保持温热，避免空闲首连失败；单次抖动不切换，
连续失败约 30 秒内换路。若实测冷启动阈值不同，以维护窗口数据决定 interval，不凭经验拍值。

`expected-status` 必须钉实测值：先用 curl 经完整链请求 `https://api.anthropic.com/` 记录正常
返回码，再写入配置。不钉的话任何 HTTP 响应都算活——拦截页、机场维护页会把死链判成健康，
这正是本次事故"全绿仪表盘"的同款错误。

## Enforcer 行为重构

enforcer 每 30 秒执行一次，但健康态必须是只读快路径：

| 检测结果 | 行为 |
|---|---|
| 配置不变量正确、Anthropic 完整链可达、出口 IP 正确 | 记录 OK；零写入、零 heal、零 reload |
| 当前完整链超时，但存在健康候选 | 交给 fallback 换链并复测；不 reload |
| 所有完整链超时 | 累计可用性失败；达到阈值后切 `REJECT` 并告警 |
| 实际出口返回非 `<EXPECTED_IP>` | 立即切 `REJECT` 并告警，不等待三轮 |
| mode/TUN/规则/组结构损坏 | 才调用 heal；修复后重新验证完整链与出口 |
| 住宅 SOCKS 直测正常、完整链失败 | 明确记录为中转/嵌套链故障，不能报 OK |

状态文件应至少导出：当前完整链候选、Anthropic 探测结果、完整路径出口 IP、住宅 SOCKS 直测结果、
失败类别。只在状态变迁时发通知，避免每 30 秒刷屏。

## 第一轮资格测试结果（2026-08-08 晚，已执行）

执行范围：仅完成实施步骤 3（候选资格测试），未进入失败测试、源码修改或 reload。生产路径已恢复
`SG4-HY2` 且 alive；6 个生产文件与备份逐一比对一致；Git 仅本 handoff 未跟踪。

| 候选 | 连续请求 | 空闲首连 | 出口 IP | 资格 |
|---|---:|---:|---|---|
| SG4-HY2 | 19/20 | 4/4 | 正确 | 不合格 |
| JP2-HY2 | 18/20 | 4/4 | 正确 | 不合格 |
| JP3-HY2 | 20/20 | 4/4 | 正确 | **合格** |
| 主代理 | 19/20 | 4/4 | 正确 | 不合格 |

三条失败线路的失败均为真实 `SSL_ERROR_SYSCALL`。合格链只有 JP3 一条，未达"至少两条"门槛，
按规停止。20/20 门槛保持不变，不得放水——19/20 就是不合格，不存在"接近合格"。

两个直接推论：

1. 当前生产链 SG4 自带约 5% 的真实断连率。Claude Code 2.1.220 观察期里的零星 `ECONNRESET`
   有网络本底，归因时不能全记客户端。
2. JP3 是目前唯一满分链。无论最终架构是双链还是单链，主力线路都应是 JP3，不是 SG4。

## 第二轮资格测试结果（2026-08-08 晚）

为避免切换生产 `主代理`，第二轮使用关闭 TUN、绑定 `en0`、独立端口和独立 controller socket 的
Mihomo 实例测试。隔离基线经生产连接表复核，测试候选流量未被生产 TUN 捕获。临时配置含真实凭据，
只留在 `~/Scratch/20260808-claude-network-repair/isolated-test/`，权限 700/600，不进入 Git。

按候选优先级测试首个扩大候选 `JP1-HY2`：

| 候选 | 连续请求 | 空闲首连 | 出口 IP | 资格 |
|---|---:|---:|---|---|
| JP1-HY2 | 20/20 | 4/4 | 正确 | **合格** |

Anthropic 返回码稳定为 `404`，无 TLS timeout/reset，两个独立 IP 服务一致。至此已有
`JP3-HY2 + JP1-HY2` 两条满分链，严格按停止条件不再扫描其余候选，进入分支一。JP3 固定为第一成员，
JP1 为第二成员。独立实例恢复到 JP3 后已停止，临时目录未删除。

## 第二轮任务：扩大候选池 + 分支决策

### A. 扩大候选池重测

- 从订阅中列出全部可用第一跳节点（排除已知死亡的 SG5、JP4，以及第一轮已判不合格的
  SG4、JP2、主代理），逐个做与第一轮完全相同的完整链资格测试：20/20 连续请求 +
  10/20/30/60 秒空闲首连 4/4 + 两个独立 IP 服务返回同一 `<EXPECTED_IP>` + 无
  `SSL_ERROR_SYSCALL`/TLS timeout/reset。
- 优先测与 JP3 同区域、同协议的节点；其他协议节点也纳入，不预设结论。
- 每测完一个候选恢复到已知可用路径，全程遵守零 Claude 请求门禁。
- 找到第二条 20/20 链即可停止扫描进入分支一；扫完全部候选仍无则进入分支二。

### B. 按重测结果二选一

**分支一（合格链 ≥2，含 JP3）**：按「推荐架构」实施双链 fallback，成员=全部合格链，
第一成员固定 JP3。走实施步骤 4-7 不变。

**分支二（扫完全场仍只有 JP3 合格）**：放弃 fallback 架构——塞不合格成员进组是假保险，
切过去照样掉线。改为：

1. 生产路径单链钉死 JP3（完整链结构：JP3-HY2 → 静态住宅 SOCKS → Anthropic）。
2. `Claude` 组仍显式包含 `REJECT`，fail-closed 修复照做（「额外发现的守护缺陷」一节全部有效）。
3. enforcer 只读快路径重构照做，健康检查必须测完整链（JP3 → 住宅 SOCKS → Anthropic）。
4. 单链死亡时没有自动换路：enforcer 达到失败阈值后切 `REJECT` 并立即经 `notify-master.sh`
   告警，把"不可用"从静默变成可见。
5. 交付定性为"单链恢复 + 无自动容灾 + 失败可见"，不得宣布为永久容灾修复。

### C. 无论哪个分支都要做

- 健康检查 URL 用 `https://api.anthropic.com/`，先实测记录其正常返回码，配置钉
  `expected-status`，避免拦截页/异常响应被当成活。
- 唯一一次 profile/core reload 放在夜窗执行：全机代理瞬断会影响言茜 6 个 bridge bot，
  执行前明确告知 master 窗口影响。
- 运行时验收全部用 curl 等独立工具完成，不用 Claude Code 发请求——master 正在做 2.1.220
  版本观察，验收流量混入会同时污染两边的归因。
- master 会在实施窗口退出 cmux / 关闭 Claude Code，保证零 Claude 流量；维护门禁的
  30 秒零请求检查仍照做，作为程序性双保险。

## 实施步骤

### 1. 维护窗口门禁

master 批准方案后仍不能立即实施。通过 Mihomo `/connections` 检查以下任一条件：

- host 匹配 `anthropic`、`claude.ai`、`claude.com`；
- process 匹配 Claude Code 可执行文件。

要求连续 30 秒计数为 0。任一采样出现请求，整个维护动作中止，不切节点、不写配置、不 reload。
仅凭 Claude 进程存在或本地 7897 keep-alive socket 不能判定正在请求。

core reload 会让全机代理连接短暂重连，不只影响 Claude。执行前明确告知 master 窗口影响。

### 2. 备份

第一轮已建备份且与生产文件逐一比对一致；第二轮开工前复核该目录仍在、内容仍与生产一致，
有差异先停下问 master，不得覆盖重建。备份位置
`~/Scratch/20260808-claude-network-repair/rollback/`，目录权限 700、文件权限 600：

- 当前 active merge source
- `profiles.yaml`
- `clash-verge.yaml`
- `~/.local/bin/claude-ip-enforce`
- `~/.local/bin/claude-ip-heal`
- enforcer LaunchAgent plist

不得把含真实凭据的备份加入 Git。清理备份属于删除红线，24 小时验收后另问 master。

### 3. 候选资格测试

第一轮（SG4、JP2、JP3、主代理）已完成，结果见「第一轮资格测试结果」。第二轮按「第二轮任务」A
扩大候选池执行，方法不变：利用当前 `Claude-Tunnel` 的运行时选择能力，在零请求窗口逐个测试；
每次测试后恢复到已知可用路径。每个候选必须：

- 完整住宅链访问 Anthropic 20/20；
- 间隔 10、20、30、60 秒后的首个请求均成功；
- 两个独立 IP 服务返回同一个 `<EXPECTED_IP>`；
- 无 `SSL_ERROR_SYSCALL`、TLS timeout、connection reset。

合格数 ≥2（含 JP3）走分支一；扫完全部候选仍只有 JP3 时走分支二，交付"单链恢复 + 无自动容灾 +
失败可见"，不得宣布为永久容灾修复。20/20 门槛不降。

### 4. 先写失败测试

在 `skills/claude-ip-guard/tests/` 建无敏感信息的 fixture 与标准库测试。新目录需附短 README/CLAUDE
说明：只放 guard 测试、fixture 必须脱敏、不触碰真实 runtime。

测试至少覆盖：

1. 住宅 SOCKS 直测成功但完整链到 Anthropic 失败时，fast path 必须失败。
2. 一条完整链死亡时，组仍有另一条可用完整链。
3. 健康态不调用 heal、不写文件、不 reload。
4. 出口 IP 不匹配时实际选择 `REJECT`。
5. Claude 请求不为零时维护门禁拒绝切换和 reload。
6. heal 能识别、保留并验证新的完整链拓扑，不重新生成旧 `Claude-Tunnel` 结构。

先观察测试在现状下失败，再修改实现。

### 5. 修改 canonical 源码与脱敏示例

计划修改：

- `~/Projects/clash-verge/merge-profile-example.yaml`
- `~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh`
- 新增 tracked `~/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-enforce.sh`
- `~/Projects/clash-verge/skills/claude-ip-guard/SKILL.md`
- `~/Projects/clash-verge/CONTEXT.md`
- 新增 `~/Projects/clash-verge/docs/adr/0003-claude-full-chain-fallback.md`
- 新增脱敏测试文件

生产部署：

- 更新 active merge source；不修改订阅原文。
- `.local/bin/claude-ip-enforce` 改为指向 canonical 脚本的薄 wrapper。
- `.local/bin/claude-ip-heal` 继续使用现有 canonical wrapper。
- LaunchAgent 的 30 秒周期无需修改。
- Cockpit、GLOBAL、主代理默认选择、Codex-Stable、Claude Code 版本均不在本次改动范围。

### 6. 离线验证与唯一一次加载

1. 生成脱敏 fixture 和含本机凭据的本地最终配置；后者不得输出到工具日志。
2. 运行 shell 语法检查和全部失败测试。
3. 用 Mihomo 自带配置检查验证最终配置可加载、所有 `dialer-proxy` 引用存在。
4. 验证通过后只执行一次受控 profile/core reload。
5. reload 后先保持 Claude 关闭，跑运行时验收门。

### 7. 运行时验收

- `Claude` 当前选择 `Claude-Residential`，候选包含 `REJECT`。
- `Claude-Residential` 是 fallback，成员与资格测试通过名单一致。
- 每个完整链成员的 `dialer-proxy` 与目标第一跳正确。
- 两个实际路径 IP 服务均返回 `<EXPECTED_IP>`。
- Anthropic API 30/30 成功。
- Claude 官网、控制台、OAuth、API 均能建立 TLS。
- 空闲 60 秒后的首个连接成功。
- 连续 10 个 enforcer 周期：无 heal、无 reload、无 fail_count 增长。
- 所有门通过后才通知 master 重开 Claude。

## 第二轮实施与即时验收结果（2026-08-08 晚）

分支一已实施，生产结构为：

```text
Claude
  → Claude-Residential
      ├─ Claude-Residential-JP3 → JP3-HY2 → 静态住宅 SOCKS
      └─ Claude-Residential-JP1 → JP1-HY2 → 静态住宅 SOCKS
```

`Claude` 实际候选为 `Claude-Residential + REJECT`；`Claude-Residential` 实际候选顺序为
`JP3 + JP1`，健康 URL、间隔、lazy、失败阈值和 expected-status 均与本文一致。`主代理` 保持
`自动选择`，GLOBAL、Cockpit、Codex-Stable、Claude Code 版本均未改。

源码与测试：

- 新增 tracked enforcer source，生产 `.local/bin/claude-ip-enforce` 已收为两行薄 wrapper。
- heal 只解析当前 profile 指向的 active merge source，保留并验证完整链拓扑。
- 新增脱敏 fixture、Mihomo 完整配置 fixture 和 9 项标准库回归测试；现状失败基线已观察，修改后
  `9/9` 通过，两个 shell 脚本语法检查通过。
- 脱敏最小配置与含本机凭据的完整最终展开配置均经现役 Mihomo `-t` 验证可加载；后者留在
  `~/Scratch/20260808-claude-network-repair/offline-final-bash/`，权限 700/600，不进 Git。

唯一一次 core reload 由旧 enforcer 在 active merge 写入后抢先触发，加载的就是已经离线验证过的最终
展开配置。旧 heal 当时只等待 1 秒便做首个 curl，早于 `lazy: false` 的完整链完成温热，因此误报
`full-chain Anthropic probe failed`。现场确认两条完整链和两个第一跳均 alive 后终止旧守护周期，部署
新 wrapper；没有执行第二次 reload。该竞态已增加失败测试，并改为最多 7 次、每 5 秒一次的有界
post-reload 验证，重试期间不再次 reload。

即时验收证据：

- Anthropic API 裸 curl：`30/30`，全部 `404`。
- 两个完整路径 IP 服务：均匹配预期住宅出口。
- 官网、控制台、OAuth、API：均能建立 TLS；无登录态 curl 分别返回 `403/301/301/404`。
- 停止人工请求 60 秒后的首个 API 请求：成功，`404`。
- 独立脱敏 Mihomo 实例：实际把 `Claude` 切到 `REJECT` 并从 controller 读回 `now=REJECT`，再恢复
  `Claude-Residential`；证明 fail-closed 不是日志假动作。生产组未参与该故障注入。
- 连续 10 个 enforcer 周期：`OK`、`fail_count=0`；active merge 和最终运行配置哈希不变，状态文件
  mtime 不变，heal 事件数与 reload 日志数不变，零误报、零写入、零 heal、零 reload。

验收全程使用 curl、Mihomo controller 和脱敏独立实例，没有启动或调用 Claude Code。即时门已全部
通过，可以重开 Claude；24 小时观察项仍按「观察与版本 A/B」执行，在观察期结束前不清理备份。

## 回滚

任一门失败：

1. 不打开 Claude。
2. 恢复 active merge、生产 wrapper 与受影响配置。
3. 只做一次回滚 reload。
4. 验证旧结构已恢复、SG4 仍为当前可用临时路径、出口仍为 `<EXPECTED_IP>`。
5. 记录失败点与证据，不继续叠加修补。

回滚目标是恢复本 handoff 开始前的 SG4 临时可用状态，不回退 Claude Code，不切换全局出口。

## 观察与版本 A/B

网络修复通过后观察 24 小时：

- Mihomo 的 Anthropic timeout / reset；
- enforcer 的状态变迁、heal 与 reload 次数；
- Claude Code 用户可见传输错误；
- 空闲后的首次请求。

版本侧已由 master 单独处理（现役 native 2.1.220，观察中），不在本任务范围。网络改动的实施与
验收全程不用 Claude Code 发请求，与版本观察互不污染；两边各自稳定后如仍有中断，再由 master
决定是否做进一步版本 A/B。

## 当前 Git 与运行状态

- canonical：`~/Projects/clash-verge/`，分支 `main`，HEAD 仍为 `00f1061`；第二轮改动均未 commit、
  未 push。工作树中的修改均为本文列出的 canonical、ADR、handoff、enforcer 和脱敏测试文件。
- 旧副本：`~/Projects/clash-verge-ip-guard/`，不在本次写入范围。
- 生产路径：`Claude-Residential` 完整链 fallback，JP3 第一、JP1 第二；`Claude` 含真实 `REJECT`。
- enforcer：tracked canonical + 生产薄 wrapper，LaunchAgent 仍为原 30 秒周期，未修改 plist。
- 第一轮备份与第二轮 Scratch 证据均保留，未删除、未加入 Git。
- 不得 commit、push、删除备份或公开发布，除非 master 另行明确授权。

## 下一位 agent 的第一步

1. 不再改配置、不再 reload；先完成 24 小时观察，核对 Anthropic timeout/reset、enforcer 状态变迁、
   heal/reload 次数和用户可见中断。
2. 观察期内如失败，按「回滚」章恢复第二轮前 SG4 临时态，不叠加修补；Claude Code 版本仍不动。
3. 观察期通过后向 master 报告，再单独请求是否清理 Scratch 备份；删除仍是红线。
4. commit、push、PR 均未授权，不执行。
