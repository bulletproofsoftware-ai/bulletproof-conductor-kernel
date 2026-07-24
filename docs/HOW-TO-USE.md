# How to use conductor-kernel

The kernel exports **no slash command**. You use it by building a **domain plugin**
that dispatches the kernel's agents and calls its primitives. This guide shows the
load-bearing patterns. The authoritative, per-primitive contract (inputs, outputs,
error codes) is [`../API.md`](../API.md); this document is the task-oriented
companion.

The fastest way to learn the contract hands-on is the reference plugin at
[`../examples/example-domain/`](../examples/example-domain/) — ~10 minutes to read,
~30 minutes to adapt into your own domain.

---

## The one pattern everything is built on

From any domain agent or command, you dispatch a kernel agent by its qualified
name and read back a structured verdict:

```
Dispatch conductor-kernel:critic with output=<my-output> expectation=<my-expectation>
  -> returns PASS or NEEDS_REWORK (with structured gap analysis)
```

Under the hood this is Claude Code's Task tool with a qualified `subagent_type`:

```
Task(subagent_type="conductor-kernel:critic", prompt=...)
```

This resolves as long as `conductor-kernel` is installed in the same session. Every
other kernel capability is a variation of this dispatch-and-read-verdict shape.

---

## Workflow mode — a bounded task, start to finish

Workflow mode is for a task with a beginning and an end (build a feature,
investigate an alert, produce a document). The lifecycle:

### 1. Classify the tier

```
kernel.workflow.tier_classify(description, signals) -> tier_result
```

- `signals` is a domain-specific 5-signal map. The dev domain uses
  `{scope, type, risk, ambiguity, intent_sensitivity}`; a SOC domain uses
  `{impact, scope, confidence, data_classification, reversibility}`.
- `weights` are loaded from **your** domain's `tier-matrix.yaml` and must sum to
  1.0 (±0.001).
- Result: a `tier` in `{TRIVIAL, MINOR, STANDARD, MAJOR, CRITICAL}` plus a score
  in `[1.0, 4.0]` and a rationale.

The tier drives which gates are blocking vs. advisory (see the `critic` agent's
per-tier gate matrix).

### 2. Initialize state

```
kernel.workflow.state_init(domain, tier, schema_extension, state_path) -> state
```

- Writes a state file validated against
  [`workflow-state.schema.json`](../schemas/workflow-state.schema.json) merged
  (`allOf`) with your domain's `schema_extension`.
- `state_path` is validated to be **inside the current working directory** — path
  traversal, symlink escape, and special files are rejected (`KER-SI-003` /
  `KER-SI-007`), and nothing is written on violation.
- Put all your domain-specific fields under `domain_extensions` — the kernel never
  reads or writes inside that object.

### 3. Advance state — the only legal way to mutate

```
kernel.workflow.state_advance(state_path, event) -> state'
```

- `event.kind` is one of `{phase_transition, step_complete, gate_pass, gate_fail,
  agent_dispatch, agent_return}`.
- **All** mutations go through this primitive. Direct edits to the state JSON are
  non-conforming and the `post-state-write.sh` hook will fail them. This is the
  canonical state-machine enforcement point.

### 4. Dispatch agents as you go

```
kernel.dispatch_agent(qualified_name, prompt, expectation, budget?) -> output
```

- Use this **string form** only for **trusted** prompts you authored.
- For **any untrusted content** (logs, user input, external alert bodies, file
  contents from disputed sources), use the envelope form:

```
kernel.dispatch_agent_v2(qualified_name, prompt_envelope, expectation, budget?) -> output
```

`prompt_envelope.user_untrusted[]` regions are wrapped by the kernel in
`<UNTRUSTED:label>...</UNTRUSTED:label>` blocks with a fixed prompt-isolation
preamble telling the model to treat that content as **data, not instructions**.
This is the kernel's prompt-injection boundary — use it whenever untrusted text
enters a prompt.

Both forms enforce a **token/cost budget** (defaults from
[`../lib/budget-defaults.yaml`](../lib/budget-defaults.yaml)); exceeding it returns
`KER-DA-005 budget_exceeded` and emits a `dispatch.budget_exceeded` audit event.

### 5. Validate with a second opinion

```
kernel.critic_review(claim, evidence) -> ACCEPT | REJECT | ACCEPT_WITH_FINDINGS
kernel.gemini_validate(output, expectation, target_agent, data_classification?) -> PASS|FAIL|PARTIAL|ERROR
```

- `critic_review` is a fully local second opinion (dispatches
  `conductor-kernel:critic`).
