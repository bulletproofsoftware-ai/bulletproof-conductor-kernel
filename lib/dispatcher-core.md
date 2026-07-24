# Dispatcher Core — Canonical Orchestration Prose

**Canonical source for `conductor-kernel` orchestration semantics.**

This file is the canonical, domain-agnostic prose that domain command files (`conductor-dev/commands/conduct.md`, `clue-soc/commands/clue.md`, and any future 3rd-domain command) duplicate verbatim via the `<!-- BEGIN_CANONICAL ... -->` / `<!-- END_CANONICAL -->` marker pattern documented in `API.md §9`. Drift between this file and any duplicating domain file is caught by `scripts/ci-dispatcher-diff.sh` (RC-16 hash gate + content diff).

Per directive D3.2 in `directive-resolutions.md`, this file covers the **how** of orchestration: tier classification, agent dispatch, token-budget accounting, spec-alignment, builder readback, the Gemini-validation loop, gate enforcement, state persistence, context management, the workflow-template summaries, and the critical rules. Domain-specific **what** prose (BRD-tracker hooks, phase ladders, `/conduct` and `/clue` argument routing) belongs in the consuming command file, OUTSIDE the canonical block.

---

## 1. Tier Classification

Score the request using 5 signals. The signal vocabulary is domain-supplied via `domains/<domain>/tier-matrix.yaml`; the dev domain uses the matrix below.

| Signal | Weight | Scale |
|--------|--------|-------|
| Scope | 0.25 | 1 (single file) → 4 (new repo) |
| Type | 0.20 | 1 (bugfix) → 4 (greenfield) |
| Risk | 0.20 | 1 (reversible) → 4 (irreversible) |
| Ambiguity | 0.15 | 1 (crystal clear) → 4 (unknowns) |
| Intent Sensitivity | 0.20 | 1 (no hard limits touched) → 4 (intersects multiple hard limits) |

`weighted_score = (scope × 0.25) + (type × 0.20) + (risk × 0.20) + (ambiguity × 0.15) + (intent_sensitivity × 0.20)`

| Score | Tier |
|-------|------|
| 1.0–1.5 | TRIVIAL |
| 1.6–2.3 | MINOR |
| 2.4–3.2 | STANDARD |
| 3.3–4.0 | MAJOR |

SOC and other domains supply their own 5-signal vocabularies and weights via `tier-matrix.yaml`; both pass through `kernel.workflow.tier_classify` (API.md §4) with the same primitive contract.

The primitive emits a `workflow.tier_classified` audit event with the full result (`score`, `tier`, `rationale`, signals, weights). Tier classification weights MUST sum to 1.0 (±0.001 tolerance); violations produce `KER-TC-002`.

---

## 2. Agent Dispatch

All kernel agents are dispatched via qualified `<plugin>:<agent>` names through the Task tool:

```
Task(subagent_type="conductor-kernel:critic", prompt="...", description="Critic review")
```

Domain-plugin agents follow the same pattern (`conductor-dev:architect`, `clue-soc:root-cause-coder`, etc.). External agents not bundled in any plugin are dispatched without a prefix and degrade gracefully if unavailable.

Cross-plugin dispatch is mediated by `kernel.dispatch_agent(qualified_name, prompt, expectation, budget?)` and its envelope-form sibling `kernel.dispatch_agent_v2(qualified_name, prompt_envelope, expectation, budget?)`. The envelope form (API.md §6) is **mandatory** whenever any untrusted content (logs, user input, external alert content, file contents from disputed sources) is interpolated into the prompt; CLUE Phase 4 binds this requirement on its destructive-containment paths.

A runtime collision check enforces that the resolved agent's source plugin matches the prefix in `qualified_name`. Mismatch → `KER-DA-006 namespace_collision` (RC for F-01).

### 2.1 Token Budget Tracking (MANDATORY — Every Agent Dispatch)

After every agent dispatch returns, record token usage in the workflow-state file under `token_budget`:

```json
{
  "token_budget": {
    "total_input_tokens": 0,
    "total_output_tokens": 0,
    "total_cost_usd": 0.00,
    "dispatches": [
      {
        "agent": "<plugin>:<agent>",
        "model": "opus|sonnet|haiku",
        "phase": "Phase 1",
        "input_tokens": 12500,
        "output_tokens": 8200,
        "cost_usd": 0.80,
        "timestamp": "ISO-8601"
      }
    ],
    "by_phase": { "Phase 1": { "input": 0, "output": 0, "cost": 0.00, "dispatches": 0 } },
    "by_model": { "opus": { "input": 0, "output": 0, "cost": 0.00, "dispatches": 0 } }
  }
}
```

**Cost rates** (per 1M tokens) — operator-adjustable in deployment config:

