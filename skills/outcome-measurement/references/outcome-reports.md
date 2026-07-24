# Outcome Report Templates

## Weekly Digest Template

```markdown
# Outcome Digest — Week of {date}

## Key Metrics
| Metric | This Week | Last Week | Trend |
|--------|-----------|-----------|-------|
| Completion Rate | {rate}% | {prev}% | {arrow} |
| Avg TTR | {ttr} min | {prev_ttr} min | {arrow} |
| First-Pass Rate | {fpr}% | {prev_fpr}% | {arrow} |
| Cost/Outcome | ${cpo} | ${prev_cpo} | {arrow} |
| Recovery Rate | {rr}% | {prev_rr}% | {arrow} |

## Notable Outcomes
- {list of significant completions or milestones}

## Regressions
- {any metrics that degraded >15% from rolling average}

## Agent Performance
| Agent | Tasks | Success Rate | Avg TTR |
|-------|-------|-------------|---------|
| {agent} | {n} | {rate}% | {ttr} min |
```

## Project Retrospective Template

```markdown
# Project Retrospective — {project_name}

## Summary
- **Duration**: {start_date} to {end_date} ({days} days)
- **Tier**: {tier}
- **Total Tasks**: {total} (✓ {success} | ✗ {failed} | ⊘ {abandoned})
- **Total Cost**: ${cost}
- **Cost Per Outcome**: ${cpo}

## Outcome Metrics
| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|
| Completion Rate | {rate}% | ≥85% | {status} |
| Avg TTR | {ttr} min | varies by tier | {status} |
| First-Pass Rate | {fpr}% | ≥80% | {status} |
| Rework Cycles | {rework} avg | <1.0 | {status} |
| Recovery Rate | {rr}% | ≥70% | {status} |

## Value Attribution
| Category | Value | Notes |
|----------|-------|-------|
| Time Saved | ${time_value} | {hours} hours × ${hourly_rate}/hr |
| Quality Improvement | ${quality_value} | {error_reduction}% error reduction |
| Throughput | ${throughput_value} | {tasks} tasks automated |
| Risk Avoidance | ${risk_value} | {findings} critical findings caught |
| **Total Value** | **${total_value}** | |
| **Total Cost** | **${total_cost}** | |
| **Net ROI** | **{roi}x** | |

## Agent Breakdown
| Agent | Dispatches | Success | Avg TTR | Cost |
|-------|-----------|---------|---------|------|
| {agent} | {n} | {rate}% | {ttr} min | ${cost} |

## Quality Trend
{chart or table showing weekly quality scores over project duration}

## Lessons Learned
- {auto-generated from recovery events, rework patterns, and regression alerts}
```
