# Installing conductor-kernel

`conductor-kernel` is a Claude Code plugin. It is **not** an npm package, a Python
package, a container image, or a standalone binary — there is nothing to build and
nothing to compile. Installation is registering the plugin with Claude Code.

---

## Prerequisites

| Requirement | Why | Required? |
|---|---|---|
| [Claude Code](https://docs.claude.com/en/docs/claude-code) `>= 1.0.0` | The runtime that loads the plugin, resolves qualified agent names, and runs hooks. | **Yes** |
| `bash` | Verification scripts, hooks, and stream-mode reference scripts are Bash. | **Yes** (present on macOS/Linux by default) |
| [`governance-plugin`](https://github.com/bulletproofsoftware-ai/bulletproof-governance-plugin) `>= 0.1.0` | Provides the append-only audit trail (`state/audit.db`) and human-approval gates that `audit_emit` / `gates_evaluate_and_enforce` write to. | **Optional** — without it, `audit_emit` writes to a local JSONL fallback file instead and the rest of the kernel works unchanged. Note: that repository may not be publicly accessible to every reader; its absence does not block using this kernel. |
| `claude-memory-mcp` (Qdrant-backed, default REST port `6333`) | Only if you use the `memory_recall` / `memory_store` primitives or stream-mode state persistence. | Optional |
| `gemini` CLI on `PATH` | Only if you use the `gemini-validator` agent / `gemini_validate` primitive. | Optional |
| `jq`, `sqlite3` | Convenience utilities used by some scripts and the audit-emission verifier. Operator-provided; not bundled. | Optional |

The kernel ships **zero runtime dependencies** of its own — see
[`SBOM.md`](SBOM.md).

---

## Install

```bash
# 1. Add the marketplace
/plugin marketplace add bulletproofsoftware-ai/bulletproof-conductor-kernel

# 2. Install the kernel from it
/plugin install conductor-kernel@bulletproof-conductor-kernel

# 3. Confirm the plugin is loaded
/plugin list
# Expected line: conductor-kernel  0.1.0  enabled
```

`governance-plugin` is an **optional** dependency — install it separately only if
you want the full audit trail and human-approval gates (see Prerequisites above).
Its repository lives at
[`bulletproofsoftware-ai/bulletproof-governance-plugin`](https://github.com/bulletproofsoftware-ai/bulletproof-governance-plugin)
and may not be publicly accessible to every reader; that does not block using the
kernel. Without it, `audit_emit` writes to a local JSONL fallback file instead of
a database.

The example domain plugin bundled at `examples/example-domain/` requires no
separate install step — it ships inside this repository and is described in
[`examples/example-domain/README.md`](../examples/example-domain/README.md).

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

### 3. The audit trail is reachable and hardened, if governance-plugin is installed (RC-5)

```bash
bash scripts/verify-audit-emission.sh
# If governance-plugin is installed: confirms audit.db exists and is mode 0600
#   (exit 0 = PASS, exit 1 = present but misconfigured, exit 3 = advisory PASS).
# If governance-plugin is NOT installed: exit 77 (SKIP). This is a PASS-equivalent,
#   supported configuration — audit emission falls back to a local JSONL file.
```

### 4. Cross-plugin dispatch works (REQ-KER-005)

```bash
bash scripts/verify-cross-plugin-dispatch.sh
# Creates a tiny sibling plugin, dispatches conductor-kernel:critic,
# and asserts the output structure + an agent.dispatch audit row.
# Expected: PASS.
```

### 5. End-to-end smoke test via the reference example

If you installed `examples/example-domain` (see [its README](../examples/example-domain/README.md)):

```
/example hello
```

Expected: a validated greeting from `example-agent` and a `PASS` from
`conductor-kernel:critic`. If governance-plugin is installed, a corresponding
`agent.dispatch` row also lands in its audit database; if not, the same event is
appended to the local JSONL fallback file instead. Either way, if that round-trip
works, your kernel is wired correctly.

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
workflow-state files you created, the local audit fallback JSONL, or (if
governance-plugin is installed) any audit rows it holds — those are owned by
their respective locations and are removed separately if desired.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| A domain command errors with "conductor-kernel not installed" | Kernel not registered in this session | Run `/plugin marketplace add bulletproofsoftware-ai/bulletproof-conductor-kernel` then `/plugin install conductor-kernel@bulletproof-conductor-kernel`, then re-run `/plugin list`. |
| `verify-audit-emission.sh` exits 77 | `governance-plugin` not installed | Expected — this is a supported configuration, not a failure. Audit emission is using the local JSONL fallback. Install governance-plugin only if you want the full database-backed trail. |
| `verify-audit-emission.sh` exits 1 | Audit DB present but wrong file mode or unreadable | `chmod 600` the resolved DB path, or check `$AUDIT_DB_OVERRIDE` / `$GOVERNANCE_PLUGIN_ROOT`. |
| `gemini-validator` fails with "gemini CLI not on PATH" (`KER-GV-001`) | `gemini` CLI not installed | Install the `gemini` CLI, or use `conductor-kernel:critic` for validation instead. |
| Stream-mode primitives return "not implemented"-style errors | Stream-mode is experimental at v0.1.0 | See [`../API.md §5`](../API.md); use workflow mode for bounded tasks. |

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
