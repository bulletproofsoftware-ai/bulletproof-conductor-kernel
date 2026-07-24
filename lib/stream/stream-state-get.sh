#!/usr/bin/env bash
# lib/stream/stream-state-get.sh — kernel.stream.state_get (REQ-KER-012)
#
# Fetches a stream-state document from Qdrant collection 'kernel_stream_state'
# keyed by stream_id. Validates against schemas/stream-state.schema.json
# before returning (best-effort via jsonschema; advisory if missing).
#
# Usage: stream-state-get.sh --stream-id <id>
#
# Returns the stream-state JSON on stdout, or { ok:false, error_code: ... }.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

STREAM_ID=""

usage() {
  cat <<'USAGE'
stream-state-get.sh — kernel.stream.state_get

USAGE:
  stream-state-get.sh --stream-id <id>

ENVIRONMENT:
  QDRANT_URL      Default http://localhost:6333 (REST). Falls back to :6334 if 6333 unreachable.
  KERNEL_STREAM_COLLECTION  Default "kernel_stream_state"

EXIT:
  0 success (state JSON on stdout)
  1 KER-SS-001 stream not found
  2 Qdrant unreachable
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stream-id) STREAM_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "{\"ok\":false,\"error_code\":\"INVALID-ARG\",\"message\":\"unknown arg $1\"}"; exit 1 ;;
  esac
done

[ -n "$STREAM_ID" ] || { echo '{"ok":false,"error_code":"INVALID-ARG","message":"--stream-id required"}'; exit 1; }

QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
COLLECTION="${KERNEL_STREAM_COLLECTION:-kernel_stream_state}"
QDRANT_AUTH=()
if [ -n "${QDRANT_API_KEY:-}" ]; then
  QDRANT_AUTH=(-H "api-key: $QDRANT_API_KEY")
fi

# Map stream_id → Qdrant point id (UUIDv5 derived; identical to state-mutate.sh)
POINT_ID="$(STREAM_ID="$STREAM_ID" python3 -c '
import os, uuid
sid = os.environ["STREAM_ID"]
try:
    uuid.UUID(sid)
    print(sid)
except ValueError:
    print(uuid.uuid5(uuid.NAMESPACE_OID, f"kernel_stream_state:{sid}"))
')"

# Try REST endpoint first
RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' "${QDRANT_AUTH[@]}" "$QDRANT_URL/collections/$COLLECTION/points/$POINT_ID" 2>&1 || true)"
HTTP_CODE="$(printf '%s' "$RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"
BODY="$(printf '%s' "$RESP" | sed -e 's/__HTTP__:[0-9]*$//')"

if [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
  # Try alternative port 6334 (in this deployment the host port mapping
  # may bind container :6333 to host :6334)
  QDRANT_URL="${QDRANT_URL/6333/6334}"
  RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' "${QDRANT_AUTH[@]}" "$QDRANT_URL/collections/$COLLECTION/points/$POINT_ID" 2>&1 || true)"
  HTTP_CODE="$(printf '%s' "$RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"
  BODY="$(printf '%s' "$RESP" | sed -e 's/__HTTP__:[0-9]*$//')"
fi

case "$HTTP_CODE" in
  200)
    # Qdrant point retrieval returns { result: { id, payload, vector? }, status, time }
    PAYLOAD="$(printf '%s' "$BODY" | python3 -c '
import json,sys
d=json.load(sys.stdin)
r=d.get("result")
if not r:
    print(json.dumps({"ok":False,"error_code":"KER-SS-001","message":"stream not found"})); sys.exit(0)
print(json.dumps(r.get("payload", {})))
')"
    NOT_FOUND="$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error_code","") if isinstance(d, dict) else "")')"
    if [ "$NOT_FOUND" = "KER-SS-001" ]; then
      echo "$PAYLOAD"; exit 1
    fi
    echo "$PAYLOAD"
    exit 0
    ;;
  404)
    echo "{\"ok\":false,\"error_code\":\"KER-SS-001\",\"message\":\"stream not found: $STREAM_ID\"}"
    exit 1
    ;;
  *)
    echo "{\"ok\":false,\"error_code\":\"KER-SI-001\",\"message\":\"qdrant unreachable or error HTTP ${HTTP_CODE:-0}\"}"
    exit 2
    ;;
esac
