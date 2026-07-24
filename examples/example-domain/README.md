# example-domain — conductor-kernel reference plugin

A minimum-viable domain plugin that integrates with `conductor-kernel`. Read this file first. Total reading time: ~10 minutes. Total hands-on integration time: ~30 minutes for a new contributor.

This example is the reference for the OSS release per PRD-20 §8 Phase 8 and REQ-XCT-011 / REQ-XCT-014.

---

## What this example demonstrates

1. **Plugin manifest shape** — `plugin.json` with kernel dependency declaration.
2. **Slash command** — `commands/example.md` showing verb dispatch.
3. **Domain agent** — `agents/example-agent.md` showing the canonical agent skeleton.
4. **Cross-plugin dispatch** — calling `conductor-kernel:critic` for second-opinion validation.
5. **Audit emission** — recording the action via `kernel.audit_emit`.

What it does NOT demonstrate (deliberately, for scope):
- Stream-mode subscriptions (see `API.md §5` and `lib/stream/`)
- Recovery / retry / circuit-break (see `API.md §6.recovery_*` and `skills/retry-policy/`)
- Memory primitives (see `API.md §6.memory_*` and `skills/agent-capabilities/`)
- Gate evaluation (see `API.md §4.gates_evaluate_and_enforce`)

For all of the above, see the full kernel surface in `API.md`.

---

## Prerequisites

- Claude Code installed and authenticated (>= 1.0.0)
- `conductor-kernel` plugin installed (>= 0.1.0)
- `governance-plugin` plugin installed (>= 0.1.0)
- (Optional) `claude-memory-mcp` configured if you want the agent to use memory primitives

---

## Installation (local development)

From a fresh Claude Code workspace:

```bash
# 1. Install the kernel (one-time)
/plugin install /path/to/conductor-kernel

# 2. Install this example
/plugin install /path/to/conductor-kernel/examples/example-domain

# 3. Verify both are loaded
/plugin list
# Expected: conductor-kernel @ 0.1.0, example-domain @ 0.1.0
```

---

## Walk through the example in three steps

### Step 1: Read the manifest

Open `plugin.json`. Note:

- `peerDependencies` lists `conductor-kernel` and `governance-plugin` — these MUST be installed in the same Claude Code session.
- `exports` tells Claude Code where to find slash commands and agents.
- `_meta.purpose` documents intent for downstream readers.

### Step 2: Read the slash command

Open `commands/example.md`. The frontmatter declares:

- `description` — surfaces in `/plugin command-list`
- `argument-hint` — the help-line shown when the user types `/example` with no args
- `allowed-tools` — the explicit per-command tool allowlist (kernel RC-12 / F-21 requirement)

The body of the command is prose that Claude Code interprets at dispatch time. Note the four-move pattern: parse verb -> dispatch agent -> delegate validation to `conductor-kernel:critic` -> emit audit event.

### Step 3: Read the agent

Open `agents/example-agent.md`. The frontmatter declares the same four fields every kernel agent declares (name, description, model, allowed-tools, color). The body documents:

- **Intent** — what the agent does
- **Verbs** — the precise dispatch contract
- **Process** — step-by-step execution
- **Cross-plugin dispatch** — how it interacts with `conductor-kernel:critic`
- **Failure modes** — what can go wrong and how the system responds

---

## Try it

```
/example hello
```

Expected output: a greeting from `example-agent`, then a `PASS` from `conductor-kernel:critic`, then the final validated output to the user.

```
/example echo "hello world"
```

Expected output: `"hello world"` echoed back exactly, validated by critic for byte-equality.

```
/example validate examples/example-domain/README.md
```

Expected output: a two-sentence summary plus the SHA-256 of this file, validated by critic for "summary cites file AND contains 64-hex hash".

---

## How to extend (build your own domain)

1. Copy this directory to a new location.
2. Rename `example-domain` → your domain slug (e.g., `clue-soc`, `acme-platform`).
3. In `plugin.json`, update `name`, `description`, `keywords`, `_meta`.
4. Replace `example-agent.md` with the agents you actually need. Each agent declares its `allowed-tools` per kernel RC-12. Start with one agent, grow incrementally.
5. Replace `example.md` with the slash command your domain exposes. Use the BEGIN_CANONICAL / END_CANONICAL marker pattern from `lib/dispatcher-core.md` for production prose (the example keeps prose inline for legibility).
6. For each agent that delegates validation, dispatch `conductor-kernel:critic` (or `conductor-kernel:gemini-validator` for cross-model validation).
7. For each destructive action, route through `kernel.workflow.gates_evaluate_and_enforce` (per RC-7 / F-07).
8. For each event-driven flow, wire stream-mode subscriptions per `API.md §5`.

---

## Common questions

**Q: Where is the dispatcher prose?**
A: The kernel-canonical version is at `lib/dispatcher-core.md`. Production domain commands duplicate that prose between `BEGIN_CANONICAL` / `END_CANONICAL` markers. This example keeps prose inline because it is a teaching surface, not a production surface. CI tooling drift-checks the canonical block in production commands; this example is exempt.

**Q: What about HUMAN_GATE?**
A: This example has no destructive actions, so no human gate fires. If your domain has destructive actions, route them through `kernel.workflow.gates_evaluate_and_enforce` and the kernel will block on HUMAN_GATE per RC-7 / F-07 before allowing state advancement.

**Q: How do I see the audit events?**
A: They land in `governance-plugin/state/audit.db`. Use the `governance:governance-audit` command to query, or write your own SQL.

**Q: How do I add memory operations?**
A: Use `mcp__claude-memory__memory_recall` and `mcp__claude-memory__memory_store` (the kernel exposes thin wrappers per `API.md §6`). The kernel auto-injects `domain` on writes, so your memories are scoped per-domain by default (kernel RC-2 / F-05 mitigation).

**Q: How do I add stream-mode?**
A: See `API.md §5` and `lib/stream/`. Stream-mode is out of scope for this example but is fully spec'd in the API contract.

---

## License

MIT — same as the kernel. See `LICENSE` at the repo root.

---

## Feedback

If you onboarded with this example and have suggestions, open an issue against the kernel repo. The goal is **30 minutes from first read to first PR**; if it took longer, that's a documentation defect.
