# Security Policy — conductor-kernel v0.1.0

This document is the canonical security policy and threat model summary for `conductor-kernel`. Its structure and content are prescribed by `API.md §17` (RC-14 / F-21). Six sections follow in order.

The full Phase 1 CISO security review, including the 20-row STRIDE table, full findings list (F-01 .. F-21), and remediation map, is committed at `docs/threat-model-v0.1.0.md` and is the canonical reference for the items summarized here.

---

## 17.1 Threat Model Summary

`conductor-kernel` is a Claude Code plugin that exports orchestration primitives, validators, security agents, and supporting skills to **domain plugins** (`conductor-dev`, `clue-soc`, future SOC/dev/3rd-domain consumers, and eventual OSS consumers). The kernel is the only component that is permitted to write to the governance-plugin audit trail, and it is the only component that mediates cross-plugin agent dispatch, memory recall, recovery classification, and gemini validation.

The v0.1.0 threat model was developed using **STRIDE**, **OWASP LLM Top 10 (2025)**, **MITRE ATLAS**, **SLSA v1.0**, and **NIST SSDF (SP 800-218 v1.1)**. The full review evaluated 20 elements of the public surface — see `docs/threat-model-v0.1.0.md` for the verbatim table.

### Critical findings and their mitigations

Four CRITICAL findings drove load-bearing additions to the kernel API surface before v0.1.0 shipped:

- **F-02 — Indirect prompt injection on agent dispatch.** Original `kernel.dispatch_agent(qualified_name, prompt, ...)` accepted a single trusted string. Mitigation: added `kernel.dispatch_agent_v2(qualified_name, prompt_envelope, ...)` with explicit `system_extension` / `user_trusted` / `user_untrusted` / `artifacts` slots (`API.md §6`). The envelope form is mandatory for any caller interpolating untrusted log / alert / file content; CLUE Phase 4 is contractually required to use it.
- **F-05 — Cross-domain memory leakage.** Original `kernel.memory_recall(query, filters)` allowed an absent `domain` filter, returning memories across domains. Mitigation: `filters.domain` is now mandatory at the boundary; `payload.domain` and `payload.stored_by` are auto-injected from caller context and unforgeable; the standard primitive rejects cross-domain recall with `KER-MR-005`. Cross-domain recall is reserved at `kernel.memory_recall_cross_domain` with explicit justification and (Phase 5+) operator approval (`API.md §6`).
- **F-07 — HUMAN_GATE bypass on destructive containment.** Original `kernel.workflow.gates_evaluate` returned an advisory verdict; the caller was trusted to call `state_advance({kind: "gate_pass"})`. Mitigation: replaced by `kernel.workflow.gates_evaluate_and_enforce` (`API.md §4`) which blocks on `human_gate`, dispatches governance, waits for resolution, and writes the resulting state itself. A caller-written `gate_pass` lacking a prior gate-resolution audit row fails with `KER-GE-002`. The advisory form is retained but deprecated at v0.1.0 and removed at v1.0.0.
- **F-10 — Unauthenticated stream event ingestion.** Original `kernel.stream.init` had no authentication declaration. Mitigation: `subscriptions[].authentication` is REQUIRED in `stream-state.schema.json`; `kernel.stream.handle_event` verifies authentication BEFORE schema validation; `kind: "none"` requires explicit `audit_warning_acknowledged: true` and emits a one-time warning event (`API.md §5.0` for the n8n credential lifecycle; `API.md §5` for the enforcement order).

### High and medium findings

Eight HIGH findings (denial-of-wallet, audit-write authorization, memory provenance, schema permissiveness, gemini egress, namespace collision, n8n credential scope, state-machine bypass) and seven MEDIUM findings drove additional surface additions: per-trace dispatch budgets (`API.md §6` RC-7), HMAC-token gated audit writes (RC-5), the `prompt_ref`/`response_ref` audit form (RC-6), the audit redactor registration hook (RC-6), explicit per-agent `allowed-tools` declarations (RC-12), data-classification on `gemini_validate` (RC-10), recovery override scoping (RC-15), top-level schema `additionalProperties: false` (RC-13), and `state_init` path-traversal validation (RC-11).

### Residual risks (deferred, transparently tracked)

