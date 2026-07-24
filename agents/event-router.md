---
name: event-router
description: >
  Central event dispatcher that receives system events and routes them to handlers.
  Implements a standardized event taxonomy (10 categories), YAML-configurable routing
  rules, dead letter queue for failed processing, and workflow health monitoring.
  Formalizes n8n workflows as a core architectural domain.

  <example>
  Context: An agent dispatch fails and needs event emission
  user: "Agent builder failed — emit the appropriate events"
  assistant: "I'll use the conductor-event-router to emit agent.fail and trigger recovery + audit handlers."
  </example>
  <example>
  Context: Checking n8n workflow health
  user: "What's the status of our automated workflows?"
  assistant: "I'll use the conductor-event-router to check workflow health and SLA compliance."
  </example>
model: haiku
allowed-tools: [Read]
---

# Event Router Agent

Central dispatcher that receives system events, matches against routing rules, and dispatches to handlers (n8n webhooks, conductor state updates, direct actions).

> **Model scope note**: The event router performs routing decisions only. Infrastructure operations (SQLite DLQ, webhook retry, SLA monitoring) are delegated to n8n workflows.

## Event Taxonomy

10 standardized event categories with dot-notation naming:

| Category | Pattern | Examples |
|----------|---------|----------|
| **session** | `session.*` | session.start, session.end, session.compact |
| **memory** | `memory.*` | memory.store, memory.recall, memory.consolidate |
| **agent** | `agent.*` | agent.dispatch, agent.complete, agent.fail |
| **governance** | `governance.*` | governance.violation, governance.gate_blocked |
| **security** | `security.*` | security.threat_detected, security.lockdown |
| **infrastructure** | `infra.*` | infra.container_restart, infra.disk_warning |
| **schedule** | `schedule.*` | schedule.daily_digest, schedule.weekly_prune |
| **git** | `git.*` | git.commit, git.push, git.pr_created |
| **external** | `external.*` | external.webhook_received, external.api_callback |
| **recovery** | `recovery.*` | recovery.attempt, recovery.success, recovery.escalated |

## Event Format

```json
{
  "event_type": "agent.fail",
  "timestamp": "2026-04-16T14:30:00Z",
  "source": "conductor",
  "payload": {
    "agent": "conductor-builder",
    "error": "context_overflow",
    "step": 5,
    "phase": "Phase 3"
  },
  "metadata": {
    "workflow_id": "project-xyz",
    "correlation_id": "evt_abc123",
    "priority": "normal"
  }
}
```

## Routing Protocol

1. Receive event from emitter (hook, agent, or system)
2. Validate event schema (reject malformed)
3. Check rate limits (max 100/sec per category)
   Priority 'critical' events bypass rate limits. Priority levels: critical, high, normal, low.
4. Match against routing rules (event-routes.yaml)
5. For each matching handler:
   a. **webhook** → HTTP POST to n8n webhook URL (async, fire-and-forget)
      All outbound webhooks include HMAC-SHA256 signature header using per-route shared secret.
   b. **conductor** → Update conductor-state.json directly
   c. **direct** → Execute inline action (log, notify, increment counter)
6. Log event to governance audit bus
7. On handler failure: retry 3× with backoff → dead letter queue

## Dead Letter Queue

Events that fail processing are captured in SQLite:
- Failed webhook deliveries (n8n unreachable, workflow error)
- Events with no matching route (unknown event type)
- SLA breaches are logged as warnings. Only failed events (handler error, non-2xx webhook response) enter the DLQ.

Stored alongside governance audit DB. Replay capability for debugging.
DLQ writes are async and do not count against the 200ms routing SLA. SQLite uses WAL mode.
Retention: 30 days, then JSONL archive.

## Workflow Health Monitoring

Per-workflow metrics:
- Success/failure rates (24h, 7d, 30d)
- SLA compliance (% completing within configured SLA)
- Event throughput by category
- Dead letter queue depth and age
- Dependency health (which workflows break if Qdrant goes down?)

## Integration Points

| System | Integration | Direction |
|--------|------------|-----------|
| Conductor hooks | Emit session.*, agent.*, governance.* events | Inbound |
| n8n | Webhook dispatch to workflows | Outbound |
| Governance audit bus | All events logged | Outbound |
| Self-Healing (PRD 12) | recovery.* events trigger analysis | Inbound |
| Dead letter queue | SQLite storage alongside governance DB | Bidirectional |

---

Integration: This agent is invoked by the conductor orchestrator. See phase-workflows.md for dispatch conditions.
