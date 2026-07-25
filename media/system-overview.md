# bulletproof-conductor-kernel

## Executive Summary

The bulletproof-conductor-kernel is a domain-agnostic orchestration kernel designed for multi-agent workflows within Claude Code. It functions as a foundational plugin that centralizes five critical orchestration concerns: the dispatch contract, validation loops, audit trails, state machine management, and gate enforcement. By providing a stable, single-import surface, the kernel allows downstream domain plugins (such as development or security operation center plugins) to execute tier-classified, gate-enforced, and audit-logged workflows without re-implementing core infrastructure.

Currently at version 0.1.0, the kernel exports 19 agents, 14 skills, and a suite of workflow and stream-mode primitives. It maintains a strict security posture, featuring an HMAC-token-protected audit trail, restricted agent toolsets, and robust prompt-injection boundaries. The kernel deliberately exposes no slash commands, operating entirely as a library for domain-specific integrations.

## Core Components and Capabilities

### The 19 Domain-Agnostic Agents
Each agent in the kernel is "read-mostly" and operates with an explicit, minimal `allowed-tools` frontmatter. Notably, `Task` is excluded from all kernel agent allowlists to prevent kernel agents from dispatching other agents; dispatching is reserved for domain-plugin commands.

| Category | Agents |
| :--- | :--- |
| **Workflow & Validation** | critic, gemini-validator, completeness-validator, checkpoint, event-router |
| **Outcome & Reflection** | outcome-collector, retrospective, prediction-engine, research |
| **Security & Compliance** | ciso, llm-security, pentest-coordinator, secrets-lifecycle, supply-chain-security, compliance, compliance-overview |
| **Recovery & Robustness** | recovery-engine |
| **Code Investigation** | bug-find, analyze-codebase |

### Domain-Agnostic Skills
The kernel provides 14 skills that offer prose guidance to Claude Code. These skills encode tier-appropriate patterns rather than executable code:
*   context-management, retry-policy, self-healing, state-management, event-automation, outcome-measurement, predictive-scaling, process-knowledge, sbr, dashboard-integration, brd-tracking, workflow-reference, agent-capabilities, agent-interop.

### Orchestration Modes
The kernel supports two distinct operational modes:
1.  **Workflow Mode:** Designed for bounded tasks with a defined start and end. It utilizes tier-classification to determine if gates are blocking or advisory and persists state to local JSON files.
2.  **Stream Mode (Experimental):** Designed for long-lived, event-driven subscriptions (webhooks, cron jobs). It requires mandatory authentication and pre-defined budgets at initialization to mitigate "denial-of-wallet" risks.

---

## Detailed Analysis of Key Themes

### 1. Security-First Architecture and Isolation
The kernel is positioned as a secure layer between domain plugins and the governance-plugin audit trail.
*   **Prompt Injection Boundaries:** To handle untrusted content (logs, external alerts), the kernel uses a prompt envelope form. This wraps untrusted regions in `<UNTRUSTED:label>` blocks with a preamble instructing the model to treat the content as data, not instructions.
*   **Tool Restriction:** Only five agents (gemini-validator, pentest-coordinator, secrets-lifecycle, supply-chain-security, bug-find) are permitted to use `Bash`, and even then, only for read-only or scanner invocations.
*   **Domain Isolation:** Memory recall requires a mandatory `filters.domain`. The kernel enforces domain isolation internally, preventing one domain from accessing another’s memories.

### 2. Immutable Audit Trail and State Integrity
The kernel acts as the sole authoritative source for workflow telemetry. `governance-plugin` is an **optional** dependency — when it is installed, `kernel.audit_emit` writes to its HMAC-protected `state/audit.db`; when it is not, audit emission degrades to a local JSONL fallback file and every other kernel capability is unaffected.
*   **Audit Emission:** The `kernel.audit_emit` primitive is the only component holding the HMAC token required for writes to the `governance-plugin/state/audit.db`. Direct-to-file writes by other plugins are rejected.
*   **State Machine Enforcement:** The `state_advance` primitive is the only legal way to mutate workflow state. A `PostToolUse` hook serves as a filesystem backstop, validating that state mutations conform to schemas and were not written directly to the JSON file.

