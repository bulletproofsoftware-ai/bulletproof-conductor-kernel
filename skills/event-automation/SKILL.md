---
name: event-driven-automation
description: >
  Event-driven automation layer that formalizes n8n workflows as a core architectural domain.
  Provides event taxonomy, routing rules, workflow registry, dead letter queue, and workflow
  health monitoring. Referenced by conductor-event-router agent and conductor hooks for
  automated event emission and routing.
---

# Event-Driven Automation Skill

Provides reference data for the event-driven automation layer: event taxonomy, routing rules, workflow registry, and health monitoring configuration.

## When To Use

- When emitting system events from hooks or agents
- When configuring event routing rules for new workflows
- When reviewing workflow health and SLA compliance
- When debugging failed event delivery (dead letter queue)
- When adding new n8n workflows to the registry

## Reference Files

| File | Purpose |
|------|---------|
| `references/event-taxonomy.yaml` | 10 event categories with naming conventions |
| `references/event-routes.yaml` | YAML routing rules mapping events to handlers |
| `references/workflow-registry.yaml` | Catalog of all n8n workflows with metadata |

## Event Flow

```
System Event (hook/agent/cron)
        │
        ▼
┌───────────────┐
│   Validate     │ ← event-taxonomy.yaml
│   Event        │
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Match        │ ← event-routes.yaml
│   Routes       │
└───────┬───────┘
        │
   ┌────┼────┐
   │    │    │
   ▼    ▼    ▼
Webhook State Direct
(n8n)  Update Action
        │
        ▼
   Audit Bus
```

## Key Rules

1. **Fire-and-forget** — emitters never block on event processing
2. **200ms SLA** — router must process events within 200ms
3. **3 retries** on webhook failure, then dead letter queue
4. **Rate limit** — 100 events/second per category to prevent storms
5. **All events audited** — logged to governance audit bus
6. **Fan-out supported** — single event can trigger multiple handlers
