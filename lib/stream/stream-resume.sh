#!/usr/bin/env bash
# lib/stream/stream-resume.sh — kernel.stream.resume implementation (REQ-KER-013)
#
# Reactivates the n8n workflow (active=true) and clears pause_state.
# Mirror of stream-pause.sh.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# shellcheck source=scripts/lib/paths.sh
. "$KERNEL_ROOT/scripts/lib/paths.sh"

STREAM_ID=""

usage() {
  cat <<'USAGE'
stream-resume.sh — kernel.stream.resume wrapper

USAGE:
  stream-resume.sh --stream-id <id>
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

audit_emit() {
  local event_type="$1" payload_json="$2"
  local audit_db; audit_db="$(kernel_audit_db_path)"
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

RESUMED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
audit_emit "stream.resume" "$(printf '{"stream_id":"%s","resumed_at":"%s"}' "$STREAM_ID" "$RESUMED_AT")" >/dev/null

N8N_URL="${N8N_URL:-http://localhost:5679}"
if [ -z "${N8N_API_KEY:-}" ]; then
  cat <<MANUAL
{"ok":true,"manual_n8n":true,"stream_id":"$STREAM_ID","resumed_at":"$RESUMED_AT","note":"State recorded. n8n active=true toggle must be invoked from MCP context or set N8N_API_KEY."}
MANUAL
  exit 0
fi

RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' \
  -X POST "$N8N_URL/api/v1/workflows/$STREAM_ID/activate" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" 2>&1 || true)"
HTTP_CODE="$(printf '%s' "$RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"

case "$HTTP_CODE" in
  200|204) printf '{"ok":true,"stream_id":"%s","resumed_at":"%s"}\n' "$STREAM_ID" "$RESUMED_AT" ;;
  401|403) audit_emit "stream.n8n_unauthorized" "$(printf '{"tool":"activate","http_status":%s}' "$HTTP_CODE")" >/dev/null
           echo '{"ok":false,"error_code":"KER-SI-004","message":"n8n unauthorized"}'; exit 3 ;;
  404) echo "{\"ok\":false,\"error_code\":\"KER-SE-001\",\"message\":\"stream not found: $STREAM_ID\"}"; exit 2 ;;
  *)   echo "{\"ok\":false,\"error_code\":\"KER-SI-001\",\"message\":\"n8n activate failed HTTP ${HTTP_CODE:-0}\"}"; exit 1 ;;
esac
