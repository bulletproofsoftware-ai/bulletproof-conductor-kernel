#!/usr/bin/env bash
# lib/stream/stream-health.sh — kernel.stream.health implementation
# REQ-KER-013
#
# Aggregates n8n_list_executions + n8n_get_workflow_details + governance audit
# emissions to produce a health_metrics object matching stream-state.schema.json.
#
# Output:
# {
#   "ok": true,
#   "stream_id": "...",
#   "health_metrics": {
#     "success_rate": 0.0-1.0,
#     "avg_latency_ms": number,
#     "p99_latency_ms": number,
#     "error_rate": 0.0-1.0,
#     "throughput_per_min": number,
#     "dlq_depth": int,
#     "sla_status": "healthy"|"degraded"|"breach"|"unknown",
#     "measured_at": ISO-8601,
#     "window_seconds": int
#   }
# }
#
# Usage: stream-health.sh --stream-id <id> [--window-seconds 3600]

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

STREAM_ID=""
WINDOW_SECONDS=3600

usage() {
  cat <<'USAGE'
stream-health.sh — kernel.stream.health wrapper

USAGE:
  stream-health.sh --stream-id <id> [--window-seconds <int>]

OPTIONS:
  --stream-id      n8n workflow_id (required)
  --window-seconds rolling window for metrics aggregation (default 3600)

EXIT:
  0 success
  1 stream not found / unreachable
  2 unauthorized
  3 internal error
USAGE
}

err_json() {
  local code="$1" msg="$2"
  printf '{"ok":false,"error_code":"%s","message":%s}\n' "$code" \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

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

while [ $# -gt 0 ]; do
  case "$1" in
    --stream-id) STREAM_ID="$2"; shift 2 ;;
    --window-seconds) WINDOW_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err_json "INVALID-ARG" "unknown argument: $1"; exit 1 ;;
  esac
done

[ -n "$STREAM_ID" ] || { err_json "INVALID-ARG" "--stream-id required"; exit 1; }

N8N_URL="${N8N_URL:-http://localhost:5679}"
MEASURED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
SINCE_TS="$(python3 -c "import time,datetime; t=time.time()-$WINDOW_SECONDS; print(datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# Without N8N_API_KEY, we cannot reach n8n directly; emit MANUAL marker with
# audit-bus-derived metrics only.
if [ -z "${N8N_API_KEY:-}" ]; then
  AUDIT_DB="${AUDIT_DB_OVERRIDE:-$HOME/Code/governance-plugin/state/audit.db}"
  if [ -f "$AUDIT_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    AUDIT_METRICS="$(STREAM_ID="$STREAM_ID" SINCE_TS="$SINCE_TS" AUDIT_DB="$AUDIT_DB" python3 <<'PY'
import sqlite3, os, json
db = os.environ["AUDIT_DB"]
sid = os.environ["STREAM_ID"]
since = os.environ["SINCE_TS"]
conn = sqlite3.connect(db)
c = conn.cursor()
# Count events_handled vs auth_failures vs schema_failures vs handler_errors
def cnt(et):
    # Match both compact ("stream_id":"foo") and indented ("stream_id": "foo") JSON
    pattern_a = f'%"stream_id":"{sid}"%'
    pattern_b = f'%"stream_id": "{sid}"%'
    c.execute("""SELECT COUNT(*) FROM audit_events
                 WHERE event_type = ? AND timestamp >= ?
                   AND (detail LIKE ? OR detail LIKE ?)""",
              (et, since, pattern_a, pattern_b))
    return c.fetchone()[0]
handled = cnt("stream.event_handled")
auth_fail = cnt("stream.event_auth_failure")
schema_fail = cnt("stream.event_schema_failure")
handler_err = cnt("stream.event_handler_error")
total = handled + auth_fail + schema_fail + handler_err
dlq = auth_fail  # auth failures go to DLQ per RC-4
print(json.dumps({
    "events_handled": handled,
    "auth_failures": auth_fail,
    "schema_failures": schema_fail,
    "handler_errors": handler_err,
    "total": total,
    "dlq_depth": dlq
}))
conn.close()
PY
)"
  else
    AUDIT_METRICS='{"events_handled":0,"auth_failures":0,"schema_failures":0,"handler_errors":0,"total":0,"dlq_depth":0}'
  fi
  cat <<RESULT
{"ok":true,"manual_n8n":true,"stream_id":"$STREAM_ID","note":"N8N_API_KEY not set; metrics derived from audit-bus only. For full health (success_rate, latencies), invoke n8n_list_executions + n8n_get_workflow_details via MCP from Claude Code context.","window_seconds":$WINDOW_SECONDS,"measured_at":"$MEASURED_AT","health_metrics":$(printf '%s' "$AUDIT_METRICS" | python3 -c "
import json,sys
m=json.load(sys.stdin)
total = m['total'] if m['total']>0 else 1
fail = m['auth_failures'] + m['schema_failures'] + m['handler_errors']
out = {
    'success_rate': round(m['events_handled']/total, 4) if m['total']>0 else None,
    'avg_latency_ms': None,
    'p99_latency_ms': None,
    'error_rate': round(fail/total, 4) if m['total']>0 else None,
    'throughput_per_min': round(m['total'] / (${WINDOW_SECONDS}/60.0), 4),
    'dlq_depth': m['dlq_depth'],
    'sla_status': 'unknown',
    'measured_at': '${MEASURED_AT}',
    'window_seconds': ${WINDOW_SECONDS}
}
print(json.dumps(out))
")}
RESULT
  audit_emit "stream.health_checked" "$(printf '{"stream_id":"%s","mode":"audit_only"}' "$STREAM_ID")" >/dev/null
  exit 0
fi

# Live n8n path.
EXEC_RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' \
  "$N8N_URL/api/v1/executions?workflowId=$STREAM_ID&limit=100" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" 2>&1 || true)"
HTTP_CODE="$(printf '%s' "$EXEC_RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"
BODY="$(printf '%s' "$EXEC_RESP" | sed -e 's/__HTTP__:[0-9]*$//')"

case "$HTTP_CODE" in
  401|403)
    audit_emit "stream.n8n_unauthorized" "$(printf '{"tool":"list_executions","http_status":%s}' "$HTTP_CODE")" >/dev/null
    err_json "KER-SI-004" "n8n unauthorized — no retry per RC-9"
    exit 2
    ;;
  404)
    err_json "KER-SE-001" "stream not found: $STREAM_ID"
    exit 1
    ;;
  200) ;;
  *)
    err_json "KER-SI-001" "n8n list_executions failed HTTP ${HTTP_CODE:-0}"
    exit 1
    ;;
