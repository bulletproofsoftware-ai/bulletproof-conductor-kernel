# Stream-Mode Integration Test (Phase 3)

Validates the kernel stream-mode primitives end-to-end against the live n8n instance at `http://localhost:5679` and the Qdrant instance at `http://localhost:6333/6334`. Each test step is annotated **AUTO** (runs in this script harness) or **MANUAL** (requires an interactive Claude Code MCP context with n8n-mcp credentials configured).

The harness performs:
- AUTO steps via direct invocation of `lib/stream/*.sh`
- MANUAL steps surface a clear `manual_dispatch:true` marker in their output so the operator can complete them in a follow-up Claude Code session with n8n-mcp credentials

## Setup

```bash
export KERNEL_ROOT=<path-to-this-kernel-checkout>
export AUDIT_DB_OVERRIDE=<path-to-governance-plugin>/state/audit.db
# Operators with direct n8n access for full automation:
# export N8N_API_KEY=<api key from the n8n UI>
# export N8N_URL=http://localhost:5679
```

Required tools:
- `bash`, `python3` (>=3.9), `curl`, `sqlite3`
- Optional: `pip3 install jsonschema jsonpatch` (expands schema validation surface)

## Test Step 1 — stream-init (dry-run + live)

### 1a. AUTO: dry-run validates the init config

```bash
cat <<'CFG' | "$KERNEL_ROOT/lib/stream/stream-init.sh" --stdin --dry-run
{
  "domain": "test",
  "subscriptions": [
    {
      "source": "test.webhook",
      "kind": "webhook",
      "authentication": {
        "kind": "hmac",
        "secret_ref": "env://TEST_HMAC_SECRET",
        "verification_field": "header.X-Signature",
        "algorithm": "hmac-sha256"
      },
      "event_schema_ref": "webhook-event.schema.json"
    }
  ],
  "schema_extension": { "type": "object", "properties": {} },
  "budget": {
    "per_event": { "max_input_tokens": 8000, "max_output_tokens": 4000, "max_cost_usd": 0.25 },
    "per_stream_hour": { "max_total_cost_usd": 5.00, "max_total_dispatches": 100 }
  },
  "stream_name": "kernel-test-stream-001"
}
CFG
```

**Expected**: JSON `{ ok: true, dry_run: true, would_create: {...}, audit_session_id: "<uuid>" }`. Subscription auth is reported as kind only (no secret material). Audit event `stream.init.attempt` lands in `audit.db`.

**Status**: AUTO — runnable in this session.

### 1b. AUTO: KER-SI-005 trigger (auth kind=none without acknowledgment)

```bash
cat <<'CFG' | "$KERNEL_ROOT/lib/stream/stream-init.sh" --stdin --dry-run
{
  "domain": "test",
  "subscriptions": [
    {
      "source": "test.webhook",
      "kind": "webhook",
      "authentication": { "kind": "none" }
    }
  ],
  "schema_extension": {},
  "budget": {
    "per_event": { "max_input_tokens": 1, "max_output_tokens": 1, "max_cost_usd": 0.01 },
    "per_stream_hour": { "max_total_cost_usd": 0.10, "max_total_dispatches": 1 }
  }
}
CFG
```

**Expected**: `{ ok: false, error_code: "KER-SI-005", ... }`. Script exits 1.

### 1c. AUTO: KER-SI-006 trigger (missing budget)

```bash
cat <<'CFG' | "$KERNEL_ROOT/lib/stream/stream-init.sh" --stdin --dry-run
{
  "domain": "test",
  "subscriptions": [
    {
      "source": "test.webhook",
      "kind": "webhook",
      "authentication": { "kind": "none", "audit_warning_acknowledged": true }
    }
  ]
}
CFG
```

**Expected**: `{ ok: false, error_code: "KER-SI-006", ... }`.

### 1d. AUTO (via n8n CLI fallback): live deployment

The POC workflow was deployed during Phase 3 closeout via the n8n container's
import CLI, yielding workflow_id `audit-emitter-poc`:

```bash
python3 -c 'import json; wf=json.load(open("workflows/_shared/audit-emitter-poc.json"));
  imp={"id":"audit-emitter-poc","name":wf["name"],"nodes":wf["nodes"],
       "connections":wf["connections"],"settings":wf["settings"],"active":False};
  json.dump(imp, open("/tmp/poc.json","w"))'
docker cp /tmp/poc.json n8n:/tmp/poc.json
docker exec n8n n8n import:workflow --input=/tmp/poc.json
```

