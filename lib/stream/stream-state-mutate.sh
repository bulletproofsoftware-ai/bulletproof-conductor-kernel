#!/usr/bin/env bash
# lib/stream/stream-state-mutate.sh — kernel.stream.state_mutate (REQ-KER-012)
#
# Applies a JSON-Patch (RFC 6902) mutation to a stream-state document in
# Qdrant collection 'kernel_stream_state'. Schema-validates the result
# before persisting. Emits "stream.state_mutate" audit event.
#
# Usage:
#   stream-state-mutate.sh --stream-id <id> --mutation '<json-patch>'
#   stream-state-mutate.sh --stream-id <id> --mutation-file <path>
#
# Special-case bootstrap: if the document does not yet exist and --mutation
# is a single { "op": "replace", "path": "", "value": <full-state> }, the
# script will create the point.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
SCHEMA_PATH="$KERNEL_ROOT/schemas/stream-state.schema.json"

STREAM_ID=""
MUTATION=""
MUTATION_FILE=""

usage() {
  cat <<'USAGE'
stream-state-mutate.sh — kernel.stream.state_mutate

USAGE:
  stream-state-mutate.sh --stream-id <id> --mutation '<rfc6902-json-patch>'
  stream-state-mutate.sh --stream-id <id> --mutation-file <path>

EXIT:
  0 success (mutated state on stdout)
  1 INVALID-ARG
  2 KER-SS-002 mutation violates schema
  3 Qdrant unreachable
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stream-id) STREAM_ID="$2"; shift 2 ;;
    --mutation) MUTATION="$2"; shift 2 ;;
    --mutation-file) MUTATION_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "{\"ok\":false,\"error_code\":\"INVALID-ARG\",\"message\":\"unknown arg $1\"}"; exit 1 ;;
  esac
done

[ -n "$STREAM_ID" ] || { echo '{"ok":false,"error_code":"INVALID-ARG","message":"--stream-id required"}'; exit 1; }
if [ -z "$MUTATION" ] && [ -n "$MUTATION_FILE" ]; then
  MUTATION="$(cat "$MUTATION_FILE")"
fi
[ -n "$MUTATION" ] || { echo '{"ok":false,"error_code":"INVALID-ARG","message":"--mutation or --mutation-file required"}'; exit 1; }

QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
COLLECTION="${KERNEL_STREAM_COLLECTION:-kernel_stream_state}"
QDRANT_AUTH=()
if [ -n "${QDRANT_API_KEY:-}" ]; then
  QDRANT_AUTH=(-H "api-key: $QDRANT_API_KEY")
fi

# Ensure collection exists. Qdrant requires explicit creation.
ensure_collection() {
  local url="$1"
  local create_resp http
  create_resp="$(curl -sS -w '\n__HTTP__:%{http_code}' "${QDRANT_AUTH[@]}" -X PUT "$url/collections/$COLLECTION" \
    -H "Content-Type: application/json" \
    -d '{"vectors":{"size":1,"distance":"Dot"}}' 2>&1 || true)"
  http="$(printf '%s' "$create_resp" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"
  # 200 = created; 409 = already exists; both fine.
  case "$http" in
    200|409) return 0 ;;
    *) return 1 ;;
  esac
}

if ! ensure_collection "$QDRANT_URL"; then
  # Try 6334 fallback
  QDRANT_URL="${QDRANT_URL/6333/6334}"
  if ! ensure_collection "$QDRANT_URL"; then
    echo '{"ok":false,"error_code":"KER-SI-001","message":"qdrant unreachable; cannot ensure collection"}'
    exit 3
  fi
fi

# Map stream_id → Qdrant point id (UUIDv5; identical to state-get.sh)
POINT_ID="$(STREAM_ID="$STREAM_ID" python3 -c '
import os, uuid
sid = os.environ["STREAM_ID"]
try:
    uuid.UUID(sid)
    print(sid)