| Model  | Input    | Output   |
|--------|----------|----------|
| opus   | $15.00   | $75.00   |
| sonnet | $3.00    | $15.00   |
| haiku  | $0.80    | $4.00    |

**Recording flow:**
1. Before dispatch, note the agent name and its model tier (from agent frontmatter).
2. After agent returns, estimate tokens from output length (chars / 4 ≈ tokens) or use actual counts if available.
3. Compute cost: `(input_tokens / 1M × input_rate) + (output_tokens / 1M × output_rate)`.
4. Append to `dispatches[]`, increment `by_phase` and `by_model` accumulators.
5. Update `total_*` fields.

**Denial-of-wallet protection (RC-7 / F-09).** Per `lib/budget-defaults.yaml`, every dispatch is bounded by a per-trace budget (`max_input_tokens`, `max_output_tokens`, `max_cost_usd`, `max_dispatches_per_minute_per_trace`). Budget exceeded → audit event `dispatch.budget_exceeded` + return code `KER-DA-005`. Stream-mode amplifies this risk and MUST supply a stream-level budget at `kernel.stream.init` time (`KER-SI-006` if absent).

### 2.2 Spec Alignment Check (MANDATORY — After Architect, Before Builder)

After an architecture/plan agent produces output, validate it against the original user description BEFORE any implementation begins. This catches comprehension errors early.

**Dispatch flow:**
1. The architecture/plan agent returns its document.
2. Before dispatching the implementer, dispatch `conductor-kernel:critic` in spec-alignment mode with the prompt:

   > **SPEC ALIGNMENT CHECK** — Compare architect output against original request.
   >
   > ORIGINAL USER REQUEST: `{original project description}`
   > ARCHITECT OUTPUT: `{first ~3000 chars of architecture document}`
   >
   > Check for:
   > a) Does the architecture address ALL stated requirements?
   > b) Does it introduce scope not requested?
   > c) Are there ambiguities that could cause the builder to make wrong assumptions?
   > d) Are there requirements the architect appears to have misunderstood?
   >
   > Respond with one of:
   > - **ALIGNED** — Architecture matches intent. Proceed.
   > - **DRIFT** — `[list specific mismatches]`. Recommend re-dispatch architect with corrections.
   > - **AMBIGUOUS** — `[list items needing clarification]`. Recommend asking the user before proceeding.

3. If `DRIFT` → re-dispatch architect with specific corrections.
4. If `AMBIGUOUS` → escalate to the operator with the specific questions.
5. If `ALIGNED` → proceed to the implementer.

Record the result in `state.spec_alignment`:

```json
{
  "spec_alignment": {
    "verdict": "ALIGNED|DRIFT|AMBIGUOUS",
    "issues": [],
    "checked_at": "ISO-8601",
    "re_dispatches": 0
  }
}
```

### 2.3 Builder Readback (MANDATORY — Before Implementation Starts)

Before any implementer agent begins writing code, require it to echo back its understanding. Aviation-style readback catches handoff ambiguity before code is written.

**Inject into implementer dispatch prompt:**

> **READBACK REQUIRED** — Before writing any code, respond with a Readback section:
>
> ## Readback
> 1. **My understanding of the task** (1-3 sentences)
> 2. **Key files I will create/modify** (list)
> 3. **Approach** (1-2 sentences on implementation strategy)
> 4. **Assumptions I'm making** (list any gaps you're filling with assumptions)
> 5. **Questions (if any)** (anything unclear)
>
> Then proceed with implementation.

**Orchestrator checks the readback:**
1. If the implementer lists assumptions → flag for operator review before continuing.
2. If the implementer lists questions → escalate to operator.
3. If the readback contradicts the architecture → halt and re-dispatch with corrections.
4. If the readback aligns → implementation proceeds.

Record in `state.builder_readback`:

```json
{
  "builder_readback": {
    "understanding_summary": "...",
    "files_planned": [],
    "assumptions": [],
    "questions": [],
    "verdict": "PROCEED|ESCALATE|CORRECT",
    "checked_at": "ISO-8601"
  }
}
```

### 2.4 Gemini Validation Protocol (MANDATORY — Every Agent Run)

After EVERY agent dispatch returns, run independent Gemini validation before proceeding. Agents do not grade their own homework. This protocol is the contract documented at `kernel.gemini_validate` (API.md §6).

**Per RC-10 / F-17**, every invocation MUST declare a `data_classification` argument (`public` | `internal` | `confidential` | `regulated`). Default operator policy refuses `regulated` without an explicit `operator_override`. The primitive emits `validation.gemini` audit events with the classification recorded.

#### Dispatch flow (for every agent):

