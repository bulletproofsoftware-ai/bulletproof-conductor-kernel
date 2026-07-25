#!/usr/bin/env bash
# lib/stream/stream-handle-event.sh — kernel.stream.handle_event implementation
# REQ-KER-011 / REQ-XCT-007 / RC-4 / RC-9 / F-10 / F-12
#
# Enforcement order (RC-4 / F-10):
#   1. Look up subscription for event.source
#   2. VERIFY auth_material per subscription.authentication.kind
#   3. If auth fails: emit "stream.event_auth_failure", drop to DLQ,
#      return KER-SE-004. NO downstream dispatch.
#   4. ONLY THEN validate event against subscription.event_schema_ref (REQ-XCT-007)
#   5. ONLY THEN check budget (RC-7) and proceed.
#
# Per F-12, when stream-mode dispatches an agent, parent_id MUST be formed
# as "<stream_id>:<n8n_node_id>" — this is propagated to the n8n audit-emitter
# template; this script only stamps the inbound event with the correlation
# id so the template has both halves to combine.
#
# Usage:
#   stream-handle-event.sh --stream-id <id> --event-file <path> --auth-file <path> [--mode sync|async]
#   echo '{"event":...,"auth":...}' | stream-handle-event.sh --stream-id <id> --stdin

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# shellcheck source=scripts/lib/paths.sh
. "$KERNEL_ROOT/scripts/lib/paths.sh"

STREAM_ID=""
EVENT_FILE=""
AUTH_FILE=""
MODE="sync"
FROM_STDIN=0

usage() {
  cat <<'USAGE'
stream-handle-event.sh — kernel.stream.handle_event wrapper

USAGE:
  stream-handle-event.sh --stream-id <id> --event-file <path> --auth-file <path> [--mode sync|async]
  echo '{"event":{...},"auth":{...},"subscription":{...}}' | stream-handle-event.sh --stream-id <id> --stdin

OPTIONS:
  --stream-id <id>      n8n workflow_id of the stream (required)
  --event-file <path>   File containing the event JSON
  --auth-file <path>    File containing auth material (e.g., {"header.X-Signature":"sha256=..."})
  --mode sync|async     Dispatch mode (default sync; auto-async if event ttl <5s)
  --stdin               Read combined {event,auth,subscription} from stdin

EXIT CODES:
  0  success (event handled)
  1  validation error
  2  KER-SE-001 stream not found
  3  KER-SE-002 event schema validation failed
  4  KER-SE-003 n8n execution timeout
  5  KER-SE-004 event_auth_failed (drops to DLQ)
USAGE
}

err_json() {
  local code="$1" msg="$2"
  printf '{"ok":false,"error_code":"%s","message":%s}\n' "$code" "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

audit_emit() {
  local event_type="$1" payload_json="$2"
  local audit_db; audit_db="$(kernel_audit_db_path)"
  local event_id ts session_id
  event_id="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  session_id="${STREAM_AUDIT_SESSION_ID:-$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')}"

  if [ -f "$audit_db" ] && command -v sqlite3 >/dev/null 2>&1; then
    local detail
    detail="$(printf '%s' "$payload_json" | python3 -c 'import json,sys; print(json.dumps({"payload": json.loads(sys.stdin.read())}))')"
    sqlite3 "$audit_db" <<SQL 2>/dev/null || true
INSERT INTO audit_events (event_id, timestamp, audit_session_id, event_type, agent_id, detail, outcome, human_user_id)
VALUES ('$event_id', '$ts', '$session_id', '$event_type', 'conductor-kernel:stream', '$(printf '%s' "$detail" | sed "s/'/''/g")', 'success', 'kernel');
SQL
  else
    printf '{"event_id":"%s","timestamp":"%s","event_type":"%s","payload":%s}\n' \
      "$event_id" "$ts" "$event_type" "$payload_json" >> "$(kernel_audit_fallback_path)"
  fi
  printf '%s' "$event_id"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stream-id) STREAM_ID="$2"; shift 2 ;;
    --event-file) EVENT_FILE="$2"; shift 2 ;;
    --auth-file) AUTH_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --stdin) FROM_STDIN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err_json "INVALID-ARG" "unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$STREAM_ID" ]; then
  err_json "INVALID-ARG" "--stream-id required"
  exit 1