except ValueError:
    print(uuid.uuid5(uuid.NAMESPACE_OID, f"kernel_stream_state:{sid}"))
')"

# Fetch current state (if any)
CURRENT_RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' "${QDRANT_AUTH[@]}" "$QDRANT_URL/collections/$COLLECTION/points/$POINT_ID" 2>&1 || true)"
CURRENT_HTTP="$(printf '%s' "$CURRENT_RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"
CURRENT_BODY="$(printf '%s' "$CURRENT_RESP" | sed -e 's/__HTTP__:[0-9]*$//')"

CURRENT_STATE="$(case "$CURRENT_HTTP" in
  200) printf '%s' "$CURRENT_BODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result",{}).get("payload",{})))' ;;
  *) printf '{}' ;;
esac)"

# Apply the mutation. Use jsonpatch python module if available; fallback
# to a minimal supportive subset for "add to /spawned_workflow_ids/-".
NEW_STATE="$(CURRENT_STATE_INPUT="$CURRENT_STATE" MUTATION="$MUTATION" python3 <<'PY'
import json, os, sys
state = json.loads(os.environ["CURRENT_STATE_INPUT"])
mutation = json.loads(os.environ["MUTATION"])
try:
    import jsonpatch
    patch = jsonpatch.JsonPatch(mutation)
    result = patch.apply(state)
except ImportError:
    # Minimal fallback supporting: replace "", add /key, add /list/-
    result = dict(state) if isinstance(state, dict) else state
    for op in mutation if isinstance(mutation, list) else [mutation]:
        o = op.get("op"); p = op.get("path",""); v = op.get("value")
        if o == "replace" and p == "":
            result = v
        elif o == "add" and p.startswith("/") and not p.endswith("/-"):
            # /key or /a/b
            parts = [x for x in p.split("/") if x != ""]
            cur = result
            for k in parts[:-1]:
                cur = cur.setdefault(k, {})
            cur[parts[-1]] = v
        elif o == "add" and p.endswith("/-"):
            # Append to list
            parts = [x for x in p[:-2].split("/") if x != ""]
            cur = result
            for k in parts[:-1]:
                cur = cur.setdefault(k, {})
            last = parts[-1] if parts else None
            if last is not None:
                cur.setdefault(last, []).append(v)
        elif o == "remove" and p.startswith("/"):
            parts = [x for x in p.split("/") if x != ""]
            cur = result
            for k in parts[:-1]:
                cur = cur.get(k, {})
            if isinstance(cur, dict):
                cur.pop(parts[-1], None)
        else:
            # Unsupported op in fallback
            sys.stderr.write(f"unsupported op in stdlib fallback: {op}\n")
print(json.dumps(result))
PY
)"

# Best-effort schema validation. Strip kernel-internal annotation fields
# (_kernel_*) before validation — they're transport-only and the strict
# `additionalProperties: false` schema would otherwise reject them.
SCHEMA_VERDICT="$(NEW_STATE_INPUT="$NEW_STATE" SCHEMA_PATH="$SCHEMA_PATH" python3 <<'PY'
import json, os, sys
state = json.loads(os.environ["NEW_STATE_INPUT"])
# Strip internal annotations
to_validate = {k: v for k, v in state.items() if not k.startswith("_kernel_")}
try:
    with open(os.environ["SCHEMA_PATH"]) as fh:
        schema = json.load(fh)
    from jsonschema import validate, ValidationError
    try:
        validate(instance=to_validate, schema=schema)
        print(json.dumps({"ok": True}))
    except ValidationError as e:
        print(json.dumps({"ok": False, "reason": str(e.message)[:300]}))
except ImportError:
    print(json.dumps({"ok": True, "_advisory": "jsonschema not installed; mutation accepted advisory-only"}))
except Exception as e:
    print(json.dumps({"ok": True, "_advisory": f"schema not loaded ({e}); mutation accepted advisory-only"}))
