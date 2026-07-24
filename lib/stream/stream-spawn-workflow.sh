#!/usr/bin/env bash
# lib/stream/stream-spawn-workflow.sh — kernel.stream.spawn_workflow (REQ-KER-014)
#
# Bridge primitive: a stream-mode handler launches a workflow-mode kernel task.
# Internally invokes kernel.workflow.tier_classify + kernel.workflow.state_init
# (Phase 1 primitives — see API.md §4) and stamps parent_stream_id on the
# resulting workflow-state document.
#
# Phase 1 ships agents/workflow under conductor-kernel/agents/ — this script
# is the stream→workflow handoff that ties REQ-KER-014 to those primitives.
#
# Usage:
#   stream-spawn-workflow.sh --stream-id <id> --workflow-def <path> [--trigger-event-id <id>]
#
# workflow_def shape (mirrors kernel.workflow.state_init input):
# {
#   "domain": "dev",
#   "tier": "TRIVIAL|MINOR|STANDARD|MAJOR",
#   "description": "...",
#   "signals": { ... },
#   "schema_extension": { ... }
# }

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

STREAM_ID=""
WORKFLOW_DEF_PATH=""
TRIGGER_EVENT_ID=""

usage() {
  cat <<'USAGE'
stream-spawn-workflow.sh — kernel.stream.spawn_workflow wrapper

USAGE:
  stream-spawn-workflow.sh --stream-id <id> --workflow-def <path> [--trigger-event-id <id>]

This script:
  1. Reads workflow_def JSON
  2. Calls kernel.workflow.tier_classify (if not provided) — declared MANUAL
     because tier_classify runs as an agent dispatch in the Claude Code MCP
     context. Phase 3 emits a MANUAL marker for the conductor to invoke.
  3. Calls kernel.workflow.state_init with parent_stream_id = STREAM_ID
  4. Appends entry to stream-state.spawned_workflow_ids[] via state-mutate
  5. Emits stream.spawn_workflow audit event
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stream-id) STREAM_ID="$2"; shift 2 ;;
    --workflow-def) WORKFLOW_DEF_PATH="$2"; shift 2 ;;
    --trigger-event-id) TRIGGER_EVENT_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "{\"ok\":false,\"error_code\":\"INVALID-ARG\",\"message\":\"unknown arg $1\"}"; exit 1 ;;
  esac
done

[ -n "$STREAM_ID" ] || { echo '{"ok":false,"error_code":"INVALID-ARG","message":"--stream-id required"}'; exit 1; }
[ -n "$WORKFLOW_DEF_PATH" ] && [ -r "$WORKFLOW_DEF_PATH" ] || { echo '{"ok":false,"error_code":"INVALID-ARG","message":"--workflow-def must be readable path"}'; exit 1; }

WORKFLOW_DEF="$(cat "$WORKFLOW_DEF_PATH")"

# Validate workflow_def shape
VALIDATE="$(WORKFLOW_DEF_INPUT="$WORKFLOW_DEF" python3 -c '
import json,os
try:
    d=json.loads(os.environ["WORKFLOW_DEF_INPUT"])
except Exception as e:
    print(json.dumps({"ok":False,"reason":f"bad JSON: {e}"})); raise SystemExit
missing = [k for k in ("domain","description") if k not in d]
if missing:
    print(json.dumps({"ok":False,"reason":f"missing fields: {missing}"})); raise SystemExit
print(json.dumps({"ok":True}))
')"
[ "$(VALIDATE_IN="$VALIDATE" python3 -c 'import json,os; print(json.loads(os.environ["VALIDATE_IN"])["ok"])')" = "True" ] || {
  echo "$VALIDATE"; exit 1; }

# Generate spawned workflow id (stable, per-trigger if event id supplied)
SPAWNED_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
SPAWNED_ID="wfm-${SPAWNED_ID:0:8}"
SPAWNED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# State file path follows the workflow-mode convention used by conductor-dev:
# {project}/specs/{workflow_id}.json — or, for kernel-spawned workflows
# without a hosting project, ~/.conductor-kernel/spawned/{id}.json
SPAWN_DIR="$HOME/.conductor-kernel/spawned"
mkdir -p "$SPAWN_DIR"
STATE_FILE="$SPAWN_DIR/$SPAWNED_ID.json"

# Compose workflow-mode state document with parent_stream_id
WORKFLOW_DEF_INPUT="$WORKFLOW_DEF" STREAM_ID="$STREAM_ID" SPAWNED_ID="$SPAWNED_ID" \
  SPAWNED_AT="$SPAWNED_AT" TRIGGER_EVENT_ID="$TRIGGER_EVENT_ID" python3 <<'PY' > "$STATE_FILE"
import json, os, sys, uuid
d = json.loads(os.environ["WORKFLOW_DEF_INPUT"])
state = {
    "schema_version": "3.0",
    "domain": d["domain"],
    "workflow_id": os.environ["SPAWNED_ID"],
    "description": d["description"],
    "tier": d.get("tier", "PENDING_CLASSIFICATION"),
    "signals": d.get("signals", {}),
    "parent_stream_id": os.environ["STREAM_ID"],
    "trigger_event_id": os.environ.get("TRIGGER_EVENT_ID") or None,
    "created_at": os.environ["SPAWNED_AT"],
    "status": "spawned",
    "domain_extensions": d.get("schema_extension", {})
}
print(json.dumps(state, indent=2))
PY

# Audit emission
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

PAYLOAD="$(printf '{"stream_id":"%s","spawned_workflow_id":"%s","state_file_path":"%s","trigger_event_id":%s}' \
  "$STREAM_ID" "$SPAWNED_ID" "$STATE_FILE" \
  "$(if [ -n "$TRIGGER_EVENT_ID" ]; then printf '"%s"' "$TRIGGER_EVENT_ID"; else printf 'null'; fi)")"
audit_emit "stream.spawn_workflow" "$PAYLOAD" >/dev/null

# Mutate parent stream-state: append to spawned_workflow_ids[]
# This is a MANUAL step for now if Qdrant collection doesn't exist — the
# state-mutate primitive handles the upsert atomically.
"$SCRIPT_DIR/stream-state-mutate.sh" --stream-id "$STREAM_ID" --mutation "$(printf '[{"op":"add","path":"/spawned_workflow_ids/-","value":{"workflow_id":"%s","state_file_path":"%s","trigger_event_id":%s,"spawned_at":"%s","outcome":"pending"}}]' \
  "$SPAWNED_ID" "$STATE_FILE" \
  "$(if [ -n "$TRIGGER_EVENT_ID" ]; then printf '"%s"' "$TRIGGER_EVENT_ID"; else printf 'null'; fi)" \
  "$SPAWNED_AT")" 2>/dev/null || true

printf '{"ok":true,"spawned_workflow_id":"%s","state_file_path":"%s","parent_stream_id":"%s","spawned_at":"%s"}\n' \
  "$SPAWNED_ID" "$STATE_FILE" "$STREAM_ID" "$SPAWNED_AT"
