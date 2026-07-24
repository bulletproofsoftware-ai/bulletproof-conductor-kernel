# Changelog

All notable changes to `conductor-kernel` are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) per `API.md §11`.

## [0.1.0] — 2026-05-12

Initial release. First OSS-quality contract.

### Added

- 19 domain-agnostic agents extracted from the legacy `conductor-plugin`: `critic`, `gemini-validator`, `recovery-engine`, `outcome-collector`, `checkpoint`, `event-router`, `ciso`, `llm-security`, `pentest-coordinator`, `secrets-lifecycle`, `supply-chain-security`, `research`, `retrospective`, `compliance`, `compliance-overview`, `prediction-engine`, `completeness-validator`, `bug-find`, `analyze-codebase`. Every kernel agent declares an explicit `allowed-tools` frontmatter per `API.md §13.5` (RC-12 / F-15).
- 14 domain-agnostic skills under `skills/` per `API.md §3`.
- `lib/dispatcher-core.md` — canonical orchestration prose covering tier classification, agent dispatch, token budget tracking, spec alignment, builder readback, Gemini validation loop, gate enforcement, state persistence, and outcome emission. Duplicated by domain command files via `<!-- BEGIN_CANONICAL ... -->` markers.
- `lib/budget-defaults.yaml` — default per-dispatch budget for denial-of-wallet protection per RC-7 / F-09.
- `lib/recovery-playbook.yaml` — kernel-shipped 7-category recovery strategy stub per `API.md §6` and RC-15 / F-13. Full strategy content is a Phase 2 follow-up.
- `schemas/workflow-state.schema.json` (v3.0) and `schemas/stream-state.schema.json` (v3.0). Backward-compatible with legacy v1/v2 conductor-state files per REQ-CDV-002.
- `schemas/events/` directory and README for per-source event JSON Schemas per REQ-XCT-007.
- `scripts/verify-cross-plugin-dispatch.sh`, `scripts/verify-audit-emission.sh`, `scripts/verify-agent-tools.sh` — Phase 1 exit-gate verification scripts.
- `scripts/ci-dispatcher-diff.sh` — placeholder per `API.md §9.3` (Phase 2 builder authors the live implementation).
- `templates/n8n-audit-emitter.json` (stub) and `templates/canonical-source-header.md` per REQ-XCT-002 and `API.md §9.2`.
- `SECURITY.md` per `API.md §17` covering threat model summary, coordinated disclosure, supported versions, data flows, hardening recommendations, and known limitations.

### Known limitations (full list in `SECURITY.md §17.6`)

- Stream-mode primitives are API surface only at v0.1.0; implementation lands in Phase 3.
- `kernel.memory_recall_cross_domain`, `kernel.audit_verify`, and `kernel.local_validate` are reserved namespaces; implementations land in later phases additively.
- `kernel.workflow.gates_evaluate` is deprecated at v0.1.0 in favor of `kernel.workflow.gates_evaluate_and_enforce`; removed at v1.0.0.
- Default recovery playbook strategies are stubbed; full strategy YAML lands in Phase 2.

[0.1.0]: https://github.com/bulletproofsoftware-ai/bulletproof-conductor-kernel/releases/tag/v0.1.0