esac

METRICS="$(printf '%s' "$BODY" | WINDOW_SECONDS="$WINDOW_SECONDS" MEASURED_AT="$MEASURED_AT" python3 <<'PY'
import json, os, sys
b = sys.stdin.read()
try:
    d = json.loads(b)
except Exception:
    print(json.dumps({"_error":"bad list_executions response"})); sys.exit(0)
execs = d.get("data", []) if isinstance(d, dict) else d
total = len(execs)
success = sum(1 for e in execs if e.get("finished") and not e.get("stoppedAt") and (e.get("status") in ("success", None) or e.get("mode") in ("success",)))
failed = sum(1 for e in execs if e.get("status") in ("error","failed","crashed") or e.get("stoppedAt"))
latencies = []
for e in execs:
    sa = e.get("startedAt")
    fa = e.get("stoppedAt") or e.get("finishedAt")
    if sa and fa:
        try:
            import datetime
            t0 = datetime.datetime.fromisoformat(sa.replace("Z","+00:00"))
            t1 = datetime.datetime.fromisoformat(fa.replace("Z","+00:00"))
            latencies.append((t1-t0).total_seconds()*1000)
        except Exception:
            pass
latencies.sort()
avg = sum(latencies)/len(latencies) if latencies else None
p99 = latencies[int(len(latencies)*0.99)] if latencies else None
window_s = int(os.environ["WINDOW_SECONDS"])
out = {
    "success_rate": round(success/total,4) if total else None,
    "avg_latency_ms": round(avg,2) if avg is not None else None,
    "p99_latency_ms": round(p99,2) if p99 is not None else None,
    "error_rate": round(failed/total,4) if total else None,
    "throughput_per_min": round(total/(window_s/60.0),4),
    "dlq_depth": failed,
    "sla_status": ("healthy" if (success/total>=0.99 if total else False)
                    else "degraded" if (success/total>=0.95 if total else False)
                    else "breach" if total else "unknown"),
    "measured_at": os.environ["MEASURED_AT"],
    "window_seconds": window_s,
    "_observed_executions": total
}
print(json.dumps(out))
PY
)"

audit_emit "stream.health_checked" "$(printf '{"stream_id":"%s"}' "$STREAM_ID")" >/dev/null
printf '{"ok":true,"stream_id":"%s","health_metrics":%s}\n' "$STREAM_ID" "$METRICS"
exit 0
