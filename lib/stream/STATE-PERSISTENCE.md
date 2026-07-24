# Stream-State Persistence (REQ-KER-012)

This document defines how `kernel.stream.state_get` / `kernel.stream.state_mutate` (API.md §5) persist long-horizon stream-mode state. It accompanies `lib/stream/stream-state-{get,mutate}.sh`.

## Decision: Qdrant payload-only storage in dedicated collection

Stream-mode state is stored in a **single dedicated Qdrant collection** named `kernel_stream_state`. One point per stream, keyed by a deterministic UUID derived from `stream_id` (the n8n workflow id).

### Why a dedicated collection (and not claude-memory-mcp)

REQ-CLU-033 (Phase 4 prep) calls out that **claude-memory-mcp does not support custom collections** — it is opinionated around its own retrieval surfaces (episode, learning, procedure, trajectory, graph, etc.). Stream state is operational, structured, and routinely mutated — it does not belong in semantic memory:

- Lifetime mismatch: stream state lives for the life of the n8n workflow (potentially indefinite); memory episodes are time-decayed.
- Mutation cadence: stream state mutates per event; memory episodes are write-once.
- Schema rigidity: stream state validates against `schemas/stream-state.schema.json`; memory payloads are free-form.
- Read pattern: stream state is fetched by exact id; memory recall is similarity-keyed.

So the kernel owns its own collection in the same Qdrant instance, side-by-side with claude-memory-mcp's collections. This keeps deployment surface unchanged (one Qdrant) while preserving separation of concerns.

### Why payload-only (1-dim dummy vector)

Stream state is queried by stream_id (exact key), never by similarity. Qdrant nonetheless requires every point to carry a vector with the collection's declared dimensionality. We:

- Declare the collection with `vectors: { size: 1, distance: "Dot" }`
- Upsert every point with `vector: [0.0]`
- Store the full state document in `payload`
- Retrieve via `GET /collections/kernel_stream_state/points/{id}`

This costs negligible storage per point and avoids the embedding pipeline (no Ollama dependency for state ops). If a future requirement needs semantic search across stream-state documents (e.g., "find streams matching this incident signature"), the migration path is:

1. Bump collection to `size: 768, distance: "Cosine"` (nomic-embed-text)
2. Backfill embeddings via batch script over existing payloads
3. The `state_get` / `state_mutate` API surface does not change

## Collection lifecycle

`stream-state-mutate.sh` is responsible for collection creation on first use:

```bash
PUT /collections/kernel_stream_state
{ "vectors": { "size": 1, "distance": "Dot" } }
```

HTTP 200 = created. HTTP 409 = already exists. Both are accepted.

`stream-state-get.sh` does NOT create the collection; missing collection plus missing point both return `KER-SS-001 stream not found`.

## Point ID derivation

Qdrant point ids must be unsigned ints or UUIDs. n8n workflow ids are typically opaque strings (alphanumeric). The kernel computes a UUIDv5 from the stream_id:

```python
point_id = uuid.uuid5(uuid.NAMESPACE_OID, f"kernel_stream_state:{stream_id}")
```

This is deterministic — the same stream_id always maps to the same point_id, so `state_get` and `state_mutate` round-trip correctly without any external mapping table. The original stream_id is preserved in `payload._kernel_stream_id_raw` for human-readable inspection.

## Mutation semantics

`state_mutate` accepts an RFC-6902 JSON Patch and applies it server-side (in the Python helper inside the script). If `jsonpatch` is installed, full RFC-6902 is supported. Otherwise, a minimal stdlib fallback covers:

- `replace` at root path `""` (full-state replacement / bootstrap)
- `add /key`, `add /a/b` (nested object set)
- `add /list/-` (append to list — used for `spawned_workflow_ids[]`)
- `remove /key` (delete a top-level field)

Operators running the scripts in production should `pip install jsonpatch` to enable the full patch surface, or restrict callers to the supported subset.

After mutation, the resulting state is **schema-validated** against `schemas/stream-state.schema.json` via the `jsonschema` library if available. Validation failure returns `KER-SS-002` and the upsert is NOT performed (current state is preserved).

## Audit emissions

| Operation | Audit event | Payload |
|-----------|-------------|---------|
| `state_get` | none | (read-only operations are not audited by default) |
| `state_mutate` | `stream.state_mutate` | `{ stream_id, mutation_size }` |

The mutation contents themselves are deliberately **not** logged to the audit detail — the post-mutation state is the source of truth, and logging the patch would duplicate that data and risk leaking secrets if any are temporarily embedded in `running_counters` or `consumed_offsets`.

## Concurrency

This v0.1.0 implementation uses optimistic read-then-write. If two concurrent mutators race, the later write wins (no version vector). Phase 7 hardening (adversarial defense) is expected to introduce CAS semantics via a `version` field in `state.schema_version` or a separate `_kernel_version` counter; Qdrant supports conditional updates that can drive this.

For Phase 3, callers that mutate the same stream concurrently must serialize externally (e.g., a single n8n workflow instance owns its own state).

## Required tools

- `curl` (always)
- `python3` >= 3.9 (always)
- `jsonschema` Python module (optional, recommended)
- `jsonpatch` Python module (optional, expands mutation surface)

Install in operator environment:

```bash
pip3 install jsonschema jsonpatch
```

## Failure modes

| Symptom | Error code | Resolution |
|---------|-----------|-----------|
| Qdrant unreachable on first ensure_collection | `KER-SI-001` | Verify `QDRANT_URL` (default `http://localhost:6333`; falls back to `:6334`). Confirm `docker compose ps` in `your Qdrant compose directory`. |
| state_get on non-existent stream | `KER-SS-001` | Stream was never initialized via `stream-init.sh`, or stream_id is incorrect. |
| state_mutate fails schema validation | `KER-SS-002` | Inspect the produced state document; the mutation produced something that violates `stream-state.schema.json`. The previous state is preserved. |
| state_mutate succeeds but produces invalid downstream | (advisory only) | Without `jsonschema` installed, validation is best-effort. Install `jsonschema` to catch these. |
