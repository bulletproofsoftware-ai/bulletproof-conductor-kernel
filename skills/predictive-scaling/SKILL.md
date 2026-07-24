---
name: predictive-scaling
description: >
  Predictive scaling engine for workload anticipation, model routing optimization,
  cache pre-warming, and cost forecasting. Statistical analysis of historical patterns
  to optimize resource allocation proactively. All predictions advisory.
---

# Predictive Scaling Skill

Provides reference data for the conductor-prediction-engine agent: workload profile templates, model routing matrix, cache warming configuration, and cost forecasting parameters.

## When To Use

- At session start to predict workload and set default model tier
- After every 3 tasks to update session prediction
- When checking cost trajectory for active projects
- When configuring cache pre-warming schedules
- When recommending parallel agent counts

## Reference Files

| File | Purpose |
|------|---------|
| `references/workload-profiles.yaml` | Profile templates and historical patterns |
| `references/model-routing-matrix.yaml` | Adaptive routing decision matrix |
| `references/cache-warming-config.yaml` | Cache pre-warming configuration |
| `references/cost-forecasting.md` | Forecasting methodology and examples |

## Key Rules

1. **Advisory only** — predictions influence defaults, never override operator
2. **Statistical, not ML** — rolling averages and frequency distributions
3. **3-task prediction** — session complexity predicted from first 3 tasks
4. **Daily updates** — workload profiles refreshed daily via n8n
5. **Sub-500ms** — prediction latency must stay under 500ms
6. **Logged** — all prediction decisions recorded for accuracy tracking
