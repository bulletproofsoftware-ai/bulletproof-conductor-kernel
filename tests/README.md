# Tests (`tests/`)

Per kernel-api.md §1, this directory holds kernel-level test prose and reference test suites. v0.1.0 ships markdown-prose test specifications; full automation lands in Phase 2+ alongside the live ci-dispatcher-diff and the verified audit-emit round-trip.

## v0.1.0 contents

- `tests/cross-plugin-dispatch.test.md` — Phase 1 exit gate (b) procedure (kernel-api.md §13.2). The scaffold step is automated via `scripts/verify-cross-plugin-dispatch.sh`; the dispatch round-trip is MANUAL inside Claude Code.
- `tests/audit-emission.test.md` — Phase 1 exit gate (c) procedure (kernel-api.md §13.3). The audit.db existence + mode check is automated via `scripts/verify-audit-emission.sh`; the `kernel.audit_emit` round-trip is MANUAL.
- `tests/schema-validation.test.md` — Phase 1 schema validation procedure for `workflow-state.schema.json` and `stream-state.schema.json`.

## Phase 2+ contents

- Programmatic schema validation harness (`ajv` or Python `jsonschema`) for both base schemas with a representative fixture corpus.
- Programmatic ci-dispatcher-diff validation once domain duplicate files exist.
- Programmatic round-trip of `kernel.audit_emit` once governance-plugin HMAC-token enforcement is live (Phase 3).
- Programmatic prompt-injection corpus for `kernel.dispatch_agent_v2` envelope-form validation (Phase 7 adversarial-defense evals per kernel-api.md §6).
