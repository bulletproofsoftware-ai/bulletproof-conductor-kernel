# conductor-state.json Schema Documentation

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `project_name` | string | Name of the project being orchestrated |
| `initiated_at` | date-time | When orchestration started |
| `last_updated` | date-time | Last state update |
| `current_phase` | object | Current phase position |
| `current_step` | object | Current step within phase |
| `task_queue` | array | Pending tasks with dependencies |
| `completed_tasks` | array | Successfully completed tasks |
| `verification_status` | object | Gate pass/fail status |

## Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `workflow_type` | enum | new, existing, ui-heavy, brd-provided |
| `tier` | enum | TRIVIAL, MINOR, STANDARD, MAJOR |
| `tier_score` | number (1.0-4.0) | Weighted classification score |
| `tier_override` | boolean | User manual override |
| `tier_signals` | object | Individual scope/type/risk/ambiguity scores |
| `gate_mode` | enum | advisory, blocking, mixed, skip |
| `blocked_tasks` | array | Tasks blocked by dependencies |
| `failed_tasks` | array | Dead letter queue |
| `checkpoints` | array | Checkpoint history |
| `handoff_history` | array | Agent-to-agent handoff records |
| `remediation_loops` | integer | Remediation cycle count |
| `total_critic_rejections` | integer | Critic rejection count |
| `agents_invoked` | array | Unique agent list |
| `project_characteristics` | object | Detected project features |
| `circuit_breaker` | object | Circuit breaker state |
| `cyclic_execution` | object | Cyclic verification tracking |

## Nested Object Schemas

### current_phase
```json
{
  "number": 1,           // integer or string ("0.5", "2.5")
  "name": "Phase Name",  // Human-readable
  "started_at": "ISO-8601"
}
```

### current_step
```json
{
  "number": 3,
  "name": "Step Name",
  "assigned_agent": "conductor-architect",
  "started_at": "ISO-8601",
  "status": "in_progress"  // pending|in_progress|awaiting_input|blocked|completed
}
```

### task_queue item
```json
{
  "step": 4,
  "name": "BRD Extraction",
  "agent": "conductor",
  "status": "pending",     // pending|in_progress|completed|blocked|failed
  "depends_on": [3]        // step numbers
}
```

### completed_tasks item
```json
{
  "step": 1,
  "name": "Requirements Research",
  "agent": "conductor-research",
  "completed_at": "ISO-8601",
  "outcome": "success",   // success|partial|failed|skipped
  "deliverables": ["BRD.md"],
  "duration_minutes": 15
}
```

### checkpoints item
```json
{
  "checkpoint_id": "chk_phase1_complete",  // pattern: chk_[a-zA-Z0-9_]+
  "trigger": "phase_transition",
  "created_at": "ISO-8601",
  "phase": 1,
  "step": 5,
  "git_sha": "abc1234",
  "brd_tracker_hash": "md5_hash",
  "todo_count": 12,
  "complete_count": 0
}
```

### handoff_history item
```json
{
  "handoff_id": "ho_1234567890",  // pattern: ho_[a-zA-Z0-9]+
  "source_agent": "conductor-research",
  "target_agent": "conductor-ciso",
  "initiated_at": "ISO-8601",
  "completed_at": "ISO-8601",
  "status": "completed",  // pending|in_progress|completed|failed|rolled_back
  "checkpoint_id": "chk_pre_ciso",
  "deliverables_expected": ["BRD.md"],
  "deliverables_received": ["BRD.md", "SECURITY.md"]
}
```

### verification_status
```json
{
  "post_ciso": "pass",          // pass|fail|pending|advisory_pass_with_findings|skipped|null
  "post_extraction": null,
  "post_architect": null,
  "post_qa": null,
  "post_implementation": null,
  "post_pentest": null,
  "pre_release": null,
  "advisory_findings": [
    {
      "checkpoint": "post_ciso",
      "findings_count": 3,
      "severity_breakdown": { "critical": 0, "high": 1, "medium": 2, "low": 0 },
      "summary": "Advisory findings from CISO review",
      "timestamp": "ISO-8601"
    }
  ]
}
```
