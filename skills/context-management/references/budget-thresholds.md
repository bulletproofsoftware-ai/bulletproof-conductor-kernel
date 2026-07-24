# Budget Action Matrix

## Token Estimation

| Metric | Multiplier | Capacity |
|--------|-----------|----------|
| Words → Tokens | × 1.3 | ~200,000 tokens |
| Safe threshold | 50% | ~100,000 tokens |
| Danger threshold | 60% | ~120,000 tokens |

## Code Quality vs Context Usage

| Context % | Code Quality | Typical Issue |
|-----------|--------------|---------------|
| 0-25% | World-class | Full attention, comprehensive |
| 25-50% | Good | Minor oversights |
| 50-75% | Degraded | Corner-cutting, "more concise" |
| 75-100% | Poor | Stubs, placeholders, incomplete |

## Action Matrix

| Status | % Range | Spawn Behavior | Context Transfer | Checkpoint |
|--------|---------|---------------|------------------|------------|
| HEALTHY | 0-40% | Standard | Full spec + BRD excerpt + interfaces | Not required |
| MONITOR | 40-50% | Lean | Essential spec sections + BRD ID + minimal signatures | Recommended |
| APPROACHING | 50-60% | Checkpoint-first | Checkpoint summary + current spec only | Mandatory |
| CRITICAL | >60% | NO SPAWN | N/A — full handoff to new session | Mandatory + halt |

## Spec Counter Management

- Counter starts at 0 each planning session
- Increments after each spec is processed
- At counter == 3 OR status APPROACHING:
  1. Reset counter to 0
  2. Generate checkpoint summary
  3. Start fresh planning session with checkpoint as context

## Context Rot Indicators

Watch for these signs that context is degrading:

1. **Instruction fade**: Agent stops following rules from early in the conversation
2. **Contradictions**: Agent gives answers that conflict with earlier statements
3. **Fact amnesia**: Agent forgets established facts about the project
4. **Quality decline**: Code becomes less thorough, more shortcuts
5. **Repetition**: Agent re-asks questions already answered

When any indicator appears, immediately generate handoff and transition to fresh context.