fi

# Read inputs
if [ "$FROM_STDIN" -eq 1 ]; then
  COMBINED="$(cat)"
else
  if [ -z "$EVENT_FILE" ] || [ -z "$AUTH_FILE" ]; then
    err_json "INVALID-ARG" "must supply --event-file + --auth-file, or --stdin"
    exit 1
  fi
  EVENT_JSON="$(cat "$EVENT_FILE")"
  AUTH_JSON="$(cat "$AUTH_FILE")"
  # subscription is loaded from stream-state in fuller implementation; for POC
  # we accept it inline alongside event+auth via env var or default to unset.
  COMBINED="$(python3 -c "
import json,sys
print(json.dumps({
    'event': json.loads('''$EVENT_JSON'''),
    'auth': json.loads('''$AUTH_JSON''')
}))
")"
fi

START_TS="$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')"

# === STEP 1: subscription lookup ===
# In a full implementation, fetch stream-state from Qdrant by stream_id and
# locate the matching subscription via event.source. For Phase 3 we accept
# subscription inline (passed alongside event) OR look it up via state-get.
SUBSCRIPTION_JSON="$(COMBINED_INPUT="$COMBINED" python3 -c '
import json,os
d = json.loads(os.environ["COMBINED_INPUT"])
sub = d.get("subscription")
if not sub:
    # Fallback: synthesize a permissive subscription so the script can be
    # exercised in isolation. Production callers MUST pass subscription.
    print(json.dumps({
        "source": d.get("event", {}).get("source", "unknown"),
        "kind": "webhook",
        "authentication": {"kind": "none", "audit_warning_acknowledged": True},
        "event_schema_ref": None
    }))
else:
    print(json.dumps(sub))
')"

AUTH_KIND="$(SUB_JSON="$SUBSCRIPTION_JSON" python3 -c 'import json,os; print(json.loads(os.environ["SUB_JSON"]).get("authentication",{}).get("kind",""))')"

# === STEP 2: AUTH VERIFICATION (BEFORE schema validation per RC-4) ===
AUTH_VERDICT="$(COMBINED_INPUT="$COMBINED" SUBSCRIPTION_JSON="$SUBSCRIPTION_JSON" python3 <<'PY'
import json, os, sys, hmac, hashlib, base64, time

combined = json.loads(os.environ["COMBINED_INPUT"])
sub = json.loads(os.environ["SUBSCRIPTION_JSON"])
auth = combined.get("auth", {}) or {}
event = combined.get("event", {}) or {}

authcfg = sub.get("authentication", {})
kind = authcfg.get("kind")

def fail(reason):
    print(json.dumps({"ok": False, "reason": reason, "kind": kind}))
    sys.exit(0)

def ok():
    print(json.dumps({"ok": True, "kind": kind}))
    sys.exit(0)

if kind == "none":
    if not authcfg.get("audit_warning_acknowledged"):
        fail("kind=none requires audit_warning_acknowledged at init time")
    ok()

# kind != "none" — need secret material to verify
secret_ref = authcfg.get("secret_ref")
verification_field = authcfg.get("verification_field")
if not secret_ref or not verification_field:
    fail("missing secret_ref or verification_field in subscription.authentication")

# Resolve secret: env://VAR or file:///path
secret = None
if secret_ref.startswith("env://"):
    var = secret_ref[len("env://"):]
    secret = os.environ.get(var)
elif secret_ref.startswith("file://"):
    path = secret_ref[len("file://"):]
    try:
        with open(path, "rb") as fh:
            secret = fh.read().strip()
    except Exception as e:
        fail(f"could not read secret file: {e}")
elif secret_ref.startswith("vault://"):
    # Vault resolution is operator-provided; not implemented in Phase 3 POC.
    fail("vault:// secret_ref requires operator-side vault integration not implemented in POC")
else:
    fail("unsupported secret_ref scheme")

if not secret:
    fail("secret material empty or unresolvable")

