---
name: sbr
description: >
  Subclass Brain Registry. Semantic search over successful prompt-spec pairs from
  prior conductor workflows. Indexes prompts that earned PASS verdicts (completion_pct
  >= 80) from Gemini validation into a standalone Qdrant collection so agents can
  retrieve "show me how a similar spec was solved before." Distinct from
  process-knowledge (rule-based, domain-keyed). SBR is example-based and
  similarity-keyed. Use when an architect is drafting a new spec or a builder is
  stuck and wants to see prior successful patterns.
---

# Subclass Brain Registry (SBR) Skill

A standalone retrieval surface over **prompt-spec pairs that worked** — agent inputs that produced Gemini PASS verdicts with high completion. Lets a future agent ask "we have a similar problem; what worked last time?" and get back examples with their outcome metadata.

SBR is **standalone**. It does not depend on KU/KI extraction, project_signature, or agent cards. The skill can be loaded and used in isolation.

## When To Use

Use SBR when an agent needs **examples of similar prior work**, specifically:

- **`conductor-architect`** at the start of spec planning, before drafting a new architecture spec. Query SBR with a short natural-language description of the upcoming spec; if highly similar prior specs are returned (similarity >= 0.75), inspect their `spec_summary` and `outcome_validation_id` to recover the pattern that produced PASS.
- **`conductor-builder`** when blocked or making non-obvious implementation choices. Query SBR with the current task description; retrieve prior prompt-spec pairs from the same or similar agent and project.
- **`conductor-research`** when classifying a new BRD requirement and similar requirements have been seen before.

Do **not** use SBR for:

- Rule lookups → use `process-knowledge` (deterministic rules, decision trees, SOPs).
- Session memory → use `claude-memory-plugin` (`memory_recall`).
- Project setup decisions before SBR has been seeded (cold-start: SBR returns empty until at least one PASSed validation has been ingested).

## What This Skill Owns

The `sbr` Qdrant collection at `http://localhost:6333/collections/sbr`.

This collection is **owned by this skill**, not by `claude-memory-plugin`. The claude-memory `memory_store` tool does not accept a `collection` parameter (verified by reading `claude-memory-mcp/src/index.ts:380-403`), so SBR talks to Qdrant via direct HTTP. SBR points are project-state artifacts (specs that worked) and are intentionally NOT subject to:

- The `long_term` collection's sensitivity classification
- Memory decay / expiry rules
- The session/episodic/semantic taxonomy

Embeddings reuse the same Ollama model (`nomic-embed-text`, 768-dim) as `claude-memory-plugin` so the vector space and operator infrastructure are consistent.

## Reference Files

| File | Purpose |
|------|---------|
| `references/qdrant-client.md` | Qdrant HTTP API reference for SBR. Collection creation, point upsert, vector search. Runnable curl examples. |
| `references/sbr-payload-schema.yaml` | Authoritative payload schema for every SBR point. |
| `references/usage-patterns.md` | Query patterns for agents: similarity thresholds, result interpretation, fallback behavior when SBR is empty or unreachable. |

## How Ingestion Works (Producer Side)

Ingestion is performed by `scripts/ingest-sbr.sh` in the conductor-plugin repo. The script:

1. Reads the current project's `conductor-state.json`.
2. Iterates `gemini_validations[]`. For each entry with `verdict == "PASS"` and `completion_pct >= 80`:
   - Looks up the matching `handoff_history[]` entry by phase + step + agent. Skips with a logged warning if no handoff record exists.
   - Builds a candidate point per the payload schema in `references/sbr-payload-schema.yaml`.
   - Sanitizes content using deterministic regex (no LLM call): redacts emails, strips absolute home/system paths, drops candidates that mention `T2-Confidential` or `T3-Restricted`.
   - Computes a SHA-256 content hash and uses it as the Qdrant point ID. Re-running the script is therefore idempotent — already-ingested content is upserted in place, not duplicated.
3. Generates an embedding for `prompt_text` via Ollama (`POST http://localhost:11434/api/embeddings`, model `nomic-embed-text`).
4. Upserts the point to Qdrant (`PUT http://localhost:6333/collections/sbr/points`).
5. Updates `conductor-state.sbr_state` with run results (count ingested, count skipped, last status).

If Qdrant or Ollama is unreachable, the script fails fast with a clear message and sets `sbr_state.last_run_status` accordingly. Workflows are not crashed — retrospective treats SBR ingest as best-effort.

## How Retrieval Works (Consumer Side)

Agents query SBR directly via Qdrant HTTP (no MCP wrapper):

1. Generate an embedding for the natural-language query using the same Ollama model.
2. POST `http://localhost:6333/collections/sbr/points/search` with the query vector, `limit`, and optional `filter` (by `agent`, `project`, or `domain`).
3. Apply the consumer's similarity threshold (default 0.75 — see `references/usage-patterns.md` for guidance).
4. For each result above threshold, return `spec_summary` + `outcome_validation_id` + similarity. Only retrieve the full `prompt_text` when the operator or downstream agent explicitly asks for the prompt body.

Detailed curl/HTTP examples for both the agent-side query path and the ingestion path are in `references/qdrant-client.md`.

## Key Rules

1. **Direct Qdrant HTTP only** — do not call `memory_store` / `memory_recall` for the `sbr` collection. Those tools manage their own collections.
2. **PASS-only ingestion** — `verdict == "PASS"` and `completion_pct >= 80`. FAIL/PARTIAL are not stored.
3. **Idempotent upsert** — SHA-256 of the canonicalized prompt + agent + project becomes the point ID. Re-runs do not duplicate.
4. **Sanitization is non-negotiable** — every candidate point must pass the sanitization filters in `scripts/ingest-sbr.sh` before reaching Qdrant. Filters are deterministic regex; no LLM judgment loop.
5. **Standalone** — the SBR payload contains only fields the skill itself defines. It does not reference KU/KI phrases, project_signature centroids, or agent card metadata.
6. **Graceful degradation** — when Qdrant or Ollama is down, both the ingestion script and the retrieval path return an honest error. Callers fall back to operating without prior-example context.
