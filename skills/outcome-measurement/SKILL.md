---
name: outcome-measurement
description: >
  Outcome measurement system tracking value delivered by conductor orchestration. Defines
  8 metrics, value attribution framework, regression alerting, and report templates.
  Passive observation of existing signals — no agent instrumentation required.
---

# Outcome Measurement Skill

Provides reference data for measuring outcomes and attributing value. The conductor-outcome-collector agent uses these definitions.

## When To Use

- After workflow completion to generate outcome reports
- When checking quality trends over time
- When preparing value attribution for stakeholders
- When configuring baselines for new projects
- When investigating regression in agent performance

## Reference Files

| File | Purpose |
|------|---------|
| `references/metrics-definitions.yaml` | 8 metric definitions with sources and calculation |
| `references/value-attribution.yaml` | Value framework with configurable baselines |
| `references/outcome-reports.md` | Report templates for weekly digest and retrospective |

## Key Rules

1. **Passive only** — no agent modification for outcome tracking
2. **Baselines required** — value attribution needs operator-defined baselines
3. **90-day granular** — older data aggregated, not deleted
4. **Regression at 15%** — alert when any metric degrades 15%+ from rolling average
5. **No fabrication** — every value number must trace to a defined baseline
