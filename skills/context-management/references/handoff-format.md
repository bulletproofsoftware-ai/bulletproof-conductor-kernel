# Handoff Document Template

## Full Handoff (CRITICAL budget)

```markdown
## CONTEXT HANDOFF — FULL

**Generated**: [ISO-8601 timestamp]
**Context Usage**: [X]% (CRITICAL threshold exceeded)
**Project**: [project_name]
**Session**: [session number]

---

### 1. PROJECT OVERVIEW
- **Description**: [1-2 sentence project summary]
- **Tier**: [TRIVIAL|MINOR|STANDARD|MAJOR]
- **Workflow Type**: [new|existing|ui-heavy|brd-provided]
- **BRD Source**: [path to BRD]

### 2. ACCOMPLISHMENTS THIS SESSION
- [Completed task 1 — agent: X, deliverable: Y]
- [Completed task 2 — agent: X, deliverable: Y]

### 3. KEY DECISIONS MADE
| # | Decision | Rationale | Reversible? |
|---|----------|-----------|-------------|
| 1 | [Decision] | [Why] | [Yes/No] |
| 2 | [Decision] | [Why] | [Yes/No] |

### 4. CURRENT POSITION
- **Phase**: [N] — [Phase Name]
- **Step**: [N] — [Step Name]
- **Assigned Agent**: [agent_name]
- **Step Status**: [pending|in_progress|blocked]

### 5. BRD PROGRESS
- **Requirements**: [X/Y] at status "[latest_status]"
- **Integrations**: [X/Y] complete, [Z] placeholder
- **Verification Gates**:
  - extraction_complete: [true/false]
  - specs_complete: [true/false]
  - implementation_complete: [true/false]

### 6. FILES TO REFERENCE
- `conductor-state.json` — Full workflow state
- `BRD-tracker.json` — Requirement tracking
- `claude_progress.txt` — Progress notes
- [Any other key files]

### 7. WHAT THE NEXT SESSION NEEDS
- [Specific action to take first]
- [Key constraint or rule to follow]
- [Potential blocker to watch for]

### 8. CONTINUATION PROMPT
Copy this to start the next session:

> Continue project [name] from Phase [N], Step [X].
> Read conductor-state.json for full state.
> Next action: [specific task].
```

## Phase Boundary Handoff (APPROACHING budget)

Uses the Phase Checkpoint Format from the SKILL.md — shorter, focused on phase transition rather than full project context.

## Lean Handoff (MONITOR budget)

```markdown
## LEAN HANDOFF

**Phase**: [N], **Step**: [X]
**BRD Progress**: [X/Y]
**Next Action**: [specific task]
**Key Files**: conductor-state.json, BRD-tracker.json
```
