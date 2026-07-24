---
name: conductor-retry-policy
description: |
  Retry, escalation, and circuit breaker policies for conductor orchestration failure handling. Use when a task fails or needs escalation, when determining retry strategy, or when managing circuit breaker state.
---

# Retry Policy

## Quick Reference

| Failure Type | Max Attempts | Backoff | Escalation |
|-------------|-------------|---------|------------|
| Critic rejection (blocking) | 3 | Linear (immediate) | User intervention |
| Agent failure | 2 | Exponential (10s) | Dead letter queue |
| Validation failure | 1 | None | Halt with notification |
| Integration failure | 5 | Exponential (2s) | Circuit breaker |
| Git operation failure | 2 | Linear (5s) | User intervention |
| Default (timeout, transient) | 3 | Exponential (5s) | User notification |

## Retry Decision Matrix

```
deliverable_missing  → agent_failure policy
quality_failure      → critic_rejection policy
timeout              → default policy
error                → default policy
validation_failed    → validation_failure policy (NO retry)
dependency_failed    → agent_failure policy
agent_error          → agent_failure policy
security_violation   → security_issue escalation (IMMEDIATE)
state_corruption     → critical_failure escalation (IMMEDIATE)
git_conflict         → git_operation_failure policy
integration_error    → integration_failure policy
rate_limited         → integration_failure policy
authentication_failed → user_intervention escalation
```

## Escalation Paths

1. **User Intervention**: Notify user with context, wait for decision (retry/skip/abort)
2. **Dead Letter Queue**: Move to `failed_tasks[]` in conductor-state.json, continue workflow
3. **Halt with Notification**: Stop workflow, save state, require explicit resume
4. **Security Issue**: Log event, notify immediately, block resume until review
5. **Critical Failure**: Force checkpoint, generate incident report, halt

## Circuit Breaker

For external integrations (APIs, databases, LLM calls):

| State | Behavior |
|-------|----------|
| **Closed** | Normal operation, requests flow through |
| **Open** | Failing — reject requests immediately |
| **Half-Open** | Testing recovery — allow 1 request |

Default thresholds: 5 failures to open, 300s timeout to half-open.

## Pre-Retry Checklist

Before every retry:
1. Checkpoint current state
2. Calculate backoff delay
3. Check retry budget (attempts remaining)
4. Log retry attempt
5. If `checkpoint_before_retry: true` → restore from checkpoint
6. If retry actions defined → apply remediation for this attempt number

For full policy definitions, see `references/retry-policy.yaml`.
