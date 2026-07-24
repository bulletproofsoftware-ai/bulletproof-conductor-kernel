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

- **Location**: `governance-plugin/state/audit.db` (owned by `governance-plugin`,
  not the kernel).
- **Properties**: append-only, file mode `0600`, HMAC-token-protected writes.
- **Single authoritative trail**: `kernel.audit_emit` is the only primitive that
  holds the HMAC token. Direct-to-file writes by peer plugins are rejected at the
  governance write boundary (`AUDIT-001 unsigned_row`).
- Per-row Ed25519 signatures and the `kernel.audit_verify` integrity checker are
  **reserved** for later phases (see [`../SECURITY.md §17.6`](../SECURITY.md)).

Verify the trail:

```bash
bash scripts/verify-audit-emission.sh
# Confirms audit.db exists at the canonical path and is mode 0600.
```

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
| `scripts/verify-audit-emission.sh` | `audit.db` present and mode `0600`. |
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
