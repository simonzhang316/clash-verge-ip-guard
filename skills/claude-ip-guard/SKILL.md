---
name: claude-ip-guard
description: Use when configuring Claude to run through a fixed residential IP via Clash Verge and enforcing pre-launch IP verification to avoid login risk from IP drift.
---

# Claude IP Guard

## Overview

This skill standardizes a safe Claude workflow:
- Route Claude traffic through a fixed residential IP in Clash Verge.
- Verify terminal egress IP before opening Claude.
- Block app launch when IP is wrong.

Important: On modern Mihomo cores, `relay` is removed. Use `dialer-proxy` chaining instead.

## Required Reference

Before applying this skill, read:

- `skills/claude-ip-guard/references/clash-home-ip-setup-zh.md`
- `skills/claude-ip-guard/references/claude-ip-ops-runbook-zh.md`

Treat the "三项必检清单" in that file as mandatory release gates.
The topology examples in older references are historical; the full-chain fallback in this file and ADR 0003 is canonical.

## When To Use

- Claude/Anthropic login verification loops or frequent risk checks.
- Egress IP changes after sleep, network switches, or node switches.
- Need a one-click safe launch gate.

## Workflow

1. Read required reference and confirm the three mandatory checks.
2. Apply Clash chain config (Mihomo-compatible `dialer-proxy`).
3. Enforce runtime requirements (`rule` mode, TUN on, IPv6 off).
4. Run verification gate in clean terminal.
5. Enable safe launch guard (`openclaude`) and optional app button.
6. Operate with no in-session node switching while Claude is open.

## One-Time Setup

### 1) Clash chain (Mihomo-compatible)

```yaml
prepend-proxies:
  - { name: 'Claude-Residential-JP3', type: socks5, server: x.x.x.x, port: 443, username: xxx, password: xxx, udp: true, dialer-proxy: JP3-HY2 }
  - { name: 'Claude-Residential-JP1', type: socks5, server: x.x.x.x, port: 443, username: xxx, password: xxx, udp: true, dialer-proxy: JP1-HY2 }

prepend-proxy-groups:
  # 每个成员都是第一跳 → 静态住宅 SOCKS → Anthropic 的完整链。
  # 仅放入通过 20/20 连续请求和 4/4 空闲首连资格测试的成员。
  - name: Claude-Residential
    type: fallback
    proxies: [Claude-Residential-JP3, Claude-Residential-JP1]
    url: https://api.anthropic.com/
    interval: 15
    lazy: false
    max-failed-times: 2
    expected-status: 404
  - name: Claude
    type: select
    proxies: [Claude-Residential, REJECT]

prepend-rules:
  - DOMAIN,ifconfig.me,Claude
  - DOMAIN-SUFFIX,ping0.cc,Claude
  - DOMAIN-SUFFIX,anthropic.com,Claude
  - DOMAIN-SUFFIX,claude.ai,Claude
  - DOMAIN-SUFFIX,claude.com,Claude
  - DOMAIN-SUFFIX,clau.de,Claude
  - DOMAIN-SUFFIX,modelcontextprotocol.io,Claude
  - DOMAIN,anthropic.statuspage.io,Claude
  - DOMAIN-SUFFIX,sentry.io,Claude
  - DOMAIN-SUFFIX,statsigapi.net,Claude
  - DOMAIN-SUFFIX,featureassets.org,Claude
  - DOMAIN-SUFFIX,prodregistryv2.org,Claude
  - DOMAIN-SUFFIX,featuregates.org,Claude
  - DOMAIN,api.segment.io,Claude
  - DOMAIN,cdn.growthbook.io,Claude
  - IP-CIDR,160.79.104.0/21,Claude,no-resolve
  - IP-CIDR6,2607:6bc0::/48,Claude,no-resolve
```

### 2) Runtime hard requirements

- Mode: `rule`
- TUN: `enable: true`
- IPv6: `false`
- Subscription auto-update: disabled
- Remove shell `HTTP_PROXY/HTTPS_PROXY` env exports when using TUN

## Verification Gate (Must Pass)

Must pass all 3 checks from the reference file:

1. Subscription auto-update is disabled.
2. `Claude-Residential` contains only qualified full-chain members, with JP3 first.
3. Terminal bare `curl` shows expected residential IP.