Items deferred to later phases are enumerated in `§17.6 Known Limitations`. Each cites the originating finding (F-XX) and the deferred-hardening item (OH-X) so downstream consumers can track resolution. The kernel API surface reserves the relevant namespaces (`kernel.memory_recall_cross_domain`, `kernel.audit_verify`, `kernel.local_validate`) so the eventual implementations land additively without a major bump.

---

## 17.2 Coordinated Disclosure

```
Report security issues privately to: marc@bulletproofsoftware.ai
GPG key fingerprint:                  6931 BF66 8102 203A 51A1  48C7 FB57 C3EF 125A 0BCE
GPG long key id:                      FB57C3EF125A0BCE
GPG key (armored public block):       docs/security-pgp-public-key.asc
Key algorithm / expiry:               ed25519 (cert+sign) / cv25519 (encrypt) — expires 2028-05-13
Auto-acknowledgment SLA:              24 hours (monitored mailbox)
Triage SLA:                           14 days (severity classification + remediation plan)
Public disclosure SLA:                90 days (responsible-disclosure window; mutual agreement may extend)
Safe-harbor language:                 Researchers who follow this policy receive a non-prosecution commitment for good-faith research that does not exfiltrate user data, degrade availability, or violate the privacy of third parties.
Hall of fame:                         not maintained — researchers credited inline in the public advisory issued for each fix
```

The disclosure mailbox must be live and the GPG key must be generated + published before the v0.1.0 public release tag is cut (per the Phase 8 OSS-release pre-flight in `API.md §12.3`).

Do **not** open a public GitHub issue or pull request for a vulnerability. Use the email above; we will coordinate a private fix and a public advisory after a fix is available.

---

## 17.3 Supported Versions

| Version    | Support status                | Until           |
|------------|-------------------------------|-----------------|
| 0.1.x      | Active development            | 0.2.0 release   |
| < 0.1.0    | Not supported (pre-release)   | n/a             |

This table is updated on every release. v0.1.x receives security backports and patch-level fixes until v0.2.0 ships. Pre-v0.1.0 builds are unsupported.

---

## 17.4 Data Flow & Classifications

This section enumerates every data flow that crosses a trust boundary in `conductor-kernel`. Operators are responsible for verifying each flow matches their compliance posture before deployment.

- **Audit egress: NONE by default.** All audit emissions go to `governance-plugin/state/audit.db` on the local filesystem. The file is mode `0600`, append-only (`INSERT OR IGNORE` only — no `UPDATE`/`DELETE` in the bus module), and HMAC-token-gated at the write boundary via a 64-byte service token persisted at `state/audit.token` (RC-5 / F-03). The kernel does not transmit audit content over the network. **Per-row Ed25519 signatures are reserved for v0.2.0** (see §17.6 Known Limitations); v0.1.0 compensating controls are the three layers above (filesystem 0600, append-only schema, service-token gate).
- **Gemini egress: `kernel.gemini_validate`.** The validator spawns the `gemini` CLI with a composed prompt that includes the original agent output, the expectation, and the target-agent name. **This egresses content to Google's Gemini API.** Per RC-10 / F-17, every call MUST carry a `data_classification` argument; the default operator policy refuses `data_classification == "regulated"` without an explicit `operator_override`. Operators handling regulated content MUST either (a) avoid `gemini_validate` and rely on the reserved `kernel.local_validate` primitive (Phase 5+ implementation) or (b) execute a written data-processing agreement with the validator provider before enabling override.
- **Memory egress: NONE.** `claude-memory-mcp` writes to the local Qdrant Docker instance over `localhost:6334`. There is no network egress under default configuration. Operators who reconfigure Qdrant to a remote instance are responsible for the resulting egress.
- **n8n egress: per stream configuration (Phase 3+).** Stream-mode primitives dispatch to the user-configured n8n instance. n8n credentials live exclusively in the user's `n8n-mcp` MCP server configuration; the kernel does not store, log, persist, or accept inline n8n credentials (RC-9 / F-11). Stream `subscriptions[].authentication.kind == "none"` requires explicit operator acknowledgment (RC-4 / F-10).
- **Prompt content in audit rows.** Per RC-6 / F-04, agent.dispatch audit events include the literal `prompt` and `response` strings by default. To avoid PII in audit rows, callers MAY pass `prompt_ref` / `response_ref` (sha256 hash + storage URI) instead of literal content, with the caller responsible for restrictive permissions on the referenced files. A redaction hook (`kernel.audit_register_redactor`) is exposed but no default redactor ships in v0.1.0; CLUE Phase 7 ships the Presidio integration.

