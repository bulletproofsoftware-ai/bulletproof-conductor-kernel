# Installing conductor-kernel

`conductor-kernel` is a Claude Code plugin. It is **not** an npm package, a Python
package, a container image, or a standalone binary — there is nothing to build and
nothing to compile. Installation is registering the plugin with Claude Code.

---

## Prerequisites

| Requirement | Why | Required? |
|---|---|---|
| [Claude Code](https://docs.claude.com/en/docs/claude-code) `>= 1.0.0` | The runtime that loads the plugin, resolves qualified agent names, and runs hooks. | **Yes** |
| `governance-plugin` `>= 0.1.0` | Provides the append-only audit trail (`state/audit.db`) and human-approval gates that the kernel's `audit_emit` and `gates_evaluate_and_enforce` primitives write to. | **Yes** (for audit + gates) |
| `bash` | Verification scripts, hooks, and stream-mode reference scripts are Bash. | **Yes** (present on macOS/Linux by default) |
| `claude-memory-mcp` (Qdrant-backed) | Only if you use the `memory_recall` / `memory_store` primitives or stream-mode state persistence. | Optional |
| `gemini` CLI on `PATH` | Only if you use the `gemini-validator` agent / `gemini_validate` primitive. | Optional |
| `jq`, `sqlite3` | Convenience utilities used by some scripts and the audit-emission verifier. Operator-provided; not bundled. | Optional |

The kernel ships **zero runtime dependencies** of its own — see
[`SBOM.md`](SBOM.md).

---

## Install (local development)

```bash
# 1. Install the kernel
/plugin install /path/to/bulletproof-conductor-kernel

# 2. Install governance-plugin (required for the audit trail + gates)
/plugin install /path/to/governance-plugin

# 3. (Optional) Install the reference example domain plugin
/plugin install /path/to/bulletproof-conductor-kernel/examples/example-domain

# 4. Confirm the plugin is loaded
/plugin list
# Expected line: conductor-kernel  0.1.0  enabled
```

## Install (from marketplace, once published)

```bash
/plugin marketplace install conductor-kernel
```

---

## Verify the installation

The kernel exports **no slash command**, so you verify it indirectly — by
confirming it loads, that its agents resolve, and that its verification scripts
pass.

### 1. Plugin is loaded

```bash
/plugin list | grep conductor-kernel
# Expected: conductor-kernel  0.1.0  enabled
```

### 2. Every agent declares a tool allowlist (RC-12)

```bash
bash scripts/verify-agent-tools.sh
# Expected: PASS: all 19 kernel agents declare allowed-tools
```

### 3. The audit trail is reachable and hardened (RC-5)

```bash
bash scripts/verify-audit-emission.sh
# Confirms governance-plugin/state/audit.db exists and is mode 0600.
# Expected: exit 0 with a PASS message.
```

### 4. Cross-plugin dispatch works (REQ-KER-005)

```bash
bash scripts/verify-cross-plugin-dispatch.sh
# Creates a tiny sibling plugin, dispatches conductor-kernel:critic,
# and asserts the output structure + an agent.dispatch audit row.
# Expected: PASS.
```

### 5. End-to-end smoke test via the reference example

If you installed `examples/example-domain`:

```
/example hello
```

Expected: a validated greeting from `example-agent`, a `PASS` from
`conductor-kernel:critic`, and a corresponding `agent.dispatch` row in
`governance-plugin/state/audit.db`. If that round-trip works, your kernel is wired
correctly.

---

## What gets installed

Registering the plugin makes the following available to any sibling plugin in the
same Claude Code session:

- **19 agents** addressable as `conductor-kernel:<name>` via the Task tool's
  qualified `subagent_type`.
- **14 skills** addressable as `conductor-kernel:<name>`.
- **State schemas** under `schemas/` for domain plugins to extend.
- **Hooks** (`hooks/hooks.json`): a `SessionStart` health check and a `PostToolUse`
  state-write schema validator.

No files are written outside the plugin directory at install time. Runtime state
(workflow-state JSON files, audit rows) is written by the primitives when a domain
plugin invokes them — see [`ADMINISTRATOR.md`](ADMINISTRATOR.md).

---

## Uninstall

```bash
/plugin uninstall conductor-kernel
```

Uninstalling removes the plugin registration. It does **not** delete any
workflow-state files you created or any audit rows in `governance-plugin` — those
are owned by their respective locations and are removed separately if desired.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| A domain command errors with "conductor-kernel not installed" | Kernel not registered in this session | Run `/plugin install ...` then re-run `/plugin list`. |
| `verify-audit-emission.sh` reports the DB missing | `governance-plugin` not installed, or installed at a non-default path | Install `governance-plugin`; confirm `state/audit.db` path. |
| `gemini-validator` fails with "gemini CLI not on PATH" (`KER-GV-001`) | `gemini` CLI not installed | Install the `gemini` CLI, or use `conductor-kernel:critic` for validation instead. |
| Stream-mode primitives return "not implemented"-style errors | Stream-mode is experimental at v0.1.0 | See [`../API.md §5`](../API.md); use workflow mode for bounded tasks. |

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