1. Record pre-dispatch state (expected deliverables, files snapshot).
2. Dispatch the agent via Task tool.
3. Agent returns output.
4. Collect evidence: `files_changed` (git diff --name-only), agent-output summary.
5. Dispatch `conductor-kernel:gemini-validator` with the evidence package.
6. Record validation result in `state.gemini_validations[]`.
7. Apply verdict (proceed / re-dispatch / escalate).

#### Validation dispatch template:

```
Task(subagent_type="conductor-kernel:gemini-validator", prompt="
  agent_name:            {agent that just ran (qualified name)}
  task_description:      {what it was asked to do}
  expected_deliverables: {from handoff.expectations[]}
  actual_output_summary: {first ~2000 chars of agent output}
  project_root:          {cwd}
  files_changed:         {git diff --name-only output}
  data_classification:   {public|internal|confidential|regulated}
", description="Gemini validation: {agent_name}")
```

#### Verdict actions:

| Verdict | Completion | Action |
|---------|-----------|--------|
| PASS    | 100%      | Proceed to next step |
| PARTIAL | ≥70%      | Log advisory, proceed with warning |
| PARTIAL | <70%      | BLOCK — re-dispatch agent with gaps from Gemini's evidence |
| FAIL    | any       | BLOCK — re-dispatch (attempt 1) or escalate to operator (attempt 2+) |
| ERROR   | n/a       | Log Gemini unavailability, proceed (non-blocking degradation) |

#### Remediation loop (finding-level resolution):

When Gemini returns FAIL or PARTIAL(<70%), run the **finding resolution loop**:

```
FOR each issue in gemini_validation.issues[]:
  1. DISPATCH remediation agent (same agent type that originally ran) with prompt:

     "REMEDIATION TASK — Gemini validation found this specific issue:

      FINDING:       {issue text}
      FILE(S):       {relevant files from Gemini's evidence}
      ORIGINAL TASK: {original task_description}

      You MUST:
      a) Read the file(s) cited
      b) Fix the specific issue described
      c) Respond with EVIDENCE of resolution:
         - What you changed (file:line)
         - Why it resolves the finding
         - Any side effects

      Do NOT re-implement the entire task. Fix ONLY this finding."

  2. RECORD the agent's resolution evidence.

  3. After ALL findings are addressed, run TARGETED re-validation:
     DISPATCH conductor-kernel:gemini-validator with:
       mode:                "targeted"
       original_issues:     {the specific issues from the first validation}
       resolution_evidence: {what the remediation agent reported for each}
       files_changed:       {git diff --name-only since remediation started}

  4. IF targeted re-validation returns PASS → proceed
     IF targeted re-validation returns FAIL → increment attempt counter
       - Attempt 2: re-run remediation loop for remaining failures
       - Attempt 3+: ESCALATE to operator with full finding history
```

**Key principle**: the remediation agent addresses each finding individually with cited evidence; Gemini re-validates only the specific findings, not a full re-review. Tight, focused loop.

#### Attempt limits:

- Max 2 full remediation loops per agent per step.
- After 2 loops with unresolved findings, escalate to operator with:
  - Original task description.
  - All Gemini findings (with PASS/FAIL per finding across attempts).
  - The remediation agent's resolution evidence for each attempt.
  - Gemini's re-validation responses.
- Track attempt counts in `state.gemini_validations[]` entries.

#### Exceptions (validation skipped):

- `conductor-kernel:gemini-validator` itself (no recursive validation).
- Agents that produce no file artifacts (pure advisory/status agents).
- When Gemini CLI is unavailable (degrade gracefully, log warning).

---

## 3. Gate Enforcement

At every phase transition:
1. Run inline discipline checks (SEQUENCE, DRIFT, SCOPE, LOOP, SCHEDULE).
2. Invoke `conductor-kernel:critic` at defined verification checkpoints.
3. Gate mode (advisory / blocking / skip) is determined by tier.

Verification gates the kernel recognizes (the canonical list maps to `state.verification_status[*]`):

```
post_architect, post_ciso, post_qa, post_implementation,
post_pentest, post_supply_chain, pre_release, completeness_validation
```

Domain plugins may add additional gate ids under `state.verification_status` freely.

**PostToolUse hook enforcement**. Phase transitions are programmatically enforced by `hooks/scripts/post-state-write.sh`. When the state file is written with a new `current_phase.number`, the hook checks all required verification gates for the previous phase. For STANDARD and MAJOR tiers, missing or non-`pass` gates cause the write to be **blocked** (exit 1). MINOR and TRIVIAL tiers receive advisory warnings only. The hook also blocks phase transitions when uncommitted git changes are detected (git ratcheting). This ensures mandatory gates cannot be bypassed by the orchestrating LLM.

