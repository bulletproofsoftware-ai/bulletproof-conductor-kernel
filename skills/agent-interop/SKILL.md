---
name: agent-interop
description: >
  A2A external agent interoperability layer for conductor. Provides agent capability
  registry, protocol adapter specifications, authentication configuration, and context
  sharing protocol. Enables external callers (Telegram, c2, n8n, A2A agents) to discover
  and invoke conductor agents through standardized interfaces.
---

# Agent Interop Skill

Provides reference data for the conductor-agent-gateway: capability registry, protocol specs, auth config, and context envelope format.

## When To Use

- When configuring external access to conductor agents
- When adding new agents to the externally callable registry
- When setting up authentication for a new caller type
- When implementing cross-platform agent collaboration
- When debugging external invocation failures

## Reference Files

| File | Purpose |
|------|---------|
| `references/agent-registry.yaml` | Machine-readable catalog of all 34 agents with schemas |
| `references/protocol-adapters.md` | REST, MCP Bridge, and A2A adapter specifications |
| `references/auth-config.yaml` | Authentication methods and rate limits per caller type |
| `references/context-envelope.yaml` | Context sharing protocol specification |

## Key Rules

1. **Only external_callable agents exposed** — 15 of 34
2. **Async-first** — all invocations return job ID for polling
3. **Schema validation** — input validated before dispatch
4. **Governance travels with context** — classification metadata mandatory
5. **Fallback to scripts** — degrade to ~/bin/ when conductor unavailable
6. **All invocations audited** — logged to governance audit bus
