# Context

## Glossary

- **Claude static egress**: The required network identity for Claude Code and Claude web traffic. All Claude service domains must resolve through the same residential egress identity instead of latency-optimized or general-purpose proxy groups.

- **Claude runtime invariant**: The minimum runtime state that must hold before the guard can take the fast path: rule mode is active, TUN is enabled, Claude service domains route to the Claude group, and the Claude group resolves only to the residential Claude proxy.

- **Claude Code process egress**: All network traffic emitted by the Claude Code process itself must be routed through the Claude static egress, including telemetry or bridge traffic whose host is not under an Anthropic or Claude domain.

- **Cockpit**: The single local web view that consolidates network identity and runtime state in one place: egress IP drift status, proxy node latency, proxy group selections, proxy mode, subscription state, and guard status. There is exactly one Cockpit; any network-health question should be answerable from it without opening other tools.

- **Single repairer rule**: Only the guard layer (enforcer/heal) may mutate Clash configuration or repair drift. The Cockpit is an observer with light runtime-only controls (selector switching except the Claude group, manual latency tests, manual egress re-check); it never writes configuration files, never touches subscriptions, mode, or TUN.
