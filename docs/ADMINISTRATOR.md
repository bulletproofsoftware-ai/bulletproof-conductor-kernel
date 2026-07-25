# conductor-kernel — Administrator Guide

This guide covers operating and hardening the kernel: the agent/tool surface, the
hooks, the audit trail, verification scripts, and the deployment preconditions an
operator is responsible for. For the security threat model see
[`../SECURITY.md`](../SECURITY.md) and
the SECURITY.md.

---

## Agent & tool surface (RC-12 / F-15)

Every one of the 19 kernel agents declares an explicit, minimal `allowed-tools`
frontmatter. `Task` is **not** in any kernel agent's allowlist — kernel agents do
not dispatch other agents; only domain-plugin commands do. Widening an agent's
allowlist beyond the table below is a contract violation caught by
`scripts/verify-agent-tools.sh`.

| Agent | Model | allowed-tools |
|---|---|---|
| `critic` | opus[1m] | Read, Grep |
| `gemini-validator` | sonnet | Read, Bash |
| `completeness-validator` | opus[1m] | Read, Grep, Glob |
| `checkpoint` | haiku | Read, Write, Edit |
| `event-router` | haiku | Read |
| `outcome-collector` | haiku | Read |
| `retrospective` | sonnet | Read, Write |
| `prediction-engine` | haiku | Read |
| `research` | opus[1m] | Read, WebFetch, WebSearch |
| `ciso` | opus[1m] | Read, Grep, Glob |
| `llm-security` | sonnet | Read, Grep |
| `pentest-coordinator` | opus[1m] | Read, Bash |
| `secrets-lifecycle` | sonnet | Read, Bash |
| `supply-chain-security` | sonnet | Read, Bash |
| `compliance` | opus[1m] | Read, Grep |
| `compliance-overview` | sonnet | Read |
| `recovery-engine` | sonnet | Read |
| `bug-find` | sonnet | Read, Grep, Glob, Bash |
| `analyze-codebase` | sonnet | Read, Grep, Glob |

Agents with `Bash` (`gemini-validator`, `pentest-coordinator`, `secrets-lifecycle`,
`supply-chain-security`, `bug-find`) use it for read-only / scanner invocations. The
architect-prescribed intent is to restrict Bash to a non-destructive command
allowlist where Claude Code supports per-command Bash restriction — see
[`../API.md §13.5`](../API.md).

---

## Hooks

Declared in [`../hooks/hooks.json`](../hooks/hooks.json):

| Event | Script | Purpose |
|---|---|---|
| `SessionStart` | `hooks/scripts/session-start.sh` | Kernel health check at session start. |
| `PostToolUse` (matcher `Write\|Edit`) | `hooks/scripts/post-state-write.sh` | Validates state-file writes against the schema; enforces that state mutations went through `state_advance`. |

The `PostToolUse` hook is the filesystem-write backstop for the state-machine
invariant: a `gate_pass` written directly (bypassing
`gates_evaluate_and_enforce`) is caught here as well as at the primitive
pre-condition check.

---

## The audit trail (RC-5 / F-03)

