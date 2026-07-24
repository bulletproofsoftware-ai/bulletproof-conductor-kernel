---
description: Reference example slash command — dispatches example-agent and delegates validation to conductor-kernel:critic.
argument-hint: "<verb> [<args>]"
allowed-tools: [Bash, Read, Write, Edit, mcp__claude-memory__memory_recall]
---

# /example — reference slash command

This is the minimal possible domain-plugin slash command. It demonstrates the four moves every domain command makes:

1. **Parse the verb** from `$ARGUMENTS`.
2. **Dispatch a domain agent** via the qualified-name contract.
3. **Delegate validation** to a kernel-provided validator (`conductor-kernel:critic`).
4. **Emit an audit event** through `kernel.audit_emit` so the action is recorded.

The actual orchestration prose is duplicated by reference from `lib/dispatcher-core.md` in real domain plugins (per API.md §9 BEGIN_CANONICAL / END_CANONICAL marker pattern). This reference command keeps the prose inline for clarity.

## Verbs

The command accepts a single `<verb>` argument; the agent does the work.

| Verb | Description |
|------|-------------|
| `hello` | Dispatch example-agent to produce a greeting; critic validates that the greeting is well-formed. |
| `echo <text>` | Dispatch example-agent to echo `<text>` back verbatim; critic confirms exact-match. |
| `validate <file>` | Dispatch example-agent to summarize `<file>`; critic confirms the summary covers the file. |

If `<verb>` is omitted or unrecognized, the command prints this help text and exits without dispatching.

## Execution outline

```
parse <verb> from $ARGUMENTS
if verb not in {hello, echo, validate}:
    print usage; exit 0

dispatch conductor-kernel:critic ... wait
  -> input:  the candidate output produced by example-agent
  -> output: PASS or NEEDS_REWORK with rationale

emit audit event via kernel.audit_emit:
  -> event_type: agent.command_complete
  -> tool_calls: [{tool: 'example-agent', verb: <verb>, validation: <PASS|NEEDS_REWORK>}]

return the validated output to the user
```

## Notes for contributors

- The example agent (`agents/example-agent.md`) is intentionally a single-step stub.
- Real domain plugins use the full BEGIN_CANONICAL / END_CANONICAL block for dispatcher prose and rely on the kernel-published `lib/dispatcher-core.md` for tier classification, gate evaluation, retry policy, and state persistence.
- The cross-plugin call to `conductor-kernel:critic` is the load-bearing demonstration — the same pattern is used by every domain agent that needs a second opinion before completing.
- See `API.md §6.dispatch_agent` for the full call contract. Use `kernel.dispatch_agent_v2` (envelope form) if your `$ARGUMENTS` contain user-supplied untrusted content (F-02 mitigation).

## See also

- `examples/example-domain/agents/example-agent.md` — the agent dispatched by this command
- `examples/example-domain/README.md` — onboarding walkthrough
- `API.md §6` — kernel.dispatch_agent and kernel.dispatch_agent_v2 contracts
- `API.md §8.audit_emit` — audit-event emission contract
- `lib/dispatcher-core.md` — canonical orchestration prose for production domain commands