PY
)"
SCHEMA_OK="$(SCHEMA_VERDICT_IN="$SCHEMA_VERDICT" python3 -c 'import json,os; print(json.loads(os.environ["SCHEMA_VERDICT_IN"]).get("ok"))')"
if [ "$SCHEMA_OK" != "True" ]; then
  REASON="$(SCHEMA_VERDICT_IN="$SCHEMA_VERDICT" python3 -c 'import json,os; print(json.loads(os.environ["SCHEMA_VERDICT_IN"]).get("reason",""))')"
  echo "{\"ok\":false,\"error_code\":\"KER-SS-002\",\"message\":\"mutation violates schema: $REASON\"}"
  exit 2
fi

# Upsert into Qdrant. Use payload-only storage: dummy 1-dim vector to satisfy
# qdrant collection requirements. Per STATE-PERSISTENCE.md we don't currently
# do semantic search on stream state; if/when needed, switch to 768-dim
# nomic-embed-text and embed the summary text.
UPSERT_PAYLOAD="$(NEW_STATE_INPUT="$NEW_STATE" STREAM_ID="$STREAM_ID" python3 <<'PY'
import json, os, sys
state = json.loads(os.environ["NEW_STATE_INPUT"])
# Qdrant requires the point id to be an unsigned int or UUID. n8n workflow ids
# are typically alphanumeric strings, so we hash to UUID.
import uuid, hashlib
sid = os.environ["STREAM_ID"]
try:
    # If already a UUID, accept
    uuid.UUID(sid)
    point_id = sid
except ValueError:
    # Deterministic UUIDv5 derived from sid
    point_id = str(uuid.uuid5(uuid.NAMESPACE_OID, f"kernel_stream_state:{sid}"))
state["_kernel_point_id"] = point_id
state["_kernel_stream_id_raw"] = sid
upsert = {
    "points": [{
        "id": point_id,
        "vector": [0.0],
        "payload": state
    }]
}
print(json.dumps(upsert))
PY
)"

RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' "${QDRANT_AUTH[@]}" \
  -X PUT "$QDRANT_URL/collections/$COLLECTION/points?wait=true" \
  -H "Content-Type: application/json" \
  --data "$UPSERT_PAYLOAD" 2>&1 || true)"
HTTP_CODE="$(printf '%s' "$RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"

# Audit emit
audit_emit() {
  local event_type="$1" payload_json="$2"
  local audit_db="${AUDIT_DB_OVERRIDE:-$HOME/Code/governance-plugin/state/audit.db}"
  [ -f "$audit_db" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  local event_id ts session_id detail
  event_id="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  session_id="${STREAM_AUDIT_SESSION_ID:-$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')}"
  detail="$(printf '%s' "$payload_json" | python3 -c 'import json,sys; print(json.dumps({"payload": json.loads(sys.stdin.read())}))')"
  sqlite3 "$audit_db" <<SQL 2>/dev/null || true
INSERT INTO audit_events (event_id, timestamp, audit_session_id, event_type, agent_id, detail, outcome, human_user_id)
VALUES ('$event_id', '$ts', '$session_id', '$event_type', 'conductor-kernel:stream', '$(printf '%s' "$detail" | sed "s/'/''/g")', 'success', 'kernel');
SQL
}

case "$HTTP_CODE" in
  200)
    audit_emit "stream.state_mutate" \
      "$(printf '{"stream_id":"%s","mutation_size":%d}' "$STREAM_ID" "${#MUTATION}")" >/dev/null
    printf '{"ok":true,"stream_id":"%s","state":%s}\n' "$STREAM_ID" "$NEW_STATE"
    exit 0
    ;;
  *)
    echo "{\"ok\":false,\"error_code\":\"KER-SI-001\",\"message\":\"qdrant upsert failed HTTP ${HTTP_CODE:-0}\"}"
    exit 3
    ;;
esac
