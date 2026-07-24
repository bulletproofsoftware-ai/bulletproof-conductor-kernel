# SSE Event Types and Payloads

## Event Format

```
event: [event_type]
data: [JSON payload]
```

## Event Types

### `state:updated`
Fired when conductor-state.json changes. Contains the full state diff.

```json
{
  "event": "state:updated",
  "timestamp": "ISO-8601",
  "changes": {
    "current_phase": { "old": { "number": 1 }, "new": { "number": 2 } },
    "current_step": { "old": { "number": 5 }, "new": { "number": 6 } }
  }
}
```

### `phase:transition`
Fired when a phase boundary is crossed.

```json
{
  "event": "phase:transition",
  "timestamp": "ISO-8601",
  "from_phase": { "number": 1, "name": "Requirements" },
  "to_phase": { "number": 2, "name": "Architecture" }
}
```

### `task:completed`
Fired when a task moves to completed_tasks.

```json
{
  "event": "task:completed",
  "timestamp": "ISO-8601",
  "task": {
    "step": 3,
    "name": "CISO Review",
    "agent": "conductor-ciso",
    "outcome": "success",
    "deliverables": ["SECURITY.md"]
  }
}
```

### `gate:result`
Fired when a verification gate produces a result.

```json
{
  "event": "gate:result",
  "timestamp": "ISO-8601",
  "gate": "post_ciso",
  "mode": "advisory",
  "result": "advisory_pass_with_findings",
  "findings_count": 2
}
```

### `agent:invoked`
Fired when an agent is dispatched.

```json
{
  "event": "agent:invoked",
  "timestamp": "ISO-8601",
  "agent": "conductor-architect",
  "task": "Create feature specifications",
  "step": 7
}
```

### `error:occurred`
Fired when a task fails or error is logged.

```json
{
  "event": "error:occurred",
  "timestamp": "ISO-8601",
  "step": 11,
  "agent": "conductor-builder",
  "failure_type": "quality_failure",
  "details": "Placeholder implementation detected"
}
```

### `brd:progress`
Fired when BRD-tracker.json changes.

```json
{
  "event": "brd:progress",
  "timestamp": "ISO-8601",
  "total_requirements": 20,
  "status_breakdown": {
    "extracted": 0,
    "spec_created": 5,
    "implementing": 3,
    "implemented": 7,
    "tested": 3,
    "complete": 2
  },
  "integrations_complete": 3,
  "integrations_total": 5,
  "placeholders_remaining": 1
}
```
