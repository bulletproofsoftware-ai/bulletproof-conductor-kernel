---
name: conductor-context-management
description: |
  Context budget monitoring, the 60% rule, handoff document generation, and fresh context isolation. Use when monitoring context budget, generating handoffs, or managing context-aware spawning of subagents.
---

# Context Management

## The 60% Rule

Claude's output quality degrades as context fills. The conductor MUST monitor context usage and act before quality drops.

## Context Budget Thresholds

Context guard uses **distance-to-compaction** rather than absolute usage percentages, since context window size varies by model (check `context_window_size` from the API).

| Context Guard Level | Distance to Compaction | Action |
|---------------------|----------------------|--------|
| L0 (none) | >30% | Full capacity -- work normally |
| L1 | <=30% | MONITOR -- optimize usage, delegate to subagents |
| L2 | <=15% | APPROACHING -- save state, finish current step, pause |
| L3 | <=7% | CRITICAL -- save state immediately, stop after current op |
| L4 | <=3% | EMERGENCY -- save state NOW, complete only one more action |

For the authoritative action matrix, see `references/budget-thresholds.md`.

## Budget Estimation

```
estimated_tokens = total_conversation_words x 1.3
usage_percentage = (estimated_tokens / context_window_size) x 100
distance_to_compaction = 100% - usage_percentage
```

Note: `context_window_size` varies by model -- do not hardcode a value.

## Context-Aware Spawn Protocol

### L0 (>30% remaining)
Standard spawn. Include: spec file, BRD-tracker excerpt, interface summaries.

### L1 (<=30% remaining)
Lean spawn. Include ONLY: spec file (essential sections), BRD requirement ID and acceptance criteria, minimal interface signatures.

### L2 (<=15% remaining)
Checkpoint-first spawn:
1. Generate handoff document (see format below)
2. Store checkpoint
3. Spawn subagent with checkpoint summary + current spec only
4. Clear working state for current task

### L3/L4 (<=7% remaining)
**STOP current operation. Full handoff required.**
1. Do NOT spawn subagent in current context
2. Generate FULL handoff document
3. Store all decisions and state
4. Instruct user to start fresh session
5. Provide continuation prompt

## Handoff Document Format

For handoff format, see `references/handoff-format.md` (FULL format required for STANDARD/MAJOR tier, abbreviated acceptable for MINOR).

## Phase Checkpoint Format

At every phase boundary:

```markdown
## PHASE CHECKPOINT: [Phase N] → [Phase N+1]

**Generated**: [timestamp]
**Context Usage Estimate**: [X]%

### 1. ACCOMPLISHMENTS
- [Completed deliverable 1]
- [Key milestone achieved]

### 2. DECISIONS MADE
| Decision | Rationale | BRD-REQ |
|----------|-----------|---------|
| [Decision 1] | [Why] | REQ-XXX |

### 3. CURRENT STATUS
- **Position**: Phase [N] Complete
- **BRD Progress**: [X/Y] requirements at "[status]"
- **Files Created**: [count]
- **Tests Status**: [passing/failing/pending]

### 4. NEXT STEPS
**Immediate Action**: [Concrete next task]
**Expected Deliverable**: [What should be produced]
**Success Criteria**: [How to verify]
```

## Fresh Context Rules

- Maximum 3 specs per planning session
- After 3 specs OR hitting APPROACHING → reset counter, generate checkpoint
- Each TODO spec executed in isolated subagent with fresh context
- INCLUDE: single spec, BRD excerpt, interface definitions, project conventions
- EXCLUDE: other specs, full history, unrelated code, previous attempts

For handoff template, see `references/handoff-format.md`.
For budget action matrix, see `references/budget-thresholds.md`.

## Subagent Return Contract

The "Fresh Context Rules" above isolate what goes INTO a subagent. This rule governs what comes BACK. A subagent's final message is appended verbatim to the orchestrator's context — a subagent that burns 128k tokens and then echoes its full spec back adds that spec to the parent window in one shot. This is the dominant cause of mid-turn context spikes (a single dispatch can move the orchestrator from comfortable to compaction).

Every dispatched agent MUST follow the return contract, and the conductor injects it into every Task prompt via the constraint envelope:

1. **Write the full work product to a file** — spec → `/TODO/`, analysis/report → its named path, code → the repo. Never hold the deliverable only in the return message.
2. **Return a pointer, not a payload** — the final message contains only: file path(s), a ≤10-line summary, and any BLOCKING issues.
3. **Never echo** full file contents, full diffs, full command/tool output, or quoted source in the return message.
4. **The orchestrator reads the file** when it needs detail; it does not need the content inlined.

A subagent that violates this contract is treated as a partial failure by the critic/gemini-validator (the deliverable file is the artifact of record, not the chat message).

## Enforcement (context-guard interlock)

These rules are mechanically backed by the `context-guard` plugin's PreToolUse hook (v3.1+):

- At **L4 (≤3% to compaction)** the hook **hard-blocks `Task` dispatches** (`decision: block`) — the "L3/L4: do NOT spawn subagent" rule is enforced even if the orchestrator tries to dispatch anyway. State-saving tools stay open so the handoff can still be written.
- L3/L4 escalation announcements and a persistent L4 reminder fire on every tool use, instructing immediate state-save and fresh-session handoff.

Do not rely on the hook as the primary control — honor the CONTEXT GATE proactively. The hook is the backstop for when the model misses its own gate.

## Three-Tier Memory Model (Hermes E4)

Memory is organized in three tiers, each with distinct mutation semantics:

| Tier | Surface | Mutation | Bound | Decay |
|---|---|---|---|---|
| **Live Notes** | `~/.claude/memory/MEMORY.md` `<!-- LIVE_NOTES_* -->` region | `memory-note.sh add/replace/remove` | 2200 chars | Agent-rewritten naturally; capacity header signals saturation |
| **Index** | `~/.claude/memory/MEMORY.md` outside the markers | Operator-only (hard limit) | None | Stable, version-controlled |
| **Qdrant** | `memory_store` MCP tool | Agent + n8n consolidation | None (tiered storage) | Hippocampal sweep per Barman driver |

### When To Use Each

- **Current task scratchpad, transient observation, "I just learned X about this session"** → Live Notes via `memory-note.sh add`. Decays naturally as the agent rewrites.
- **Stable file-reference pointer, "this concept lives at path P"** → propose Index edit to operator; do NOT write directly.
- **Trajectory, procedure, episode, anything that should survive future sessions** → `memory_store` to Qdrant. Pin if it must defend against weekly consolidation drain.

### Hard Limit

Agent attempts to write to MEMORY.md outside the `<!-- LIVE_NOTES_* -->` region are refused by the protection script. The Live Notes region is the ONLY agent-writable surface in MEMORY.md.
