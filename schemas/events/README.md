# Event Schemas (REQ-XCT-007)

This directory holds per-source event JSON Schemas used by `kernel.stream.handle_event` to validate stream-mode event payloads at the trust boundary BEFORE schema validation and BEFORE any agent dispatch (the enforcement order is `auth → schema → budget → dispatch` per `API.md §5.handle_event` RC-4 / F-10).

## Convention

One schema per file, named:

```
<source>.<kind>.<version>.schema.json
```

Examples (domain plugins publish these; the kernel does not ship concrete event schemas):

- `edr.alert.v1.schema.json` — CLUE EDR alert ingest
- `idp.event.v1.schema.json` — CLUE identity-provider event ingest
- `cron.daily.v1.schema.json` — generic cron tick

Each schema MUST set `$schema` to JSON Schema 2020-12, declare `additionalProperties: false` at the root, and provide a `$id` URI in the bulletproofsoftware-ai namespace.

## Referencing from a subscription

In a `stream-state.schema.json` subscription, the `event_schema_ref` field points at the schema file:

```json
{
  "source": "edr.alerts",
  "kind": "webhook",
  "authentication": { ... },
  "event_schema_ref": "edr.alert.v1.schema.json"
}
```

The kernel resolves the reference relative to the schemas/events/ directory of the consuming plugin (or the kernel, if the schema lives here).

## Versioning

Bump the `vN` suffix on any breaking change to a published schema. Old versions stay in place until all consuming streams have been migrated; the kernel's `kernel.stream.handle_event` returns `KER-SE-002 event schema validation failed` if an inbound event references a no-longer-shipped schema.

## What the kernel ships

Three baseline envelope schemas land in Phase 3 alongside the stream-mode primitive scripts (`lib/stream/`):

| Schema | Purpose | Used by |
|--------|---------|---------|
| `webhook-event.schema.json` | Generic webhook trigger envelope when a domain has not declared a specific schema | Fallback for `subscriptions[].kind == "webhook"` |
| `cron-event.schema.json` | Scheduled / polling trigger envelope synthesized by n8n Schedule Trigger | `subscriptions[].kind == "cron"` and `kind == "polling"` |
| `audit-event.schema.json` | Payload contract for events POSTed by the `n8n-audit-emitter.json` template into `kernel.audit_emit` (RC-12 / F-12 parent_id composition enforced via `pattern`) | All n8n workflows using the audit-emitter Code-node template |

These envelopes are intentionally **minimal**. Concrete event schemas (e.g., `edr.alert.v1.schema.json`, `idp.event.v1.schema.json`) are published by domain plugins and reference the appropriate envelope where useful (typically by `allOf` composition).

Phase 4+ introduces the first SOC event schemas (CLUE) in the CLUE plugin's `schemas/events/`, not in the kernel. The convention and three envelopes here are the contract every domain plugin builds against.