Output: `Successfully imported 1 workflow.`
Verification: `docker exec n8n n8n list:workflow | grep audit-emitter-poc` returns the row.

**Alternative path (MANUAL via Claude Code MCP)**: in a Claude Code session with
n8n-mcp configured for localhost (note: n8n-mcp blocks localhost by default
via `SSRF protection: Localhost access is blocked in strict mode`; operator
must reconfigure or use the CLI fallback above), invoke `n8n_create_workflow`
with the POC body. Per RC-9 the kernel does not store credentials — the n8n
API key lives only in n8n-mcp's operator config.

## Test Step 2 — stream-handle-event (auth-fail and success)

### 2a. AUTO: auth failure drops to DLQ

```bash
TMP=$(mktemp -d)
cat > $TMP/event.json <<'E'
{ "source": "test.webhook", "received_at": "2026-05-12T00:00:00Z", "body": {"sample": "data"} }
E
cat > $TMP/auth.json <<'A'
{ "header.X-Signature": "sha256=deadbeef-wrong-sig" }
A
cat > $TMP/sub.json <<'S'
{
  "subscription": {
    "source": "test.webhook",
    "kind": "webhook",
    "authentication": {
      "kind": "hmac",
      "secret_ref": "env://TEST_HMAC_SECRET",
      "verification_field": "header.X-Signature",
      "algorithm": "hmac-sha256"
    }
  }
}
S
# Combine into stdin form
python3 -c "
import json
e = json.load(open('$TMP/event.json'))
a = json.load(open('$TMP/auth.json'))
s = json.load(open('$TMP/sub.json'))
print(json.dumps({'event': e, 'auth': a, 'subscription': s['subscription']}))
" | env TEST_HMAC_SECRET='correct-secret' \
    "$KERNEL_ROOT/lib/stream/stream-handle-event.sh" --stream-id test-stream --stdin
```

**Expected**: `{ ok: false, error_code: "KER-SE-004", message: "event_auth_failed: hmac-sha256 signature mismatch — event dropped to DLQ" }`. Audit event `stream.event_auth_failure` lands in audit.db.

### 2b. AUTO: schema validation order — auth still rejected first

(Same as 2a but with `event_schema_ref: nonexistent.schema.json` in subscription.) Auth fails BEFORE schema lookup is attempted, so KER-SE-004 is still the result. This is the critical RC-4 / F-10 ordering invariant.

### 2c. AUTO: success path with correct HMAC

```bash
SECRET='correct-secret'
EVENT='{"source":"test.webhook","received_at":"2026-05-12T00:00:00Z","body":{"sample":"data"}}'
# Canonical body for HMAC = the event JSON as the script computes it (sorted keys, no spaces)
SIG=$(python3 -c "
import hmac, hashlib, json
body = json.dumps(json.loads('$EVENT'), sort_keys=True, separators=(',', ':'))
print(hmac.new(b'$SECRET', body.encode(), hashlib.sha256).hexdigest())
")
python3 -c "
import json
print(json.dumps({
    'event': json.loads('$EVENT'),
    'auth': {'header.X-Signature': '$SIG'},
    'subscription': {
        'source': 'test.webhook',
        'kind': 'webhook',
        'authentication': {
            'kind': 'hmac',
            'secret_ref': 'env://TEST_HMAC_SECRET',
            'verification_field': 'header.X-Signature',
            'algorithm': 'hmac-sha256'
        }
    }
}))
" | env TEST_HMAC_SECRET="$SECRET" \
    "$KERNEL_ROOT/lib/stream/stream-handle-event.sh" --stream-id test-stream --stdin
```

**Expected (without N8N_API_KEY)**: `{ ok: true, manual_dispatch: true, ... }`. Auth verified, schema skipped (no event_schema_ref), audit event `stream.event_handled` lands with `status: "validated_only"`.

**Expected (with N8N_API_KEY)**: `{ ok: true, stream_id: "...", latency_ms: N, auth_kind: "hmac" }` and the n8n workflow fires with this event as the body.

### 2d. MANUAL: live trigger via n8n-mcp

In a Claude Code session: `n8n_trigger_webhook_workflow` against the stream_id from step 1d, with the same event body. Verify the workflow fires and the audit-emitter Code+HTTP nodes emit an audit row.

## Test Step 3 — Audit Bus Verification

### 3a. AUTO: audit rows present after steps 1+2

