---
name: example-agent
description: Reference example agent showing the minimum-viable structure for a domain-plugin agent that integrates with conductor-kernel.
model: sonnet
allowed-tools: [Read, Write, Edit, Grep, mcp__claude-memory__memory_recall, mcp__claude-memory__memory_store]
color: blue
---

# example-agent — reference domain agent

This is the minimum-viable domain agent. It demonstrates the four properties every domain agent declares:

1. **Frontmatter** — name, description, model, `allowed-tools` (kernel RC-12 requirement per F-21), color.
2. **Intent contract** — what input it accepts, what output it produces, what failure modes it documents.
3. **Cross-plugin dispatch** — how it delegates to a kernel-provided agent for its second-opinion / validation step.
4. **Audit emission** — how its outputs are made discoverable via `kernel.audit_emit`.

## Intent

Given a verb and optional arguments from the `/example` command, produce a small output and return it. The validation step (`conductor-kernel:critic`) decides whether the output meets the verb's contract.

## Verbs

| Verb | Input | Output | Validation predicate |
|------|-------|--------|----------------------|
| `hello` | none | A greeting string (`"Hello from example-agent (kernel: 0.1.0, plugin: example-domain 0.1.0)"`) | output starts with `"Hello "` and mentions the kernel version |
| `echo` | `<text>` | The exact text supplied | output equals input (byte-equal after trim) |
| `validate` | `<file>` | A two-sentence summary of the file's purpose, plus the file's SHA-256 | output cites the file path AND contains a 64-hex-character hash |

## Process

1. **Parse the verb** from the dispatched prompt.
2. **Verify preconditions**:
   - For `echo`, the input string is present and non-empty.
   - For `validate`, the file path exists and is readable.
3. **Execute the verb**:
   - `hello`: emit the greeting string.
   - `echo`: emit the input verbatim.
   - `validate`: read the file, compute SHA-256, write the summary.
4. **Return** the produced output.

## Cross-plugin dispatch (the load-bearing example)

After producing its output, the calling command dispatches `conductor-kernel:critic` with:

- The agent's output
- The verb-specific validation predicate
- The original user-supplied input (for context)

`critic` returns `PASS` or `NEEDS_REWORK` per the kernel critic contract. If `NEEDS_REWORK`, the command re-dispatches example-agent with the critic's feedback appended. After three retries without `PASS`, the command surfaces the failure to the user and emits a `failed_after_retries` audit event.

This delegation pattern is the SAME pattern every production domain agent (for example `conductor-dev:architect`) uses for validation. The example demonstrates it on the smallest possible surface.

## Failure modes

| Mode | Detection | Response |
|------|-----------|----------|
| Unknown verb | At parse time | Return `error: unknown verb <verb>` |
| Missing argument | At precondition check | Return `error: argument required for verb <verb>` |
| File missing (validate) | At precondition check | Return `error: file not found <path>` |
| Critic returns NEEDS_REWORK 3x | After third retry | Emit `failed_after_retries` audit event; surface to user |

## Audit events emitted

The example-agent itself does NOT emit audit events directly. The calling command (`commands/example.md`) emits the post-execution `agent.command_complete` event via `kernel.audit_emit`. The agent's output is included in the event's `detail.response` field.

Per kernel RC-6 / F-04, if the response contains PII / regulated content, the calling command should switch to the `response_ref` form. The reference example uses literal `response` because its inputs are benign by construction.

## See also

- `examples/example-domain/commands/example.md` — the slash command that dispatches this agent
- `examples/example-domain/README.md` — onboarding walkthrough
- `agents/critic.md` — the kernel-provided critic delegated to for validation
- `API.md §6` — dispatch_agent contract
- `API.md §8` — audit_emit contract
