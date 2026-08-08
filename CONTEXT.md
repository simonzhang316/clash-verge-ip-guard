# Context

## Glossary

- **Claude static egress**: The required network identity for Claude Code and Claude web traffic. All Claude service domains must resolve through the same residential egress identity instead of latency-optimized or general-purpose proxy groups.

- **Claude runtime invariant**: The minimum runtime state that must hold before the guard can take the read-only fast path: rule mode is active, TUN is enabled, IPv6 is disabled, Claude service domains route to `Claude`, `Claude` contains exactly `Claude-Residential` and `REJECT`, and `Claude-Residential` contains exactly the qualified full-chain proxies.

- **Claude full-chain proxy**: One independently health-checked path from a named first hop through the static residential SOCKS endpoint to Anthropic. As of 2026-08-08, the qualified production members are `Claude-Residential-JP3` (`JP3-HY2`) and `Claude-Residential-JP1` (`JP1-HY2`), in that order. The final residential egress identity is unchanged.

- **Claude Code process egress**: All network traffic emitted by the Claude Code process itself must be routed through the Claude static egress, including telemetry or bridge traffic whose host is not under an Anthropic or Claude domain.

- **Cockpit**: The single local web view that consolidates network identity and runtime state in one place: egress IP drift status, proxy node latency, proxy group selections, proxy mode, subscription state, and guard status. There is exactly one Cockpit; any network-health question should be answerable from it without opening other tools.

- **Single repairer rule**: Only the guard layer (enforcer/heal) may mutate Clash configuration or repair drift. The Cockpit is an observer with light runtime-only controls (selector switching except the Claude group, manual latency tests, manual egress re-check); it never writes configuration files, never touches subscriptions, mode, or TUN.

- **Guard fast path**: A healthy enforcer cycle verifies the runtime topology, Anthropic through the active full chain, and two full-path egress sources. When all checks pass and state is already clean, it performs no file write, heal, selector mutation, or core reload. A wrong egress immediately selects and verifies `REJECT`; availability failures use the configured threshold.
