# Qdrant HTTP Client Reference for SBR

The SBR skill talks directly to Qdrant over HTTP. This reference documents every endpoint, request shape, and response shape the skill uses. All examples are runnable as-is against a default local Qdrant install (`docker run -p 6334:6333 qdrant/qdrant` or the existing `your Qdrant compose directory` stack used by `claude-memory-plugin`).

## Endpoints Used

| Operation | Method | Path |
|-----------|--------|------|
| Check collection exists | `GET` | `/collections/sbr` |
| Create collection | `PUT` | `/collections/sbr` |
| Upsert points | `PUT` | `/collections/sbr/points` |
| Search points | `POST` | `/collections/sbr/points/search` |
| Retrieve point by ID | `POST` | `/collections/sbr/points` (with `ids: [...]`) |
| Delete point by ID | `POST` | `/collections/sbr/points/delete` |

Embedding generation uses Ollama, not Qdrant:

| Operation | Method | URL |
|-----------|--------|-----|
| Generate embedding | `POST` | `http://localhost:11434/api/embeddings` |

## Embedding Pipeline (Ollama)

Every prompt_text and every query string must be converted to a 768-dim vector via Ollama's `nomic-embed-text` model. The collection schema below enforces 768 dimensions; using a different model will produce vectors of the wrong length and Qdrant will refuse the upsert.

```bash
curl -s -X POST http://localhost:11434/api/embeddings \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "nomic-embed-text",
    "prompt": "Implement a REST API for billing webhook ingestion with HMAC verification"
  }'
```

Response (truncated):

```json
{
  "embedding": [-0.0234, 0.1117, 0.0451, ...]
}
```

The `embedding` array is exactly 768 floats. Extract it with `jq -r '.embedding'`.

## Collection Creation (Idempotent)

Run this before first ingestion. Subsequent runs of the ingest script should `GET /collections/sbr` first; if the collection exists, skip creation.

```bash
curl -s -X PUT http://localhost:6334/collections/sbr \
  -H 'Content-Type: application/json' \
  -d '{
    "vectors": {
      "size": 768,
      "distance": "Cosine"
    }
  }'
```

Expected response:

```json
{ "result": true, "status": "ok", "time": 0.001 }
```

If the collection already exists, Qdrant returns `400 Bad Request` with a message like `Collection 'sbr' already exists`. The ingest script treats this as success.

## Point Upsert

A single upsert call accepts an array of points. Each point has an `id`, a `vector`, and a `payload` matching `sbr-payload-schema.yaml`.

```bash
curl -s -X PUT http://localhost:6334/collections/sbr/points \
  -H 'Content-Type: application/json' \
  -d '{
    "points": [
      {
        "id": "a3f1e9b2c4d56789a3f1e9b2c4d56789a3f1e9b2c4d56789a3f1e9b2c4d56789",
        "vector": [-0.0234, 0.1117, 0.0451],
        "payload": {
          "sbr_id": "sbr_2026-05-11T15:00:00Z_gv_20260511_007",
          "agent": "conductor-builder",
          "project": "my-project",
          "prompt_text": "Implement REST endpoint /webhooks/billing with HMAC verification per Stripe spec...",
          "spec_summary": "Add HMAC-verified billing webhook endpoint. Required acceptance: signature check, 5-minute timestamp tolerance, idempotency.",
          "outcome_validation_id": "gv_20260511_007",
          "completion_pct": 95,
          "verdict": "PASS",
          "ingested_at": "2026-05-11T15:00:00Z",
          "tier": "STANDARD",
          "file_paths_changed": ["src/webhooks/billing.ts", "tests/webhooks/billing.test.ts"]
        }
      }
    ]
  }'
```

Notes:

- The `id` field accepts ONLY a u64 integer or a UUID string. Raw 64-character SHA-256 hex is rejected with HTTP 400. The SBR ingestion script computes `sha256(prompt_text + "|" + agent + "|" + project)` and then formats the first 32 hex chars as a UUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`). This preserves idempotency — same content yields the same UUID, so re-ingesting overwrites in place rather than duplicating.
- The Qdrant response includes `result.operation_id` and `result.status`. The ingest script checks `result.status == "acknowledged"`.

## Vector Search

The retrieval path used by agents at decision time.

```bash
# 1. Get embedding for the natural-language query
QUERY_VEC=$(curl -s -X POST http://localhost:11434/api/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"nomic-embed-text","prompt":"Add webhook receiver with signature verification"}' \
  | jq -c '.embedding')