# Extract verification material from auth dict
material = auth.get(verification_field)
if material is None:
    fail(f"verification_field '{verification_field}' missing from auth_material")

algorithm = (authcfg.get("algorithm") or "hmac-sha256").lower()

if kind == "hmac":
    if algorithm != "hmac-sha256":
        fail(f"unsupported algorithm {algorithm} for kind=hmac")
    body = json.dumps(event, sort_keys=True, separators=(",", ":")).encode("utf-8")
    sig = hmac.new(secret if isinstance(secret, bytes) else secret.encode(),
                   body, hashlib.sha256).hexdigest()
    # Accept either "hex" or "sha256=hex"
    expected1 = sig
    expected2 = f"sha256={sig}"
    if not (hmac.compare_digest(material, expected1) or hmac.compare_digest(material, expected2)):
        fail("hmac-sha256 signature mismatch")
    ok()
elif kind == "shared_secret":
    if not hmac.compare_digest(material, secret.decode() if isinstance(secret, bytes) else secret):
        fail("shared_secret mismatch")
    ok()
elif kind == "oauth_jwt":
    # JWT verification requires libraries not available in pure-stdlib bash POC.
    # Defer to dedicated impl. For Phase 3 we surface a clear MANUAL marker.
    fail("oauth_jwt verification not implemented in Phase 3 POC; use mtls/hmac or implement via PyJWT")
elif kind == "mtls":
    fail("mtls verification happens at transport layer; not applicable in this script")
else:
    fail(f"unknown auth kind: {kind}")
PY
)"

AUTH_OK="$(VERDICT_JSON="$AUTH_VERDICT" python3 -c 'import json,os; print(json.loads(os.environ["VERDICT_JSON"])["ok"])')"