```bash
sqlite3 $AUDIT_DB_OVERRIDE "
  SELECT event_type, COUNT(*) FROM audit_events
  WHERE timestamp >= datetime('now', '-1 hour')
    AND event_type LIKE 'stream.%'
  GROUP BY event_type;
"
```

**Expected** (at minimum, given steps 1a + 2a + 2c executed):
- `stream.init.attempt` >= 1
- `stream.event_auth_failure` >= 1
- `stream.event_handled` >= 1

### 3b. MANUAL: audit row from POC workflow

After step 1d + 2d, verify the POC workflow's audit row landed:

```bash
sqlite3 $AUDIT_DB_OVERRIDE "
  SELECT timestamp, event_type, detail
  FROM audit_events
  WHERE event_type = 'memory.skill_discovery.cron_completed'
  ORDER BY timestamp DESC LIMIT 1;
"
```

**Expected**: A row whose `detail` payload contains:
- `parent_id` matching pattern `<workflow_id>:<node_id>` (F-12 enforced)
- `trace_id` matching the one generated by the workflow's Skill Discovery node
- `tool_calls` array showing the three operations recorded

**Why MANUAL**: Requires the POC workflow to have been deployed (step 1d) and the n8n container to be reachable from the kernel audit endpoint. Until governance-plugin Phase N ships the `http://localhost:5681/audit/emit` listener, operators must use the `executeCommand` fallback documented in `templates/n8n-audit-emitter.json` _integration_notes.

## Test Step 4 — State Persistence

### 4a. AUTO: state_mutate creates a stream-state document

```bash
"$KERNEL_ROOT/lib/stream/stream-state-mutate.sh" \
  --stream-id test-stream-mutate-001 \
  --mutation '[{"op":"replace","path":"","value":{"schema_version":"3.0","domain":"test","stream_id":"test-stream-mutate-001","subscriptions":[{"source":"x","kind":"webhook","authentication":{"kind":"none","audit_warning_acknowledged":true}}],"running_counters":{"events_received":0}}}]'
```

**Expected**: `{ ok: true, stream_id: "test-stream-mutate-001", state: {...} }`. Qdrant collection `kernel_stream_state` exists; one point present.

### 4b. AUTO: state_get retrieves what was stored

```bash
"$KERNEL_ROOT/lib/stream/stream-state-get.sh" --stream-id test-stream-mutate-001
```

**Expected**: The state document JSON.

### 4c. AUTO: state_get on non-existent → KER-SS-001

```bash
"$KERNEL_ROOT/lib/stream/stream-state-get.sh" --stream-id never-existed-xxx
```

**Expected**: `{ ok: false, error_code: "KER-SS-001", ... }`, exit 1.

### 4d. AUTO: state_mutate JSON-Patch append (RFC 6902 add /list/-)

```bash
"$KERNEL_ROOT/lib/stream/stream-state-mutate.sh" \
  --stream-id test-stream-mutate-001 \
  --mutation '[{"op":"add","path":"/spawned_workflow_ids","value":[]},{"op":"add","path":"/spawned_workflow_ids/-","value":{"workflow_id":"child-001","spawned_at":"2026-05-12T00:00:00Z"}}]'
```

**Expected**: `{ ok: true, state: { ..., spawned_workflow_ids: [{ workflow_id: "child-001", ... }] } }`.

## Test Step 5 — Health Metrics

### 5a. AUTO: health derived from audit-bus only

```bash
"$KERNEL_ROOT/lib/stream/stream-health.sh" --stream-id test-stream --window-seconds 3600
```

**Expected (without N8N_API_KEY)**:
```json
{ "ok": true, "manual_n8n": true, "stream_id": "test-stream",
  "health_metrics": {
    "success_rate": 0.5 (or similar — derived from audit events of step 2),
    "avg_latency_ms": null,
    "p99_latency_ms": null,
    "error_rate": ...,
    "throughput_per_min": ...,
    "dlq_depth": 1+,
    "sla_status": "unknown"
  } }
```

**With N8N_API_KEY**: full metrics including latencies, derived from `n8n_list_executions`.

### 5b. MANUAL: health via n8n-mcp

`n8n_list_executions` + `n8n_get_workflow_details` against stream_id from step 1d. Aggregated metrics match what 5a's `--with-n8n-api` path would have returned.

## Test Step 6 — Pause / Resume

### 6a. AUTO: pause records state + emits audit event

```bash
"$KERNEL_ROOT/lib/stream/stream-pause.sh" --stream-id test-stream --reason "integration_test"
```

**Expected (without N8N_API_KEY)**: `{ ok: true, manual_n8n: true, ..., pause_state: { paused: true, paused_by: "operator", ... } }`. Audit event `stream.pause` lands.

