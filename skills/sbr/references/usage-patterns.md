# SBR Usage Patterns

This reference is for agents and operators **consuming** the SBR. For producer-side ingestion, see `scripts/ingest-sbr.sh` in the conductor-plugin repo.

## Query Vocabulary

Agents query SBR with **a short natural-language description of the upcoming work**, not with the literal task ID or BRD requirement. Good queries describe **what the spec is asking for**, not the project state.

| Bad query | Better query |
|-----------|--------------|
| `REQ-027` | `Add HMAC-verified webhook endpoint for billing events with idempotency` |
| `Fix the thing in billing.ts` | `Refactor billing webhook handler to deduplicate by event ID` |
| `Implement task 14` | `Implement audit log retention policy with 90-day rolling window` |

SBR is similarity-keyed. Query text closer to the prompt that would be sent to the implementing agent will retrieve better matches.

## Similarity Threshold Guidance

Cosine similarity in [0, 1]. Empirical thresholds:

| Threshold | Recommended use |
|-----------|-----------------|
| `>= 0.85` | Near-duplicate prior work. Treat as a high-fidelity template. Inspect prompt_text and apply with minimal adaptation. |
| `0.75 – 0.85` | Strong analogy. Treat as a reference pattern; copy structure but redesign details. **Default cutoff for "useful match."** |
| `0.65 – 0.75` | Weak analogy. Show to the operator as "loosely related prior work"; do not auto-apply. |
| `< 0.65` | Probably noise. Do not surface. |

The Qdrant `search` call accepts `score_threshold`. Set it to `0.65` server-side and apply the finer-grained interpretation in the caller. Lowering the server-side threshold below 0.65 wastes payload bytes on near-noise.

## Default Filters

Apply these filters on every search unless the operator explicitly opts out:

```json
"filter": {
  "must": [
    { "key": "verdict", "match": { "value": "PASS" } }
  ]
}
```

`verdict == PASS` is structurally guaranteed by the ingest script today, but the filter is included defensively in case future versions of the schema permit additional verdict values.

For agent-scoped retrieval (recommended default for builder/architect):

```json
{ "key": "agent", "match": { "value": "conductor-builder" } }
```

For project-scoped retrieval (start with own_only, fall back to global if no matches):

```json
{ "key": "project", "match": { "value": "my-project" } }
```

## Two-Pass Retrieval Pattern (own_plus_global)

Default recommended retrieval strategy when project_filter is in play:

1. **Pass 1 — own project, strict threshold.** Filter `project == <current_project>`, limit 5, score_threshold 0.75.
2. **Pass 2 — global, looser threshold.** No project filter, limit 5, score_threshold 0.70.
3. **Merge.** Pass 1 results outrank Pass 2 results. Deduplicate by point ID. Truncate to the caller's overall limit.

This biases retrieval toward in-project precedent while still surfacing strong cross-project patterns when the current project lacks prior examples.

## Cold Start

A fresh project will have zero PASSed validations ingested. SBR search will return empty arrays. The recommended caller behavior:

```
results = sbr_search(query)
if len(results) == 0:
    # Cold start. Proceed without prior-example context.
    # Optionally log to conductor-state that SBR was empty.
    continue
elif len(results) > 0:
    # Inject the top result's spec_summary + outcome_validation_id into the
    # consuming agent's planning context. Do NOT inject the full prompt_text
    # unless explicitly required — keeps context lean.
```

Never block on SBR being empty. SBR is an enhancement, not a gate.

## Interpreting Results

Each result carries:

| Field | Use |
|-------|-----|
| `similarity` (score) | Confidence in the match. Apply the thresholds above. |
| `spec_summary` | Human-readable distillation. Show this in agent reasoning, not the full prompt_text. |
| `outcome_validation_id` | Traceability. Lets the operator audit which Gemini validation proved this example worked. |
| `completion_pct` | Quality marker. Prefer 90+ over 80+ when sorting by quality. |
| `agent` | Originating agent. Useful for filtering or weighting. |
| `tier` | Workflow tier. A STANDARD-tier example may be over-specified for a TRIVIAL task. |
| `domain` | Domain tag. Helps confirm the example is actually relevant. |
| `file_paths_changed` | Lets the caller assess code-locality. |

When citing a retrieved example to the operator or in agent output, **always include the `outcome_validation_id`** so the citation is auditable.

## Failure Modes

| Symptom | Cause | Caller action |
|---------|-------|---------------|
| Connection refused on `localhost:6333` | Qdrant not running | Proceed without SBR. Log a one-line note. |
| Connection refused on `localhost:11434` | Ollama not running | Proceed without SBR. Log a one-line note. |
| Embedding response missing `embedding` field | Ollama model not pulled — run `ollama pull nomic-embed-text` | Same as above. |
| Search returns 404 | Collection does not exist yet | Treat as empty result. SBR has not been seeded. |
| Vector dimension mismatch on upsert | Embedding model changed between ingest and query | Operator-level — purge and re-ingest with the current model. |

In all failure modes, the consumer continues without SBR. SBR adds value when present; its absence must not break a workflow.

## Privacy & Sanitization Expectations

Consumers can assume the following about every retrieved point because the ingest script enforces them:

- No raw email addresses (replaced with `[REDACTED]`)
- No absolute home-directory paths (`/Users/...`, `/home/...`) — replaced with `~/`
- No `T2-Confidential` or `T3-Restricted` content (those prompts are excluded entirely)
- No API keys, base64 blobs > 100 chars, or `.env` fragments

Consumers should **not** add their own sanitization step on the way out. If a retrieved point contains anything sensitive-looking, that's an ingest bug — file it against `scripts/ingest-sbr.sh`, not a downstream filter.

## What SBR Is Not

SBR is **not** a rule book. If your decision needs a deterministic rule ("dual approval above $5M TIV"), query `process-knowledge`, not SBR.

SBR is **not** session memory. If you need to recall what the operator said two turns ago, use `mcp__claude-memory__memory_recall` against the default `long_term` collection.

SBR is **not** an authority. A retrieved example proves the pattern worked for a prior spec. It does not prove it is correct for your current spec. Always read the retrieved `spec_summary` critically and adapt.
