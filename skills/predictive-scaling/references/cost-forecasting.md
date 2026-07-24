# Cost Forecasting Methodology

## Algorithm

Cost forecasting projects total expenditure for active projects using:

### 1. Completed Work Cost (Actual)
From Agent Economics token tracking:
```
actual_cost = sum(dispatches[].cost_usd) where status == completed
```

### 2. Remaining Work Estimate
From conductor state — count remaining phases and tasks:
```
remaining_tasks = count(task_queue where status in [pending, blocked])
completed_tasks = count(completed_tasks)
completion_ratio = completed_tasks / (completed_tasks + remaining_tasks)
```

### 3. Per-Task Cost Model
Historical average cost by task type and tier:
```
avg_cost_per_task[tier] = historical_mean(cost_usd where tier == T)
remaining_cost = sum(remaining_tasks[tier] * avg_cost_per_task[tier])
```

### 4. Confidence Interval
80% confidence interval from variance in historical costs:
```
std_dev = historical_stddev(cost_usd where tier == T)
ci_low = remaining_cost - 1.28 * std_dev * sqrt(remaining_tasks)
ci_high = remaining_cost + 1.28 * std_dev * sqrt(remaining_tasks)
```

Note: Formula assumes independent task costs. For correlated tasks (same feature), CI may be too narrow. Guard: when remaining_tasks == 0, CI width is 0.

### 5. Status Determination
```
IF projected_total <= budget * 0.90: status = "on_track"
ELIF projected_total <= budget: status = "at_risk"
ELSE: status = "over_budget"
```

## Historical Cost Baselines (Default)

| Tier | Avg Cost/Task | Std Dev | Typical Tasks |
|------|-------------|---------|---------------|
| TRIVIAL | $0.15 | $0.08 | 1-2 |
| MINOR | $0.80 | $0.40 | 3-5 |
| STANDARD | $4.50 | $2.50 | 8-15 |
| MAJOR | $25.00 | $12.00 | 15-30 |

These baselines are updated as the system accumulates more data.

## Recalculation Triggers

- After every completed task
- After model tier changes
- After budget modifications
- On operator request

## Budget Trajectory Alerts

| Condition | Alert |
|-----------|-------|
| spent > 50% AND remaining > 60% | "Budget at risk — consider model downgrade" |
| spent > 70% AND remaining > 40% | "Budget critical — downgrading non-essential" |
| spent > 90% | "Budget nearly exhausted — operator intervention needed" |
| projected_total > budget | "Over budget projection — ${amount} over" |