**HUMAN_GATE invariant (RC-3 / F-07)**. Destructive-containment gates use `kernel.workflow.gates_evaluate_and_enforce` (API.md §4). The enforce form BLOCKS on `human_gate`, dispatches governance, waits for resolution, and writes the resulting state itself. A caller-written `state_advance({kind: "gate_pass"})` lacking a prior gate-resolution audit row fails with `KER-GE-002 unresolved_gate_pass`. The advisory `kernel.workflow.gates_evaluate` form is deprecated at v0.1.0 and removed at v1.0.0.

---

## 4. State Persistence

After every significant action:
- Update the workflow-state file with the current position via `kernel.workflow.state_advance` (API.md §4).
- Record completed tasks, handoffs, and gate results.
- Commit state files to git (atomic checkpoint pattern).

Direct file edits to the state file are non-conforming and will cause `post-state-write.sh` to fail (RC-13 / F-18 + state-machine invariant). All mutations go through `state_advance`.

The base state schema is `schemas/workflow-state.schema.json` (kernel v3.0). Domain plugins extend via `domain_extensions` per REQ-KER-003; the kernel never reads or writes inside `domain_extensions`. Top-level `additionalProperties: false` enforces that all forward-compatible extensions land in `domain_extensions`.

---

## 5. Context Management

The `conductor-kernel:context-management` skill is the canonical reference for context-budget rules. Key invariants:

- Maximum 3 specs per planning session.
- Monitor context budget (60% rule — the orchestrator stops absorbing new context at 60% of the model's window and starts shedding via handoff documents).
- Generate handoff documents at phase boundaries.
- Spawn subagents with fresh context for each TODO spec.

The skill's SKILL.md prescribes the handoff template; the orchestrator's responsibility is to invoke it at the right moments.

---

## 6. Outcome Emission

On workflow completion (terminal phase reached), `kernel.workflow.complete(state)` (API.md §4 REQ-KER-009) dispatches:

1. `conductor-kernel:outcome-collector` — computes the 10 outcome metrics (completion rate, TTR, first-pass rate, rework frequency, quality trend, recovery rate, context efficiency, cost per successful outcome, capacity hours released, escalation rate).
2. `conductor-kernel:retrospective` — captures KU/KI lessons learned, mines the trajectory for reusable patterns, writes `docs/ku-ki-<project>.yaml`.

Both dispatches are synchronous and emit `agent.dispatch` audit events. The aggregate output is the `outcome_report` returned from `kernel.workflow.complete`.

---

## 7. Workflow Template Summaries

The tier-appropriate workflow shapes summarized below are domain-agnostic; concrete agent choice depends on the domain.

```
TRIVIAL:  analyze-codebase
          → implementer (plan-and-implement)
          → verify

MINOR:    analyze-codebase
          → implementer (plan)
          → SPEC-ALIGNMENT-CHECK
          → implementer (READBACK + implement)
          → conductor-kernel:ciso (advisory)
          → conductor-kernel:critic (advisory)
          → verify
          → COMPLETENESS-VALIDATION (advisory)

STANDARD: Full multi-phase ladder.
          SPEC-ALIGNMENT-CHECK after architect.
          BUILDER-READBACK before implementer.
          critic advisory except PRE-RELEASE + POST-PENTEST blocking.
          → DOMAIN-HARDENING (domain-specific quality loop)
          → DOMAIN-ADVERSARIAL-REVIEW (dual-model review)
          → DOCUMENTATION
          → COMPLETENESS-VALIDATION (blocking)

MAJOR:    Same as STANDARD but ALL critic gates blocking.
```

`conductor-kernel:analyze-codebase`, `:critic`, `:ciso`, `:completeness-validator`, `:gemini-validator`, `:bug-find`, and the security/compliance/retrospective agents are the kernel-side participants. Domain plugins supply the architect, implementer, QA, and domain-specific hardening / adversarial-review phases.

---

## 8. Critical Rules

1. **NO PLACEHOLDERS** — Every function fully implemented, every integration actually connects.
2. **REQUIREMENT TRACEABILITY** — Every domain-specific requirement (BRD entry for dev, alert entry for SOC, etc.) tracked from extraction to completion. The kernel-side `conductor-kernel:brd-tracking` skill provides the lifecycle; the tracker location is per-domain.
3. **INDEPENDENT VERIFICATION** — Agent self-reporting is not trusted; the orchestrator verifies via `conductor-kernel:critic` and `:gemini-validator`.
4. **STRICT SEQUENCING** — No step skipped or reordered.
5. **MAX 2 RETRIES** — Then escalate to operator.
6. **GIT RATCHETING** — Commit after every logical change for recovery. The `post-state-write.sh` hook blocks phase transitions when uncommitted changes are detected.

---

*End of dispatcher-core.md v0.1.0. CI hash gate enforces this file's sha256 against the `sync_hash:` field in every duplicating domain file (`scripts/ci-dispatcher-diff.sh`).*
