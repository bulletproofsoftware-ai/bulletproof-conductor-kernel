# Test — Schema Validation (Workflow + Stream State)

**Implements**: kernel-api.md §7 — `workflow-state.schema.json` and `stream-state.schema.json` base contracts.

## Goal

Verify that the kernel's base state schemas validate representative fixtures and reject malformed ones. v0.1.0 ships prose; Phase 2+ ships a programmatic harness.

## Workflow-state schema fixtures

### Positive fixtures (MUST validate)

1. **Minimal v3.0**:
   ```json
   {
     "schema_version": "3.0",
     "project_name": "demo",
     "current_phase": { "number": 0, "name": "init" },
     "current_step": "task1",
     "task_queue": [],
     "completed_tasks": [],
     "verification_status": {}
   }
   ```

2. **Legacy v2.0** (missing `domain` and `domain_extensions` — must validate per REQ-CDV-002):
   Same as (1) but `schema_version: "2.0"` and no `domain` field.

3. **Live v1.0** (the in-flight conductor-state.json shape from the upstream conductor-plugin domain):
   Same as (1) but `schema_version: "1.0"`.

4. **With domain_extensions**:
   Adds `{"domain_extensions": {"investigation_id": "INV-123", "alert_ids": ["alert-1"]}}` — kernel must validate without inspecting the contents.

### Negative fixtures (MUST reject)

1. Missing `project_name` → fail (`required`).
2. `verification_status.post_qa = "invalid_verdict"` → fail (enum violation).
3. Top-level extra property `arbitrary_key: "x"` → fail (`additionalProperties: false` per RC-13 / F-18).
4. `schema_version: "4.0"` → fail (not in enum).

## Stream-state schema fixtures

### Positive (MUST validate)

1. **Minimal**:
   ```json
   {
     "schema_version": "3.0",
     "domain": "soc",
     "stream_id": "wf-1",
     "subscriptions": [
       {
         "source": "edr.alerts",
         "kind": "webhook",
         "authentication": { "kind": "hmac", "secret_ref": "vault://x", "verification_field": "header.X-Signature" }
       }
     ]
   }
   ```

### Negative (MUST reject)

1. Subscription with `authentication.kind: "none"` and `audit_warning_acknowledged: false` → at validation time the schema accepts both forms; the kernel's `stream.init` rejects with `KER-SI-005` (RC-4 / F-10) — schema layer alone is insufficient, kernel logic enforces.
2. Missing `subscriptions[].authentication` → fail (required).
3. Top-level extra property → fail (`additionalProperties: false`).

## v0.1.0 procedure

Manual validation using `ajv` or Python `jsonschema`:

```bash
python3 -c "
import json
from jsonschema import validate
schema = json.load(open('schemas/workflow-state.schema.json'))
fixture = json.load(open('tests/fixtures/workflow-state-minimal.json'))
validate(fixture, schema)
print('OK')
"
```

Fixture files are NOT shipped at v0.1.0 — Phase 2 builder authors `tests/fixtures/*.json` alongside the live harness.

## Pass criteria

All positive fixtures validate; all negative fixtures fail with the documented error mode.
