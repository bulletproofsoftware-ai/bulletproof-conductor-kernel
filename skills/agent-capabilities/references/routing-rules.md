# Agent Routing Decision Rules

## Decision Algorithm

When the conductor needs to assign a task:

```
1. Identify task type from context
2. Look up matching agents in capability matrix
3. Check if matched agent is bundled (conductor-*) or external
4. If external: check availability, fall back gracefully if missing
5. Validate all required inputs are available
6. Validate agent is appropriate for current phase
7. Assign and record in conductor-state.json
```

## Phase-to-Agent Mapping

| Phase | Primary Agents | Optional Agents |
|-------|---------------|-----------------|
| 0: Init | conductor-project-setup | - |
| 0.5: Brownfield | - | analyze-codebase |
| 1: Requirements | conductor-research, conductor-ciso, conductor-critic | - |
| 2: Architecture | conductor-architect, conductor-qa, conductor-critic | api-design, database |
| 2.5: Visual | - | frontend-designer |
| 3: Implementation | conductor-builder, conductor-ciso, conductor-code-reviewer, conductor-qa, conductor-critic | performance, compliance, bug-find, refactor |
| 4: Verification | conductor-qa, conductor-critic | pentest-coordinator |
| 5: Documentation | conductor-doc-gen | api-docs |
| 6: Deployment | - | devops, observability |
| 7: Completeness Validation | conductor-completeness-validator | - |

## Builder Mode Selection

The conductor-builder agent operates in three modes:

| Mode | When | Tier |
|------|------|------|
| `plan-and-implement` | Simple tasks, single spec | TRIVIAL, MINOR |
| `plan-only` | Complex specs needing review | STANDARD, MAJOR |
| `implement-only` | After plan approved | STANDARD, MAJOR |

## CISO Review Types

| Review Type | Trigger | Agent Receives |
|-------------|---------|----------------|
| `requirements` | After research, Phase 1 | BRD document |
| `code-review` | After builder, Phase 3 | Generated code files |
| `doc-review` | After doc-gen, Phase 5 | Documentation |

## Critic Mode Selection

| Tier | Default Mode | Exception |
|------|-------------|-----------|
| TRIVIAL | skip | None |
| MINOR | advisory | None |
| STANDARD | advisory | PRE-RELEASE and POST-PENTEST are BLOCKING |
| MAJOR | blocking | None |

## Graceful Degradation for External Agents

When an external agent is not available:

1. Log in conductor-state.json: `{ "skipped_step": { "agent": "performance", "reason": "agent_not_available" } }`
2. Notify user with specific message
3. Continue workflow — do NOT block
4. Mark the corresponding verification as "skipped" (not "pass")
