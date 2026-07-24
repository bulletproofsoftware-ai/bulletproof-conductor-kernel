---
name: self-healing-workflows
description: >
  Self-healing workflow recovery system for conductor orchestration. Provides failure
  classification taxonomy, recovery playbook strategies, checkpoint management extensions,
  health monitoring configuration, and MTTR tracking. Referenced by conductor-recovery-engine
  agent for automated failure recovery.
---

# Self-Healing Workflows Skill

Provides the reference data and recovery logic that the `conductor-recovery-engine` agent uses to classify failures and execute automated recovery strategies.

## When To Use

- When an agent dispatch fails and needs automated recovery
- When configuring recovery strategies for a project
- When reviewing failure patterns and MTTR metrics
- When the health monitor detects infrastructure degradation

## Reference Files

| File | Purpose |
|------|---------|
| `references/recovery-playbook.yaml` | Recovery strategies per failure category and tier |
| `references/failure-taxonomy.yaml` | Failure classification patterns and signals |
| `references/health-checks.yaml` | Infrastructure health monitoring configuration |

## Recovery Flow

```
Agent Dispatch Failure
        │
        ▼
┌───────────────┐
│   Classify     │ ← failure-taxonomy.yaml
│   Failure      │
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Select       │ ← recovery-playbook.yaml
│   Strategy     │
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Execute      │
│   Recovery     │
└───────┬───────┘
        │
   ┌────┴────┐
   │         │
Success   Failure
   │         │
Resume    Next Strategy
   │      or Escalate
   ▼         ▼
```

## Key Rules

1. **Fail open** — recovery engine failure must never mask the original error
2. **Max 3 attempts** per strategy per step before escalation
3. **Checkpoint before recovery** — always validate checkpoint integrity first
4. **Audit everything** — every recovery attempt recorded with full context
5. **MTTR tracking** — running averages per failure category for trending
6. **Health is advisory** — pre-emptive signals influence strategy but never block
