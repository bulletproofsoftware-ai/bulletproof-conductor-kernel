# conductor-kernel

**Domain-agnostic orchestration kernel for multi-agent workflows in Claude Code.**

![bulletproof-conductor-kernel — overview](docs/media/infographic.png)

`conductor-kernel` is a Claude Code plugin that exports orchestration primitives, validators, security agents, and supporting skills that downstream **domain plugins** depend on to run tier-classified, gate-enforced, audit-logged multi-agent workflows.

> **Media & docs:** a system-overview [slide deck](media/), [explainer video](media/), and [briefing document](media/system-overview.md) accompany this repo (generated with NotebookLM; raster text may contain minor spelling artifacts). Full docs live in [`docs/`](docs/).

The kernel does **not** expose any slash command of its own. Domain plugins consume the kernel via the qualified-name agent dispatch contract (`conductor-kernel:<agent>`) and the kernel-defined primitives documented in [`API.md`](API.md).

---

## Why it exists

Most multi-agent Claude Code setups end up reinventing the same five things:

1. **Dispatch contract** — how one agent calls another, how budgets are tracked, how retries work.
2. **Validation loop** — how a second model checks a first model's output before accepting it.
3. **Audit trail** — how every action is recorded so security and compliance teams can reconstruct what happened.
4. **State machine** — how a workflow's progress is persisted across the inevitable conversation restart.
5. **Gate enforcement** — how human approval is required before destructive or sensitive actions.

`conductor-kernel` ships these five concerns as a stable, single-import surface. Build your domain plugin against it; do not re-implement.

---

## Quick start (30 seconds)

```bash
# 1. Install the kernel
/plugin install /path/to/conductor-kernel

# 2. Install governance-plugin (required dependency for the audit trail)
/plugin install /path/to/governance-plugin

# 3. (Optional) Install the reference example domain plugin to see the contract in action
/plugin install /path/to/conductor-kernel/examples/example-domain

# 4. Try the reference example
/example hello
```

If `/example hello` returns a validated greeting with an audit row in `governance-plugin/state/audit.db`, your kernel is wired correctly.

For a deeper walkthrough, read [`examples/example-domain/README.md`](examples/example-domain/README.md) — total reading time 10 minutes, total integration time ~30 minutes for a new contributor.

---

## Cross-plugin dispatch — the one-line example

This is the load-bearing pattern downstream consumers care about. From a domain agent:

```
Dispatch conductor-kernel:critic with output=<my-output> expectation=<my-expectation>
  -> returns PASS or NEEDS_REWORK
```

That's it. Every other primitive is some variation of this pattern. See [`API.md §6`](API.md) for the full dispatch contract.

---

## What this plugin exports

- **19 domain-agnostic agents** — critic, gemini-validator, recovery-engine, outcome-collector, checkpoint, event-router, ciso, llm-security, pentest-coordinator, secrets-lifecycle, supply-chain-security, research, retrospective, compliance, compliance-overview, prediction-engine, completeness-validator, bug-find, analyze-codebase.
- **14 domain-agnostic skills** — context-management, retry-policy, self-healing, state-management, event-automation, outcome-measurement, predictive-scaling, process-knowledge, sbr, dashboard-integration, brd-tracking, workflow-reference, agent-capabilities, agent-interop.
- **Workflow- and stream-mode primitives** — `dispatch_agent`, `dispatch_agent_v2` (envelope form for untrusted content per F-02), `gates_evaluate_and_enforce`, `audit_emit`, `memory_recall`, `gemini_validate`, `state_init`, `state_advance`, `recovery_classify`, `recovery_apply` and friends.
- **Base state schemas** — `workflow-state.schema.json` (v3.0, backward-compatible with v1.0/v2.0 per REQ-CDV-002) and `stream-state.schema.json` (v3.0).
- **Verification scripts** — `verify-cross-plugin-dispatch.sh`, `verify-audit-emission.sh`, `verify-agent-tools.sh`.

---

## Architecture overview

The kernel sits beneath domain plugins and above the governance-plugin audit trail:

```
   domain plugin (your code)
            |
            v
       conductor-kernel  <---- dispatches into kernel-provided agents,
            |                  enforces gates, emits audit, persists state
            v
       governance-plugin (audit trail, approval gates, manifests)
```

Full architecture details, primitive signatures, error codes, schemas, and stability commitments are in [`API.md`](API.md). Read that file before integrating.

For the threat model, coordinated disclosure policy, data-flow boundaries, and hardening recommendations, see [`SECURITY.md`](SECURITY.md).

---

## Documentation

| File | Purpose |
|------|---------|
| [`API.md`](API.md) | Full public API contract — every export is a stability commitment. Read this before integrating. |
| [`SECURITY.md`](SECURITY.md) | Threat model, coordinated disclosure, supported versions, data flows, hardening recommendations, known limitations. |
| [`CHANGELOG.md`](CHANGELOG.md) | Release notes per semver. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute — PR process, code style, signing requirements, scope guidance. |
| [`lib/dispatcher-core.md`](lib/dispatcher-core.md) | Canonical orchestration prose duplicated by domain command files via BEGIN_CANONICAL / END_CANONICAL markers. |
| [`examples/example-domain/`](examples/example-domain/) | Reference domain plugin demonstrating the integration contract end-to-end. |

---

## Installation

### From marketplace (once published)

```
/plugin marketplace install conductor-kernel
```

### Local development

```
/plugin install /path/to/conductor-kernel
```

---

## Status

**v0.1.0** — first OSS-quality contract. The agents/skills surface and the core dispatch / audit / memory / recovery / workflow primitives are stable. Stream-mode primitives ship as API surface in v0.1.0; their implementation lands in Phase 3.

See [`API.md §11 Versioning Rules`](API.md) for how semver applies to each part of the surface.

---

## Security

Security issues: see [`SECURITY.md §17.2`](SECURITY.md) for the coordinated disclosure policy. Do **not** open public issues or PRs for vulnerabilities.

---

## License

[Apache-2.0](LICENSE). The kernel ships with zero direct runtime dependencies, so the SBOM ([`sbom.cdx.json`](sbom.cdx.json)) lists the kernel as a single root component with no transitive dependencies.

---

## Acknowledgments

The kernel is extracted from a private orchestration system that powered tier-classified multi-agent development workflows since 2024. The OSS release is the canonical home of the orchestration contract; the originating system continues as one of several domain-plugin consumers.