# 2. Search the sbr collection
curl -s -X POST http://localhost:6334/collections/sbr/points/search \
  -H 'Content-Type: application/json' \
  -d "{
    \"vector\": $QUERY_VEC,
    \"limit\": 5,
    \"with_payload\": true,
    \"score_threshold\": 0.75,
    \"filter\": {
      \"must\": [
        { \"key\": \"verdict\", \"match\": { \"value\": \"PASS\" } }
      ]
    }
  }"
```

Response shape:

```json
{
  "result": [
    {
      "id": "a3f1e9b2c4d56789...",
      "version": 0,
      "score": 0.842,
      "payload": {
        "sbr_id": "sbr_2026-05-11T15:00:00Z_gv_20260511_007",
        "agent": "conductor-builder",
        "project": "my-project",
        "spec_summary": "Add HMAC-verified billing webhook endpoint...",
        "outcome_validation_id": "gv_20260511_007",
        "completion_pct": 95,
        ...
      }
    }
  ],
  "status": "ok",
  "time": 0.012
}
```

`score` is the cosine similarity in [0, 1]. Apply the threshold described in `usage-patterns.md`.

### Filtering by Agent or Project

For agent-scoped retrieval ("only show me prior builder specs from this project"):

```json
{
  "vector": [...],
  "limit": 5,
  "with_payload": true,
  "filter": {
    "must": [
      { "key": "verdict",  "match": { "value": "PASS" } },
      { "key": "agent",    "match": { "value": "conductor-builder" } },
      { "key": "project",  "match": { "value": "my-project" } }
    ]
  }
}
```

To allow cross-project results but bias toward own project, do two searches and rank the operator's own project results above global results in the caller.

## Retrieving a Full Point by ID

The search endpoint returns truncated payloads when `with_payload` lists specific keys. To fetch the full prompt body for one result:

```bash
curl -s -X POST http://localhost:6334/collections/sbr/points \
  -H 'Content-Type: application/json' \
  -d '{
    "ids": ["a3f1e9b2c4d56789..."],
    "with_payload": true,
    "with_vector": false
  }'
```

This returns the same payload shape, including `prompt_text`.

## Health Checks

Before ingestion or retrieval, the skill (or the ingest script) should perform a fast liveness check:

```bash
# Qdrant
curl -s -o /dev/null -w '%{http_code}' http://localhost:6334/collections   # expect 200
# Ollama
curl -s -o /dev/null -w '%{http_code}' http://localhost:11434/api/tags     # expect 200
```

If either returns a non-2xx or fails to connect, set `sbr_state.last_run_status` to `qdrant_unreachable` or `ollama_unreachable` respectively and exit with status code 0 (best-effort — do not crash the parent workflow).

## Connection Reuse Notes

For high-volume ingestion (e.g., backfilling many workflows), Qdrant supports a single bulk upsert call carrying hundreds of points. The ingest script batches in groups of 32 to stay within reasonable request sizes.

For agent retrieval, a single embedding call + a single search call is the steady-state shape. No batching needed.

## Error Modes

| HTTP status | Meaning | Skill behavior |
|-------------|---------|----------------|
| 200 | Success | Continue |
| 400 | Bad request — usually a vector dimension mismatch or malformed payload | Log full response body, increment `points_skipped_sanitization`, continue with next point |
| 404 | Collection missing on search | Skill should not happen in steady state (ingest creates the collection); on first read, treat as "no results" |
| 409 | Conflict (rare — e.g., concurrent collection create) | Treat as success when creating the collection |
| 500 / 502 / 503 | Qdrant internal or upstream failure | Set `last_run_status = qdrant_unreachable`, abort the run, do not crash workflow |
| Connection refused | Qdrant or Ollama not running | Set the appropriate `*_unreachable` status, exit 0 |