### 3. Tiered Governance and Gate Enforcement
Workflow governance is driven by a classification tiering system: TRIVIAL, MINOR, STANDARD, MAJOR, and CRITICAL.
*   **Gate Primitives:** The `gates_evaluate_and_enforce` primitive handles human approval gates. It blocks execution for up to 24 hours until an operator approves or rejects the action. 
*   **Bypass Prevention:** State cannot be advanced to `gate_pass` without a corresponding prior gate-resolution audit row, preventing callers from bypassing human oversight.

### 4. Data Egress and Privacy Controls
The kernel provides clear visibility into data leaving the local environment:
*   **Gemini Egress:** The `gemini_validate` primitive is the primary egress surface, sending data to Google’s Gemini API. It requires an explicit `data_classification` setting and defaults to refusing regulated data.
*   **Local Processing:** Audit logs and memory (via Qdrant) are stored locally.
*   **Redaction:** Operators must register a redactor via `kernel.audit_register_redactor` before dispatching if PII/PHI or regulated content is being processed.

---

## Important Quotes with Context

> **"The kernel exports no slash command. You use it by building a domain plugin that dispatches the kernel's agents and calls its primitives."**
*   *Context:* Found in the Administrator and User guides, this emphasizes that the kernel is infrastructure for other plugins, not a standalone tool for end-users.

> **"The PostToolUse hook is the filesystem-write backstop for the state-machine invariant: a gate_pass written directly (bypassing gates_evaluate_and_enforce) is caught here."**
*   *Context:* Explains the technical enforcement of the state machine, ensuring that security gates cannot be bypassed by simply editing a state file.

> **"Every one of the 19 kernel agents declares an explicit, minimal allowed-tools frontmatter. Task is not in any kernel agent's allowlist."**
*   *Context:* Highlights the security design choice to prevent agent-to-agent dispatching within the kernel, keeping the orchestration logic centralized in the domain plugin.

> **"Authentication is mandatory per subscription (RC-4)... kind: 'none' is allowed only when the operator explicitly acknowledges the risk."**
*   *Context:* From the Stream Mode requirements, highlighting the kernel's refusal to process unauthenticated external events by default.

---

## Actionable Insights for Administrators

### Deployment Preconditions
Operators must ensure the following hardening steps are completed before deploying in regulated environments:
*   **File Permissions:** Verify that `state/audit.db` is set to mode `0600` (read/write for owner only).
*   **Credential Scoping:** Ensure n8n API tokens are scoped strictly to `create_workflow`, `trigger_webhook`, `list_executions`, and `get_workflow_details`. The kernel never stores these credentials inline.
*   **Secrets Management:** Resolve `secret_ref` URIs to a dedicated manager (Vault, AWS Secrets Manager) rather than using inline values.
*   **Path Safety:** Confirm the current working directory (cwd) is correct, as `state_init` validates all paths against the resolved cwd to prevent traversal attacks.

### Verification and Monitoring
The kernel includes specific scripts for ongoing health and compliance checks:
*   `scripts/verify-agent-tools.sh`: Ensures no agent has gained unauthorized tools.
*   `scripts/verify-audit-emission.sh`: Checks for the presence and permissions of the audit database.
*   `scripts/ci-dispatcher-diff.sh`: A drift detector used in CI to ensure domain commands haven't diverged from the kernel's canonical orchestration prose.

### Data Handling
When processing regulated content, the operator must either:
1.  Register a redactor **prior** to any agent dispatch.
2.  Use the `prompt_ref` or `response_ref` forms, which pass a hash and storage URI instead of literal sensitive content.