- `gemini_validate` egresses the output to Google's Gemini API. You **must** set
  `data_classification`; the default operator policy refuses `regulated` data
  without an explicit `operator_override` (`KER-GV-004`). This is the single
  largest data-egress surface in the kernel — treat it deliberately.

### 6. Enforce gates (including human approval)

```
kernel.workflow.gates_evaluate_and_enforce(state) -> enforced_gate_result
```

- This is the **enforce-and-write** gate primitive. On a `human_gate`, it invokes
  governance, **blocks** until the operator approves/rejects (default 24h timeout),
  and the **kernel itself** writes the resulting `gate_pass` / `gate_fail` state.
- A caller cannot bypass a human gate by writing `state_advance({kind:"gate_pass"})`
  itself — doing so without a prior gate-resolution audit row fails with
  `KER-GE-002`.
- The older advisory `kernel.workflow.gates_evaluate` is **deprecated** at v0.1.0
  and removed at v1.0.0; new code must use the enforce form.

### 7. Complete

```
kernel.workflow.complete(state) -> outcome_report
```

Dispatches `conductor-kernel:outcome-collector` (10 metrics) and
`conductor-kernel:retrospective` (KU/KI lessons) and emits a `workflow.complete`
audit event.

---

## Stream mode — long-lived, event-driven (experimental)

Stream mode is for a continuous subscription (a webhook, a cron, an event bus) that
spawns work as events arrive. Primitive **signatures** are stable at v0.1.0; the
reference implementation under [`../lib/stream/`](../lib/stream/) is marked
experimental.

```
kernel.stream.init(domain, subscriptions, schema_extension, budget) -> stream_id
kernel.stream.handle_event(stream_id, event, auth_material) -> handler_result
kernel.stream.state_get / state_mutate / pause / resume / health / spawn_workflow
```

Two non-negotiable requirements baked into the contract:

- **Authentication is mandatory per subscription** (RC-4). Every subscription
  declares `authentication.kind`; `handle_event` verifies auth **before** schema
  validation, and auth failures drop the event to a DLQ with **no** agent dispatch.
  `kind: "none"` is allowed only when the operator explicitly acknowledges the risk.
- **A budget is mandatory at `init`** (RC-7) — stream mode amplifies
  denial-of-wallet risk, so a per-event and per-stream-hour budget is required or
  `init` returns `KER-SI-006`.

Stream state persists to a Qdrant collection keyed by `stream_id`; see
[`../lib/stream/STATE-PERSISTENCE.md`](../lib/stream/STATE-PERSISTENCE.md).

---

## Memory (optional)

```
kernel.memory_recall(query, filters) -> memories
kernel.memory_store(content, payload) -> memory_id
```

- `filters.domain` is **mandatory** on recall; absence is an error
  (`KER-MR-003`), and you cannot recall another domain's memories via the standard
  primitive (`KER-MR-005`) — domain isolation is enforced inside the kernel, not
  trusted from the caller.
- On store, `payload.domain` and `payload.stored_by` are **auto-injected** from your
  caller context and cannot be forged; a mismatching supplied value is stripped and
  audited.

Requires `claude-memory-mcp` (local Qdrant) — no network egress.

---

## Recovery

```
kernel.recovery_classify(error, override_playbook?) -> strategy
```

Classifies an error into one of 7 categories and recommends a strategy
(`retry`, `fallback_agent`, `model_downgrade`, `graceful_degrade`,
`wait_and_retry`, `escalate`). Caller-supplied override playbooks are honored only
for **non-destructive** categories, or when the override file is cosign-signed —
so a benign "retry" can't be substituted for a failed destructive action.

---

## Everything is audited

Every primitive emits a `governance-plugin` audit row via `kernel.audit_emit`. That
is the single authoritative trail: append-only, mode `0600`, HMAC-token-protected
writes. If you process PII/PHI/regulated content, register a redactor with
`kernel.audit_register_redactor` **before** dispatching, or pass `prompt_ref` /
`response_ref` (hash + storage URI) instead of literal content.

---

## Wiring your domain command

Every domain command that uses the kernel must fail loud if the kernel is absent:

```
CHECK: Resolve 'conductor-kernel:critic' via Task subagent_type.
  IF resolution fails:
    EMIT: "conductor-kernel not installed.
           Install via: /plugin marketplace install conductor-kernel
           This plugin requires conductor-kernel >= 0.1.0."
    EXIT (do not proceed silently)
```

If your command duplicates the canonical orchestration prose from
[`../lib/dispatcher-core.md`](../lib/dispatcher-core.md), wrap it in
`<!-- BEGIN_CANONICAL ... -->` / `<!-- END_CANONICAL -->` markers and record the
`sync_hash`; CI (`scripts/ci-dispatcher-diff.sh`) fails the build on drift.

---

MIT © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