`governance-plugin` is an **optional** dependency of the kernel. Its source is at
[`bulletproofsoftware-ai/bulletproof-governance-plugin`](https://github.com/bulletproofsoftware-ai/bulletproof-governance-plugin),
which may not be publicly reachable to every reader — that does not block using
the kernel.

- **Location**: resolved by `scripts/lib/paths.sh` (`kernel_audit_db_path`), in
  this order:
  1. `$AUDIT_DB_OVERRIDE` — explicit path, if set.
  2. `$GOVERNANCE_PLUGIN_ROOT/state/audit.db` — if `GOVERNANCE_PLUGIN_ROOT` is set.
  3. `${XDG_STATE_HOME:-~/.local/state}/governance-plugin/state/audit.db` —
     conventional default.
  - If governance-plugin is not installed, none of these paths exist. Audit
    emission then degrades to a local JSONL fallback file (see
    `kernel_audit_fallback_path`, default `<kernel root>/.audit-fallback.jsonl`,
    overridable via `$CONDUCTOR_AUDIT_FALLBACK`). This is a supported
    configuration, not an error.
- **Properties** (when governance-plugin is present): append-only, file mode
  `0600`, HMAC-token-protected writes.
- **Single authoritative trail**: `kernel.audit_emit` is the only primitive that
  holds the HMAC token. Direct-to-file writes by peer plugins are rejected at the
  governance write boundary (`AUDIT-001 unsigned_row`).
- Per-row Ed25519 signatures and the `kernel.audit_verify` integrity checker are
  **reserved** for later phases (see [`../SECURITY.md §17.6`](../SECURITY.md)).

Verify the trail:

```bash
bash scripts/verify-audit-emission.sh
# Confirms audit.db exists at the resolved path and is mode 0600 (exit 0),
# or reports a genuine misconfiguration (exit 1 / advisory exit 3).
# Exit 77 = SKIP: no audit database found because governance-plugin is not
# installed. This is a PASS-equivalent, supported configuration, not a failure.
```

---

## Environment variables

All external paths are resolved by `scripts/lib/paths.sh`; nothing in the kernel
assumes a particular checkout layout (e.g. `~/Code/...`). The table below is the
complete set of environment variables an operator can set.

| Variable | Purpose | Default when unset |
|---|---|---|
| `AUDIT_DB_OVERRIDE` | Explicit path to the governance-plugin audit database. Takes priority over `GOVERNANCE_PLUGIN_ROOT`. | Not set — falls through to `GOVERNANCE_PLUGIN_ROOT`, then the conventional path. |
| `GOVERNANCE_PLUGIN_ROOT` | Root directory of a governance-plugin install; the audit DB is read from `$GOVERNANCE_PLUGIN_ROOT/state/audit.db`. | Not set — falls through to the conventional XDG path. |
| `CONDUCTOR_STATE_DIR` | Where the kernel keeps data it owns (checkpoints, skill index, audit fallback, etc.), overriding the whole state directory at once. | `${XDG_STATE_HOME:-~/.local/state}/conductor-kernel` |
| `CONDUCTOR_AUDIT_FALLBACK` | Path to the local JSONL file used for audit events when no governance-plugin audit DB is reachable. | `<kernel root>/.audit-fallback.jsonl` |
| `QDRANT_URL` | REST endpoint for Qdrant, used by memory and stream-state primitives. | `http://localhost:6333` (Qdrant's documented default port; use a different value only if you remapped the host port) |
| `CONDUCTOR_SKILL_DIRS` | Colon-separated list of additional directories to scan when building the skill index — how a sibling domain plugin's skills get indexed. | Not set — only `~/.claude/skills`, the kernel's own `skills/`, and discovered marketplace/local plugin dirs are scanned. |
| `CONDUCTOR_SKILL_INDEX` | Output path for the generated skill index. | `~/.claude/skill-index.json` (or `--output` if passed to `build-skill-index.sh`) |
| `CONDUCTOR_AUDIT_EMITTER` | Path to an external audit-emitter script/executable consumed by `scripts/code-mode-audit-mcp.py` for code-mode dispatch audit emission. | Not set — code-mode audit emission is skipped with an explanatory message; nothing fails. |
| `CONDUCTOR_DOC_SYNC_HOOK` | Path to an executable invoked with a generated document's path, used by the `compliance-overview` agent to publish docs to an operator-chosen destination (e.g. a personal notes tool). | Not set (default) — no sync is attempted; this is expected behavior, not a warning. |
| `CONDUCTOR_NOTIFY_HOOK` | Path to an executable invoked with a message string, used by the `retrospective` agent to notify the operator out-of-band (e.g. a chat bot script). | Not set (default) — no notification is attempted; this is expected behavior, not a warning. |
| `TEST_PLUGIN_DIR` | Where `scripts/verify-cross-plugin-dispatch.sh` scaffolds its throwaway test plugin. | `$(kernel_state_dir)/kernel-dispatch-test` |
| `XDG_STATE_HOME` | Standard XDG base-directory variable; used as the parent of the kernel's own state dir and (when `GOVERNANCE_PLUGIN_ROOT` is unset) the conventional governance-plugin state path. | `~/.local/state` |

A missing or failing optional hook (`CONDUCTOR_DOC_SYNC_HOOK`, `CONDUCTOR_NOTIFY_HOOK`, `CONDUCTOR_AUDIT_EMITTER`) never blocks the primary work of the agent or script that consults it — each degrades to a no-op with a one-line log message.

---

## Data egress — what leaves the machine

| Path | Egress | Control |
|---|---|---|
| Audit (`audit.db`) | **None** by default (local, 0600). | Operator verifies mode post-deploy. |
| `gemini_validate` | **Yes** — output goes to Google's Gemini API. | Set `data_classification`; default refuses `regulated` without `operator_override` (RC-10). |
| Memory (`memory_*`) | **None** — local Qdrant (Docker). | — |
| Stream-mode n8n calls | Per operator's own n8n instance. | Operator-controlled; kernel introduces no hosted n8n. |

`gemini_validate` is the single largest residual egress surface. Treat enabling
`operator_override` for regulated data as requiring a data-processing agreement with
Google.

---

## Operator deployment preconditions

The kernel surfaces failures clearly but cannot fix operator misconfiguration.
Before deploying (especially in regulated environments), work through the
hardening checklist in [`../SECURITY.md §17.5`](../SECURITY.md). The load-bearing
items:

1. **Audit file permissions** — verify `state/audit.db` is `0600`.
2. **n8n credentials** live in the `n8n-mcp` MCP server config, never in kernel
   config. Scope the n8n API token to `create_workflow`, `trigger_webhook`,
   `list_executions`, `get_workflow_details` (RC-9). The kernel never stores, logs,
   or accepts inline n8n credentials; inline credential fields are stripped and
   audited (`stream.inline_credential_rejected`).
3. **Subscription secrets** — `secret_ref` URIs must resolve to a secrets manager
   (Vault, AWS Secrets Manager, `env://`, `file://`), never inline values.
4. **Stream authentication** — every subscription should have
   `authentication.kind != "none"` unless explicitly acknowledged (RC-4).
5. **Redactor** — if processing PII/PHI/regulated content, register a redactor via
   `kernel.audit_register_redactor` **before** any dispatch, or use the
   `prompt_ref` / `response_ref` form.
6. **Recovery override mode** — keep `recovery_override_mode = "strict"` in
   regulated deployments, or require cosign-signed override playbooks (RC-15).
7. **Path safety** — `state_init` validates `state_path` against the kernel's
   resolved cwd (RC-11); confirm that cwd is what you intend.

---

## Verification scripts

| Script | Checks |
|---|---|
| `scripts/verify-agent-tools.sh` | Every agent under `agents/` declares `allowed-tools`. |
| `scripts/verify-audit-emission.sh` | `audit.db` present and mode `0600`; exits 77 (SKIP, a PASS-equivalent) if governance-plugin is not installed. |
| `scripts/verify-cross-plugin-dispatch.sh` | A sibling plugin can dispatch `conductor-kernel:critic` and an `agent.dispatch` audit row is recorded. |
| `scripts/ci-dispatcher-diff.sh` | CI drift detector — fails if a domain command's duplicated canonical prose (`BEGIN_CANONICAL`/`END_CANONICAL`) drifts from `lib/dispatcher-core.md` (RC-16 hash gate first, then block diff). |

Additional scripts under `scripts/` support code-mode dispatch
(`code-mode-dispatch.sh`, `code-mode-audit-mcp.py`), the change-log attribution
system (`change-log-query.sh`), and skill mining/promotion
(`skill-promote.sh`, `skill-promote-patch.sh`, `skill-publish.sh`,
`build-skill-index.sh`). These are consumed by the agents (notably `critic` and
`retrospective`) and by domain workflows; they are not entry points an operator
runs directly in normal operation.

---

## State schemas

| Schema | Version | Required fields |
|---|---|---|
| [`workflow-state.schema.json`](../schemas/workflow-state.schema.json) | 3.0 | None enforced — see note below. `schema_version` accepts `1.0`–`3.0` for backward compatibility. |
| [`stream-state.schema.json`](../schemas/stream-state.schema.json) | 3.0 | `schema_version`, `domain`, `stream_id`, `subscriptions` (each subscription requires `source`, `kind`, `authentication`). |

**Workflow-state required-field note**: the required list is intentionally empty. A
survey of 29 live state files found 14 missing one or more of the originally
"required" fields at any given time (completed workflows without a `task_queue`,
early-phase workflows without a `current_step`, recovery-session files without a
`project_name`). The schema documents the structure of declared fields when
present; it does not enforce phase-dependent presence. Domain-specific structure
belongs under `domain_extensions`.

The stream-state schema is stricter (`additionalProperties: false` at the top
level and inside subscriptions), so polluted stream-state documents are rejected at
validation time.

---

## CI

[`../.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs ShellCheck (error
severity, warn-only) over all `*.sh` files on push and PR to `main`. The
`actions/checkout` action is pinned to a commit SHA. The workflow has
`permissions: contents: read` and interpolates no untrusted `github.event.*` input
into `run:` steps.

---

## Upgrades & versioning

The kernel follows semver per [`../API.md §11`](../API.md). While `0.y.z`, breaking
changes are allowed in minor bumps but discouraged; once `1.0.0` ships, strict
semver applies to the `stability.v0.1.0.stable` surface in
[`../plugin.json`](../plugin.json). Reserved namespaces
(`memory_recall_cross_domain`, `audit_verify`, `local_validate`) and experimental
stream-mode primitives may gain implementations additively without a major bump.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
