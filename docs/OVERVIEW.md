# conductor-kernel — Overview

`conductor-kernel` is a **domain-agnostic orchestration kernel** for multi-agent
workflows in [Claude Code](https://docs.claude.com/en/docs/claude-code). It ships
as a Claude Code **plugin** — a collection of Markdown agent/skill definitions,
JSON Schema state contracts, Bash verification scripts, and hook scripts. It has
**no runtime dependencies**, no CLI binary, no HTTP server, and (deliberately)
**no slash command of its own**.

The kernel exists so that downstream **domain plugins** (e.g. a dev-workflow
plugin, or a SOC investigation plugin) do not each re-invent the same five
orchestration concerns:

1. **Dispatch contract** — how one agent calls another, how token/cost budgets are
   tracked, how retries work.
2. **Validation loop** — how a second model checks a first model's output before
   it is accepted.
3. **Audit trail** — how every action is recorded so security and compliance teams
   can reconstruct what happened.
4. **State machine** — how a workflow's progress is persisted across the inevitable
   conversation restart.
5. **Gate enforcement** — how human approval is required before destructive or
   sensitive actions.

Domain plugins consume the kernel via the qualified-name dispatch contract
(`conductor-kernel:<agent>`) and the kernel-defined primitives documented in
[`../API.md`](../API.md).

---

## Where the kernel sits

```
   domain plugin (your code — exports the slash command)
            |
            v
       conductor-kernel   <-- dispatches kernel agents, enforces gates,
            |                  emits audit rows, persists workflow/stream state
            v
       governance-plugin  (audit trail, human-approval gates, NHI manifests)
```

The kernel is **beneath** domain plugins and **above** the governance-plugin audit
trail. A domain plugin declares a `requires` clause on `conductor-kernel` and calls
into it; the kernel in turn writes to `governance-plugin`'s append-only audit
database.

---

## What ships in this repository

| Surface | Count | Location | Notes |
|---|---|---|---|
| Domain-agnostic **agents** | 19 | [`agents/`](../agents/) | Addressed as `conductor-kernel:<name>`. Each declares an explicit `allowed-tools` frontmatter. |
| Domain-agnostic **skills** | 14 | [`skills/`](../skills/) | Addressed as `conductor-kernel:<name>`. |
| **Workflow-mode** primitives | 6 | [`../API.md §4`](../API.md) | `tier_classify`, `state_init`, `state_advance`, `gates_evaluate_and_enforce`, `complete`, plus deprecated `gates_evaluate`. |
| **Stream-mode** primitives | 8 | [`lib/stream/`](../lib/stream/) | Continuous, event-driven orchestration. Experimental. |
| **Shared** primitives | — | [`../API.md §6`](../API.md) | `dispatch_agent(_v2)`, `gemini_validate`, `critic_review`, `audit_emit`, `memory_recall/store`, `recovery_classify`. |
| **State schemas** | 2 | [`schemas/`](../schemas/) | `workflow-state.schema.json`, `stream-state.schema.json` (both v3.0). |
| **Event schemas** | 3 | [`schemas/events/`](../schemas/events/) | `webhook`, `cron`, `audit` baseline envelopes. |
| **Verification scripts** | 3 | [`scripts/`](../scripts/) | `verify-cross-plugin-dispatch.sh`, `verify-audit-emission.sh`, `verify-agent-tools.sh`. |
| **Hooks** | 2 | [`hooks/`](../hooks/) | `SessionStart` (health check) + `PostToolUse` (state-write schema validation). |

The full, authoritative, per-export API contract — every export is a stability
commitment — is [`../API.md`](../API.md). Read that before integrating.

---

## The 19 agents at a glance

| Group | Agents |
|---|---|
| **Workflow & validation** | `critic`, `gemini-validator`, `completeness-validator`, `checkpoint`, `event-router` |
| **Outcome & reflection** | `outcome-collector`, `retrospective`, `prediction-engine`, `research` |
| **Security & compliance** | `ciso`, `llm-security`, `pentest-coordinator`, `secrets-lifecycle`, `supply-chain-security`, `compliance`, `compliance-overview` |
| **Recovery & robustness** | `recovery-engine` |
| **Code investigation** | `bug-find`, `analyze-codebase` |

Every agent is read-mostly and declares a minimal `allowed-tools` scope. Kernel
agents do **not** dispatch other agents (`Task` is not in any kernel agent's
allowlist) — only domain-plugin commands dispatch. See
[`ADMINISTRATOR.md`](ADMINISTRATOR.md) for the full agent/tool matrix.

---

## The 14 skills at a glance

`context-management`, `retry-policy`, `self-healing`, `state-management`,
`event-automation`, `outcome-measurement`, `predictive-scaling`,
`process-knowledge`, `sbr`, `dashboard-integration`, `brd-tracking`,
`workflow-reference`, `agent-capabilities`, `agent-interop`.

Skills are prose guidance surfaces that Claude Code loads on demand; they encode
tier-appropriate patterns rather than executable code.

---

## Two orchestration modes

- **Workflow mode** — a bounded task with a start and an end. Tier-classified,
  advanced through a state machine, gated, and completed with an outcome report.
  State persists to a working-directory JSON file validated against
  [`workflow-state.schema.json`](../schemas/workflow-state.schema.json).
- **Stream mode** — a long-lived, event-driven subscription (webhook, cron, event
  bus). State persists to a Qdrant collection keyed by `stream_id`. Stream-mode
  primitive **signatures** are a v0.1.0 stability commitment; the reference
  implementation scripts live under [`lib/stream/`](../lib/stream/) and are marked
  **experimental**.

---

## Status

**v0.1.0** — first OSS-quality contract. The agents/skills surface and the core
dispatch / audit / memory / recovery / workflow primitives are stable. Reserved
namespaces (`memory_recall_cross_domain`, `audit_verify`, `local_validate`) and
stream-mode implementation details land additively in later phases. See
[`../CHANGELOG.md`](../CHANGELOG.md) and [`../API.md §11`](../API.md) for how semver
applies to each part of the surface.

---

## Where to go next

- Install it: [`INSTALL.md`](INSTALL.md)
- Operate / administer it: [`ADMINISTRATOR.md`](ADMINISTRATOR.md)
- Use it from a domain plugin: [`HOW-TO-USE.md`](HOW-TO-USE.md)
- Dependency inventory: [`SBOM.md`](SBOM.md)
- Security posture: [`../SECURITY.md`](../SECURITY.md) and [`threat-model-v0.1.0.md`](threat-model-v0.1.0.md)
- Latest security scan: [`scan/scan-report.md`](scan/scan-report.md)

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