A one-page data-flow diagram with trust boundaries is deferred to Phase 8 per `docs/threat-model-v0.1.0.md` OH-8.

---

## 17.5 Hardening Recommendations

For consumers planning to deploy `conductor-kernel` in regulated, multi-tenant, or otherwise high-assurance environments, work through this checklist before production rollout:

1. **File permissions.** Verify `governance-plugin/state/audit.db` is mode `0600` and writable only by the governance-plugin process identity. The kernel enforces this at write time; operators verify post-deployment with `stat -f '%Mp%Lp' <path>` (macOS) or `stat -c '%a' <path>` (Linux).
2. **Secret management.** Stream-mode subscriptions reference secrets via `secret_ref` URIs that MUST resolve to a secrets manager (Vault, AWS Secrets Manager, AWS Parameter Store, etc.). Inline secret values in `secret_ref` are rejected. Rotate secrets per operator policy.
3. **n8n credential scope.** Limit the n8n-mcp API token to the four capabilities listed in `API.md §5.0`: `create_workflow`, `trigger_webhook` (or `trigger_webhook_workflow`), `list_executions`, `get_workflow_details`. Confirm scope adherence with the `conductor-kernel:secrets-lifecycle` agent in Phase 2+.
4. **Stream authentication.** Every `subscriptions[].authentication.kind` MUST be one of `hmac`, `mtls`, `oauth_jwt`, or `shared_secret` for production deployments. `kind: "none"` is permitted only with explicit `audit_warning_acknowledged: true` and is contraindicated outside of dev / lab environments (RC-4 / F-10).
5. **Audit redactor registration.** Before any agent dispatch that may interpolate PII / PHI / regulated content, register a redactor via `kernel.audit_register_redactor`. Until a redactor is registered, use the `prompt_ref` / `response_ref` form per RC-6 to keep literal PII out of audit rows.
6. **Recovery override mode.** In regulated deployments, set `recovery_override_mode = "strict"` in operator config OR require all caller-supplied recovery playbooks to be cosign-signed per RC-15 / F-13. The default `permissive_signed` mode allows non-destructive-category overrides without a signature, which is acceptable for dev/lab but not for production destructive-containment domains.
7. **Gemini data classification.** Do NOT enable `operator_override` for `gemini_validate` calls carrying `data_classification == "regulated"` without an executed data-processing agreement with Google. If regulated data must be validated, defer to `kernel.local_validate` (Phase 5+ implementation) or implement a local validator that does not egress content.
8. **Path safety on `state_init`.** The kernel validates `state_path` against `cwd` via `os.path.realpath` + `os.path.commonpath` (RC-11 / F-19). Operators MUST verify the kernel's resolved cwd at deployment time is the intended working directory; a misconfigured cwd nullifies the containment check.
9. **OSS-readiness gate.** Before any public release tag, run the 12-item pre-release checklist in the CISO §7 (committed at `docs/threat-model-v0.1.0.md`). Items include gitleaks scan, secrets-lifecycle self-scan, SBOM generation, license audit, signed-release verification.

---

## 17.6 Known Limitations

Items below are deferred for transparency. Each cites the originating CISO finding (F-XX) and the deferred-hardening item (OH-X) so downstream consumers can track resolution.