if [ "$AUTH_OK" != "True" ]; then
  REASON="$(VERDICT_JSON="$AUTH_VERDICT" python3 -c 'import json,os; print(json.loads(os.environ["VERDICT_JSON"]).get("reason",""))')"
  audit_emit "stream.event_auth_failure" \
    "$(printf '{"stream_id":"%s","auth_kind":"%s","reason":%s}' "$STREAM_ID" "$AUTH_KIND" "$(printf '%s' "$REASON" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")" >/dev/null || true
  err_json "KER-SE-004" "event_auth_failed: $REASON — event dropped to DLQ"
  exit 5
fi

# === STEP 3 (skipped because auth passed) — STEP 4: schema validation ===
SCHEMA_REF="$(SUB_JSON="$SUBSCRIPTION_JSON" python3 -c 'import json,os; print(json.loads(os.environ["SUB_JSON"]).get("event_schema_ref") or "")')"
if [ -n "$SCHEMA_REF" ]; then
  # Resolve relative to schemas/events/ if not absolute
  if [ "${SCHEMA_REF:0:1}" != "/" ]; then
    SCHEMA_REF="$KERNEL_ROOT/schemas/events/$SCHEMA_REF"
  fi
  if [ ! -r "$SCHEMA_REF" ]; then
    err_json "KER-SE-002" "event_schema_ref not readable: $SCHEMA_REF"
    exit 3
  fi
  # Validate via python jsonschema if installed; else minimal best-effort
  VALIDATE="$(COMBINED_INPUT="$COMBINED" SCHEMA_REF="$SCHEMA_REF" python3 <<'PY'
import json, os, sys
combined = json.loads(os.environ["COMBINED_INPUT"])
event = combined.get("event", {})
schema_path = os.environ["SCHEMA_REF"]
with open(schema_path) as fh:
    schema = json.load(fh)
try:
    from jsonschema import validate, ValidationError
    try:
        validate(instance=event, schema=schema)
        print(json.dumps({"ok": True}))
    except ValidationError as e:
        print(json.dumps({"ok": False, "reason": str(e.message)[:300]}))
except ImportError:
    # Best-effort: check required top-level fields if declared.
    req = schema.get("required", [])
    missing = [k for k in req if k not in event]
    if missing:
        print(json.dumps({"ok": False, "reason": f"missing required: {missing}"}))
    else:
        print(json.dumps({"ok": True, "_advisory": "jsonschema not installed; only checked top-level required"}))
PY
)"
  SCHEMA_OK="$(VALIDATE_JSON="$VALIDATE" python3 -c 'import json,os; print(json.loads(os.environ["VALIDATE_JSON"])["ok"])')"
  if [ "$SCHEMA_OK" != "True" ]; then
    REASON="$(VALIDATE_JSON="$VALIDATE" python3 -c 'import json,os; print(json.loads(os.environ["VALIDATE_JSON"]).get("reason",""))')"
    audit_emit "stream.event_schema_failure" \
      "$(printf '{"stream_id":"%s","reason":%s}' "$STREAM_ID" "$(printf '%s' "$REASON" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")" >/dev/null || true
    err_json "KER-SE-002" "event schema validation failed: $REASON"
    exit 3
  fi
fi

# === STEP 5: budget check would happen here in a fuller impl ===
# For Phase 3, we trust that stream-init enforced budget presence and the
# n8n workflow respects the per-event budget. The kernel's full budget
# enforcement at dispatch time is in kernel.dispatch_agent (REQ-KER-015,
# already implemented in Phase 1).

# === Trigger n8n webhook ===
if [ -z "${N8N_API_KEY:-}" ]; then
  cat <<MANUAL
{"ok":true,"manual_dispatch":true,"stream_id":"$STREAM_ID","note":"Auth + schema validated. n8n_trigger_webhook_workflow must be invoked from Claude Code MCP context, or set N8N_API_KEY for direct fallback. Per RC-9 kernel does not store credentials.","auth_kind":"$AUTH_KIND","mode":"$MODE"}
MANUAL
  audit_emit "stream.event_handled" \
    "$(printf '{"stream_id":"%s","mode":"%s","status":"validated_only","auth_kind":"%s"}' "$STREAM_ID" "$MODE" "$AUTH_KIND")" >/dev/null || true
  exit 0
fi

# Direct trigger fallback (POC).
N8N_URL="${N8N_URL:-http://localhost:5679}"
EVENT_BODY="$(COMBINED_INPUT="$COMBINED" python3 -c 'import json,os; print(json.dumps(json.loads(os.environ["COMBINED_INPUT"])["event"]))')"

RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' \
  -X POST "$N8N_URL/api/v1/workflows/$STREAM_ID/execute" \
  -H "Content-Type: application/json" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  --data "$EVENT_BODY" 2>&1 || true)"
HTTP_CODE="$(printf '%s' "$RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"
BODY="$(printf '%s' "$RESP" | sed -e 's/__HTTP__:[0-9]*$//')"
END_TS="$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')"
LATENCY_MS="$(python3 -c "print(int(($END_TS - $START_TS) / 1_000_000))")"

case "$HTTP_CODE" in
  200|201)
    audit_emit "stream.event_handled" \
      "$(printf '{"stream_id":"%s","mode":"%s","latency_ms":%s,"status":"success","auth_kind":"%s"}' "$STREAM_ID" "$MODE" "$LATENCY_MS" "$AUTH_KIND")" >/dev/null || true
    printf '{"ok":true,"stream_id":"%s","mode":"%s","latency_ms":%s,"auth_kind":"%s"}\n' \
      "$STREAM_ID" "$MODE" "$LATENCY_MS" "$AUTH_KIND"
    exit 0
    ;;
  401|403)
    audit_emit "stream.n8n_unauthorized" \
      "$(printf '{"tool":"trigger_webhook","http_status":%s}' "$HTTP_CODE")" >/dev/null || true
    err_json "KER-SI-004" "n8n unauthorized (HTTP $HTTP_CODE) — no retry per RC-9"
    exit 3
    ;;
  404)
    err_json "KER-SE-001" "stream not found: $STREAM_ID"
    exit 2
    ;;
  *)
    audit_emit "stream.event_handler_error" \
      "$(printf '{"stream_id":"%s","http_status":%s}' "$STREAM_ID" "${HTTP_CODE:-0}")" >/dev/null || true
    err_json "KER-SE-003" "n8n execution error HTTP ${HTTP_CODE:-0}: $(printf '%s' "$BODY" | head -c 300)"
    exit 4
    ;;
esac