### 6b. MANUAL: actual n8n active=false toggle

In Claude Code with n8n-mcp: `n8n_update_partial_workflow` setting `active: false` on the workflow_id. Verify on next `n8n_get_workflow_details` that `active === false`.

### 6c. AUTO: resume audit emission

```bash
"$KERNEL_ROOT/lib/stream/stream-resume.sh" --stream-id test-stream
```

**Expected**: `{ ok: true, manual_n8n: true, ..., resumed_at: "<iso>" }`. Audit event `stream.resume`.

## Test Step 7 — Spawn Workflow (REQ-KER-014)

### 7a. AUTO: spawn produces a workflow-mode state file

```bash
TMP=$(mktemp -d)
cat > $TMP/wfdef.json <<'D'
{
  "domain": "dev",
  "description": "Test workflow spawned from stream",
  "tier": "MINOR",
  "signals": { "complexity": "low" }
}
D
"$KERNEL_ROOT/lib/stream/stream-spawn-workflow.sh" \
  --stream-id test-stream-spawn-001 \
  --workflow-def $TMP/wfdef.json \
  --trigger-event-id evt-001
```

**Expected**:
- A new file at `~/.conductor-kernel/spawned/wfm-<8hex>.json` containing the workflow-mode state with `parent_stream_id: "test-stream-spawn-001"` and `trigger_event_id: "evt-001"`
- Audit event `stream.spawn_workflow` lands
- (Best-effort) state_mutate adds an entry to `test-stream-spawn-001.spawned_workflow_ids[]` in Qdrant

## Summary Matrix

| Step | Description | AUTO / MANUAL | Verifies |
|------|-------------|---------------|----------|
| 1a | Dry-run init valid config | AUTO | Validation logic, audit emission |
| 1b | KER-SI-005 trigger | AUTO | Auth-none-ack enforcement (RC-4) |
| 1c | KER-SI-006 trigger | AUTO | Budget enforcement (RC-7) |
| 1d | Live n8n_create_workflow | MANUAL | RC-9 credential lifecycle |
| 2a | Auth fail → DLQ | AUTO | RC-4 / F-10 ordering |
| 2b | Auth before schema | AUTO | RC-4 / F-10 ordering |
| 2c | Auth success path | AUTO | HMAC verification |
| 2d | Live trigger via MCP | MANUAL | n8n-mcp dispatch |
| 3a | Audit rows present | AUTO | REQ-KER-018 emission |
| 3b | POC workflow audit row | MANUAL | F-12 parent_id, REQ-XCT-002 |
| 4a | state_mutate bootstrap | AUTO | REQ-KER-012 |
| 4b | state_get round-trip | AUTO | REQ-KER-012 |
| 4c | KER-SS-001 | AUTO | Error handling |
| 4d | JSON-Patch append | AUTO | RFC 6902 mutation |
| 5a | Health from audit | AUTO | REQ-KER-013 fallback |
| 5b | Health from n8n | MANUAL | Full REQ-KER-013 |
| 6a | Pause audit | AUTO | REQ-KER-013 pause |
| 6b | Live deactivate | MANUAL | n8n toggle |
| 6c | Resume audit | AUTO | REQ-KER-013 resume |
| 7a | Spawn workflow | AUTO | REQ-KER-014 |

## Phase 3 Closeout Acceptance

This integration test passes Phase 3 closeout when:
- All AUTO steps return their expected outputs and exit codes
- All MANUAL steps have been documented to operators with the exact commands and verification queries above
- BRD-tracker.json REQ-KER-010..014 + REQ-XCT-006..009 status reflects implemented + verification evidence captured

The Phase 1 deferred items resolve as follows:
- REQ-XCT-002 (audit emitter): template ships in `templates/n8n-audit-emitter.json`; POC integration in `workflows/_shared/audit-emitter-poc.json` demonstrates production wiring
- REQ-XCT-006 (5 n8n-mcp tools wrapped): all 5 wired in lib/stream/ scripts (create via stream-init, trigger via stream-handle-event, list_executions + get_workflow_details via stream-health, update_partial_workflow via stream-pause/resume)
- REQ-XCT-007 (event schemas): three baseline envelopes shipped under schemas/events/, with the README convention documented and enforced via handle-event's schema validation step
- REQ-XCT-009 (workflow migration): POC migration of memory-skill-discovery demonstrates the integration pattern; full triage of the 30+ workflows is a Phase 6 backlog item