Run in a clean terminal:

```bash
curl -s ifconfig.me && echo
curl -s ping0.cc/ip && echo
```

Both must return the same fixed residential IP (for example `<EXPECTED_RESIDENTIAL_IP>`).

Optional deep check (Clash unix socket):

```bash
curl --unix-socket /tmp/verge/verge-mihomo.sock -s http://localhost/configs | rg '"mode"|"ipv6"'
curl --unix-socket /tmp/verge/verge-mihomo.sock -s http://localhost/proxies/Claude-Residential | rg '"now"|"all"'
```

## Safe Launch Guard

Add to `~/.zshrc`:

```bash
openclaude() {
  local expected_ip="${CLAUDE_EXPECTED_IP:-}"
  local current_ip
  [[ -z "$expected_ip" ]] && echo "Set CLAUDE_EXPECTED_IP first. Claude not opened." && return 1
  current_ip="$(curl -4 -s --max-time 8 ifconfig.me | tr -d '\r\n')"
  echo "Current IP: ${current_ip:-<empty>}"

  [[ -z "$current_ip" ]] && echo "IP check failed. Claude not opened." && return 1
  [[ "$current_ip" != "$expected_ip" ]] && echo "IP mismatch (expected $expected_ip). Claude not opened." && return 1

  echo "IP verified ($current_ip). Opening Claude..."
  open -a "Claude"
}
```

Usage:

```bash
export CLAUDE_EXPECTED_IP="<EXPECTED_RESIDENTIAL_IP>"
openclaude
```

## Optional One-Click App Button

Create `Open Claude Safe.app` with AppleScript:

```applescript
on run
    set expectedIP to "<EXPECTED_RESIDENTIAL_IP>"
    set currentIP to do shell script "/usr/bin/curl -4 -s --max-time 8 ifconfig.me | /usr/bin/tr -d '\\r\\n'"
    if currentIP is not expectedIP then
        display alert "Claude Guard" message "IP mismatch: " & currentIP & " (expected " & expectedIP & ")" as warning
        return
    end if
    do shell script "/usr/bin/open -a 'Claude'"
end run
```

## Operating Rules

- Never manually switch the Claude selector while Claude is open; the qualified full-chain fallback may fail over automatically.
- If network changes (sleep wake, Wi-Fi switch, Clash restart), close Claude, re-check IP, then reopen.
- Before every Claude launch, pass the verification gate first.

## Security Hygiene

- Do not hardcode personal IPs, usernames, passwords, or tokens in this skill.
- Keep `CLAUDE_EXPECTED_IP` in local shell env only, not in git-tracked files.
- Keep proxy credentials as placeholders in docs (`xxx`), real values only in local config.
- Before publishing, run a quick secret/PII scan:

```bash
rg -n "(api[_-]?key|token|password|secret|@|([0-9]{1,3}\\.){3}[0-9]{1,3})" \
  skills/claude-ip-guard/SKILL.md \
  skills/claude-ip-guard/references/clash-home-ip-setup-zh.md
```

## Fast Recovery

If IP suddenly becomes unexpected:

1. Quit Claude completely.
2. Ensure Clash mode is `rule`, TUN on, IPv6 off.
3. Keep Claude closed while the guard verifies or repairs the full-chain fallback.
4. Re-run the Anthropic TLS check and the two bare `curl` IP checks.
5. Reopen Claude only after the full chain and expected IP both pass.

## Auto Rollback Heal Script

When subscription refresh or profile merge causes IP drift, run:

```bash
claude-ip-heal <EXPECTED_IP> <EXPECTED_PORT>
```

What it does:

- Resolves and repairs only the current profile's active merge source.
- Preserves the two qualified full-chain proxies and their fixed first-hop `dialer-proxy` values.
- Keeps `Claude` fail-closed capable by retaining `REJECT` as an actual member.
- Refuses source mutation or core reload while Claude requests are active.
- After repair, verifies Anthropic through the full chain and two full-path IP sources.

The scheduled enforcer source is tracked beside heal as `scripts/claude-ip-enforce.sh`. Its healthy fast path performs no file write, heal, selector mutation, or core reload.

Script source in this skill:

- `skills/claude-ip-guard/scripts/claude-ip-heal.sh`