- **Per-node identity in stream-mode.** F-12 / OH-1. Phase 3 implementation populates `parent_id = "<stream_id>:<n8n_node_id>"` in agent.dispatch audit events emitted from stream-mode. v0.1.0 reserves the slot in the spec (`API.md §5.handle_event`) so the eventual implementation lands additively.
- **Cross-domain memory recall.** F-05 / OH-5. `kernel.memory_recall_cross_domain` namespace is reserved at v0.1.0; the implementation lands in Phase 5+ once the governance approval flow for cross-domain queries is in place. Calls in v0.1.0 return `KER-MR-006 cross_domain_not_implemented`.
- **Local-model validator.** F-17 / OH-2. `kernel.local_validate` namespace is reserved at v0.1.0; the implementation (Ollama-backed or operator-configured) lands in Phase 5+ when CLUE's regulated-data scenarios go live. Calls in v0.1.0 return `KER-LV-001 local_validate_not_implemented`.
- **Audit integrity verifier (incl. per-row Ed25519).** F-03 / OH-6. `kernel.audit_verify` namespace is reserved at v0.1.0; the implementation lands in v0.2.0 alongside per-row Ed25519 signing in `governance-plugin/governance/lib/audit_bus.py`. v0.1.0 ships only the write-path service-token gate (HMAC-keyed token at `state/audit.token`, mode 0600) plus the file-mode/append-only schema controls. Per-row Ed25519 signing requires (a) adding `cryptography` or `pynacl` as a governance dependency, (b) a `row_signature` column migration over the existing ~36k rows (forward-only signing; legacy rows remain unsigned with NULL signature), (c) signing-key generation + rotation policy, and (d) the verifier CLI. Calls to `kernel.audit_verify` in v0.1.0 return `KER-AV-001 audit_verify_not_implemented`.
- **SBOM at release time.** F-16 / OH-3. v0.1.0 ships zero direct runtime dependencies (Markdown + JSON Schema + Bash). SBOM generation is required at v0.1.0 public release per the OSS-readiness gate in `API.md §12.3`; the CI job lands in Phase 8.
- **Bundled dependency license audit.** F-20 / OH-4. v0.1.0 ships under MIT with zero direct dependencies. Phase 8 conducts a license audit before public release; any GPL/AGPL contamination would force a relicense decision.
- **OS-level audit chaining.** F-03. The `state/audit.db` rejection log relies on the OS audit subsystem (`auditd` on Linux, `OSLogStore` on macOS). On hosts without an OS audit subsystem, the kernel falls back to a separate restricted file with the same write semantics. Operators verify availability post-deployment.
- **Workflow-mode state-file HMAC signature.** F-08 / A-08 (final adversarial review). The original CISO F-08 recommendation was to compute an HMAC `state_signature` over state file contents in `kernel.workflow.state_advance` so that direct filesystem edits (including from n8n Code nodes, SSH operators, or external orchestrators bypassing the PostToolUse hook) would invalidate the signature on read. v0.1.0 ACCEPTS this as a known risk and ships compensating controls instead of the signature: (a) workflow-mode state file integrity is operator-responsibility per the spec, (b) stream-mode state lives in Qdrant where access is governed at the database boundary (Qdrant API key), (c) the `post-state-write.sh` PostToolUse hook validates schema compliance for any Claude-Code-driven write, (d) the kernel's own primitives are the only sanctioned write path. The HMAC signature primitive is reserved for v0.2.0; consumers requiring tamper-evident workflow state today should pin state files on filesystems with immutability flags (Linux `chattr +a`, macOS `chflags uimmutable`) or store state in an append-only object store.
- **Tier-aware Gemini ERROR handling.** A-01 (final adversarial review). `gemini_validate` ERROR verdict is now tier-aware: non-blocking only at TRIVIAL/MINOR; PAUSE at STANDARD; BLOCK at MAJOR/CRITICAL — preventing an attacker who can DoS Gemini from silently removing the independent validation gate. See `agents/gemini-validator.md:279-287`.
- **CLUE response workflow execution-data hardening.** A-02 (final adversarial review). All five clue-soc/workflows/responses/*.json plus the ransomware playbook set `settings.saveDataSuccessExecution: "none"` so Bearer tokens passed via HTTP headers are not persisted in the n8n execution database. Errors retain data for debugging. Operators MUST use n8n's native Credential store (referenced by ID), never inline env-var-derived tokens.
- **Ransomware playbook independent EDR verification.** A-06 (final adversarial review). The ransomware-immediate-containment playbook's `validate-trigger` node MUST independently query the EDR API to confirm `mass_file_write` + `encryption_suffix_rename` patterns from raw telemetry within a 30-second window; it MUST NOT trust pattern_evidence supplied in the request body (which a compromised incident-commander could forge). An operator-side rate limit caps ransomware playbook invocation at max 1 per 5-minute window.

---

*End of SECURITY.md v0.1.0. The full Phase 1 CISO security review is the canonical reference for every finding cited here; that document is committed at `docs/threat-model-v0.1.0.md`.*
