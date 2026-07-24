---
name: conductor-state-management
description: |
  conductor-state.json lifecycle management including creation, validation, updates, and recovery. Use when creating or validating conductor-state.json, checking workflow position, or recovering from state corruption.
---

# State Management

## conductor-state.json Overview

The `conductor-state.json` file is the single source of truth for workflow orchestration state. It tracks:

- Current phase and step position
- Tier classification and scoring
- Task queue with dependencies
- Completed/blocked/failed tasks
- Verification gate status
- Agent handoff history
- Checkpoint records
- Circuit breaker state

## Schema

The canonical schema is at `schemas/conductor-state.schema.json` in the plugin root. Key required fields:

```json
{
  "project_name": "string (required)",
  "initiated_at": "ISO-8601 (required)",
  "last_updated": "ISO-8601 (required)",
  "current_phase": { "number": 0, "name": "string", "started_at": "ISO-8601" },
  "current_step": { "number": 0, "name": "string", "status": "pending|in_progress|awaiting_input|blocked|completed" },
  "task_queue": [],
  "completed_tasks": [],
  "verification_status": {}
}
```

## Lifecycle

### Creation (Phase 0 / Session Start)

When no state file exists:

```json
{
  "project_name": "[from user]",
  "initiated_at": "[now]",
  "last_updated": "[now]",
  "workflow_type": "new|existing|ui-heavy|brd-provided",
  "tier": "[classified tier]",
  "tier_score": 0.0,
  "tier_override": false,
  "tier_signals": { "scope": 0, "type": 0, "risk": 0, "ambiguity": 0 },
  "current_phase": { "number": 0, "name": "Project Initialization", "started_at": "[now]" },
  "current_step": { "number": 0, "name": "Initialize", "status": "pending" },
  "task_queue": [],
  "completed_tasks": [],
  "blocked_tasks": [],
  "failed_tasks": [],
  "checkpoints": [],
  "handoff_history": [],
  "remediation_loops": 0,
  "total_critic_rejections": 0,
  "agents_invoked": [],
  "verification_status": {
    "post_ciso": null,
    "post_extraction": null,
    "post_architect": null,
    "post_qa": null,
    "post_implementation": null,
    "post_pentest": null,
    "pre_release": null,
    "advisory_findings": []
  },
  "audit_sink": {
    "enabled": false,
    "transport": "substrate",
    "substrate_python": "python3",
    "substrate_cwd": null,
    "events_to_emit": [
      "phase_transition", "gate_pass", "gate_block", "gate_decision",
      "nhi_spawn", "nhi_terminate", "handoff", "gemini_validation",
      "escalation", "workflow_complete"
    ],
    "emit_count": 0,
    "last_error": null
  }
}
```

**`audit_sink` (default OFF).** Seeded into every new state so the durable-audit wiring is one
flag away, never a from-scratch addition. The PostToolUse hook (`audit_emitter.py`) is a no-op
while `enabled` is false. To record each state-transition as a hash-chained, HMAC-anchored row on
the **substrate-orchestrator** audit chain, set `enabled: true` and point the shell-out at the
substrate venv + repo:

```json
"audit_sink": {
  "enabled": true,
  "transport": "substrate",
  "substrate_python": "/abs/path/to/substrate-orchestrator/.venv/bin/python",
  "substrate_cwd": "/abs/path/to/substrate-orchestrator",
  "events_to_emit": ["phase_transition", "gate_pass", "gate_block", "gate_decision", "workflow_complete"]
}
```

The substrate repo must be reachable (its `.env` provides `APP_DATABASE_URL`/`AUDIT_HMAC_KEY`); a
substrate that is down NEVER blocks the conductor state write (the emitter is fail-open, recording
the failure in `audit_sink.last_error`). Other transports (`syslog`/`http`/`file`) use
`syslog_target` instead — see `audit_emitter.py`.

### Updates

Update `last_updated` on EVERY write. Key update triggers:

| Event | Fields Updated |
|-------|---------------|
| Phase transition | `current_phase`, `current_step`, `task_queue` |
| Step completion | `completed_tasks` (append), `task_queue` (remove), `current_step` |
| Agent handoff | `handoff_history` (append), `agents_invoked` (add) |
| Critic checkpoint | `verification_status.[checkpoint]`, `total_critic_rejections` |
| Task failure | `failed_tasks` (append), `remediation_loops` |
| Checkpoint created | `checkpoints` (append) |

### Validation

After every write, validate against the schema. The PostToolUse hook automatically validates writes to `conductor-state.json`.

### Recovery

If state file is corrupted:
1. Check `checkpoints[]` for last valid checkpoint
2. Restore from checkpoint's `git_sha`
3. Rebuild state from git log if needed
4. Never proceed with corrupted state

For detailed examples per phase, see `references/state-examples.md`.
For full schema documentation, see `references/state-schema.md`.
