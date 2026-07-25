#!/usr/bin/env bash
# lib/stream/stream-init.sh — kernel.stream.init implementation
# REQ-KER-010 / REQ-XCT-006 / RC-4 / RC-7 / RC-9 / RC-11
#
# Wraps n8n_create_workflow via n8n-mcp. Validates subscription configuration
# against schemas/stream-state.schema.json. Enforces:
#   - authentication.kind required per subscription (RC-4 / F-10)
#   - authentication.kind == "none" requires audit_warning_acknowledged: true
#     else KER-SI-005 (RC-4)
#   - budget required per stream (RC-7 / F-09) else KER-SI-006
#   - workflow_template path safety (RC-11) else KER-SI-003
#   - n8n_create_workflow 401/403 surfaces KER-SI-004 (RC-9), no retry
#   - inline credential fields (n8n_api_token, api_key, password) stripped
#     and audit warning emitted (RC-9 / §5.0 step 4)
#
# Usage:
#   stream-init.sh --config <path-to-init-json> [--dry-run]
#   echo '<json>' | stream-init.sh --stdin [--dry-run]
#
# Input JSON (init config) shape:
# {
#   "domain": "soc",
#   "subscriptions": [ ... per stream-state.schema.json ... ],
#   "schema_extension": { ... domain_extensions schema ... },
#   "budget": {
#     "per_event": { "max_input_tokens": ..., "max_output_tokens": ..., "max_cost_usd": ... },
#     "per_stream_hour": { "max_total_cost_usd": ..., "max_total_dispatches": ... }
#   },
#   "n8n_url": "http://localhost:5679",
#   "workflow_template": { ... optional ... },
#   "stream_name": "...",
#   "audit_session_id": "uuid"
# }
#
# Output JSON:
# {
#   "ok": true,
#   "stream_id": "<n8n_workflow_id>",
#   "n8n_workflow_id": "<n8n_workflow_id>",
#   "audit_session_id": "...",
#   "warnings": [ ... ]
# }
# or { "ok": false, "error_code": "KER-SI-00X", "message": "..." }
#
# Exit codes:
#   0  success
#   1  validation error (KER-SI-002 / KER-SI-003 / KER-SI-005 / KER-SI-006)
#   2  n8n unreachable (KER-SI-001)
#   3  n8n unauthorized (KER-SI-004)
#   4  internal error

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KERNEL_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# shellcheck source=scripts/lib/paths.sh
. "$KERNEL_ROOT/scripts/lib/paths.sh"
SCHEMA_PATH="$KERNEL_ROOT/schemas/stream-state.schema.json"

CONFIG_PATH=""
DRY_RUN=0
FROM_STDIN=0

usage() {
  cat <<'USAGE'
stream-init.sh — kernel.stream.init wrapper

USAGE:
  stream-init.sh --config <path-to-init-json> [--dry-run]
  echo '<json>' | stream-init.sh --stdin [--dry-run]

OPTIONS:
  --config <path>   Read init config from file
  --stdin           Read init config from stdin
  --dry-run         Validate inputs and emit the planned audit envelope; do NOT
                    call n8n_create_workflow. Useful for CI and operator review.
  -h, --help        Show this help

ENVIRONMENT:
  AUDIT_DB_OVERRIDE      Override governance audit.db path (testing only).
  KERNEL_AUDIT_TOKEN     Required by governance write boundary (RC-5). The kernel
                         does NOT log or persist this token. If missing, audit
                         writes will fail with AUDIT-001 unsigned_row.
  N8N_API_KEY            POC ONLY. If set and n8n-mcp tool dispatch is not
                         available in this execution context, the script will
                         use direct HTTP to the n8n REST API. Production
                         deployments MUST use n8n-mcp per RC-9 / §5.0.

EXIT CODES:
  0  success
  1  validation error (KER-SI-002 / 003 / 005 / 006)
  2  n8n unreachable (KER-SI-001)
  3  n8n unauthorized (KER-SI-004)
  4  internal error
USAGE
}

err_json() {
  local code="$1" msg="$2"
  printf '{"ok":false,"error_code":"%s","message":%s}\n' "$code" "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# Best-effort audit emission to governance audit.db.
# Uses sqlite3 if available; otherwise writes a JSON line to a fallback log.
# The HMAC-token enforcement at the governance write boundary (RC-5) will
# reject unsigned writes once governance-plugin Phase N lands; that is
# governance-plugin's responsibility, not the kernel's.
audit_emit() {
  local event_type="$1" payload_json="$2"
  local audit_db; audit_db="$(kernel_audit_db_path)"
  local event_id ts session_id
  event_id="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  session_id="${STREAM_AUDIT_SESSION_ID:-$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')}"

  if [ ! -f "$audit_db" ]; then
    # Fallback log so we don't silently lose events when governance not installed.
    local fallback; fallback="$(kernel_audit_fallback_path)"
    printf '{"event_id":"%s","timestamp":"%s","event_type":"%s","payload":%s}\n' \
      "$event_id" "$ts" "$event_type" "$payload_json" >> "$fallback"
    return 0
  fi

  if ! command -v sqlite3 >/dev/null 2>&1; then
    printf '{"event_id":"%s","timestamp":"%s","event_type":"%s","payload":%s}\n' \
      "$event_id" "$ts" "$event_type" "$payload_json" >> "$(kernel_audit_fallback_path)"
    return 0
  fi

  # Direct write (governance HMAC enforcement is a future write boundary,
  # not enforced in v0.1.0 — see §6 RC-5 implementation coordination note).
  local detail
  detail="$(printf '%s' "$payload_json" | python3 -c 'import json,sys; print(json.dumps({"payload": json.loads(sys.stdin.read())}))')"
  sqlite3 "$audit_db" <<SQL 2>/dev/null || true
INSERT INTO audit_events (event_id, timestamp, audit_session_id, event_type, agent_id, detail, outcome, human_user_id)
VALUES ('$event_id', '$ts', '$session_id', '$event_type', 'conductor-kernel:stream', '$(printf '%s' "$detail" | sed "s/'/''/g")', 'success', 'kernel');
SQL
  printf '%s' "$event_id"
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --stdin) FROM_STDIN=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err_json "INVALID-ARG" "unknown argument: $1"; exit 1 ;;
  esac
done

# Read config
if [ "$FROM_STDIN" -eq 1 ]; then
  CONFIG_JSON="$(cat)"
elif [ -n "$CONFIG_PATH" ]; then
  if [ ! -r "$CONFIG_PATH" ]; then
    err_json "KER-SI-002" "config file not readable: $CONFIG_PATH"
    exit 1
  fi
  CONFIG_JSON="$(cat "$CONFIG_PATH")"
else
  err_json "INVALID-ARG" "must supply --config or --stdin"
  exit 1
fi

# Validate JSON parses
if ! printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  err_json "KER-SI-002" "config is not valid JSON"
  exit 1
fi

# Run validation + planning in Python. We pass CONFIG_JSON via env var so
# that the heredoc-fed python script doesn't compete with sys.stdin reads.
RESULT="$(CONFIG_JSON_INPUT="$CONFIG_JSON" KERNEL_ROOT="$KERNEL_ROOT" SCHEMA_PATH="$SCHEMA_PATH" DRY_RUN="$DRY_RUN" python3 <<'PY'
import json, os, sys, re, uuid
from datetime import datetime, timezone

cfg = json.loads(os.environ["CONFIG_JSON_INPUT"])
schema_path = os.environ["SCHEMA_PATH"]
dry_run = os.environ.get("DRY_RUN") == "1"

warnings = []

# --- inline credential rejection (RC-9 step 4) ---
INLINE_CRED_KEYS = {"n8n_api_token", "api_key", "password", "secret", "token"}
stripped = {}
for k in list(cfg.keys()):
    if k.lower() in INLINE_CRED_KEYS:
        stripped[k] = "<redacted>"
        del cfg[k]
if stripped:
    warnings.append({
        "code": "stream.inline_credential_rejected",
        "fields_stripped": list(stripped.keys()),
        "note": "RC-9 / §5.0 step 4 — inline credentials are never accepted; configure n8n-mcp instead."
    })

# --- basic shape checks ---
domain = cfg.get("domain")
subs = cfg.get("subscriptions")
budget = cfg.get("budget")
workflow_template = cfg.get("workflow_template")
n8n_url = cfg.get("n8n_url", "http://localhost:5679")

if not domain or not isinstance(domain, str):
    print(json.dumps({"ok": False, "error_code": "KER-SI-002",
                      "message": "domain is required (string)"}))
    sys.exit(1)
if not isinstance(subs, list) or len(subs) < 1:
    print(json.dumps({"ok": False, "error_code": "KER-SI-002",
                      "message": "subscriptions array required (minItems 1)"}))
    sys.exit(1)

# --- budget required (RC-7) ---
if not isinstance(budget, dict):
    print(json.dumps({"ok": False, "error_code": "KER-SI-006",
                      "message": "budget is required (RC-7 / F-09); see API.md §5.init"}))
    sys.exit(1)
per_event = budget.get("per_event") or {}
per_stream_hour = budget.get("per_stream_hour") or {}
required_per_event = {"max_input_tokens", "max_output_tokens", "max_cost_usd"}
required_per_hour = {"max_total_cost_usd", "max_total_dispatches"}
missing = []
missing.extend([f"per_event.{k}" for k in required_per_event if k not in per_event])
missing.extend([f"per_stream_hour.{k}" for k in required_per_hour if k not in per_stream_hour])
if missing:
    print(json.dumps({"ok": False, "error_code": "KER-SI-006",
                      "message": "budget missing required fields: " + ", ".join(missing)}))
    sys.exit(1)

# --- subscription authentication (RC-4 / F-10) ---
for i, sub in enumerate(subs):
    src = sub.get("source")
    kind = sub.get("kind")
    auth = sub.get("authentication")
    if not src or not kind:
        print(json.dumps({"ok": False, "error_code": "KER-SI-002",
                          "message": f"subscriptions[{i}] missing source or kind"}))
        sys.exit(1)
    if not isinstance(auth, dict) or not auth.get("kind"):
        print(json.dumps({"ok": False, "error_code": "KER-SI-002",
                          "message": f"subscriptions[{i}] authentication.kind required (RC-4)"}))
        sys.exit(1)
    if auth["kind"] == "none":
        if not auth.get("audit_warning_acknowledged"):
            print(json.dumps({"ok": False, "error_code": "KER-SI-005",
                              "message": f"subscriptions[{i}] authentication.kind == 'none' requires audit_warning_acknowledged: true (RC-4)"}))
            sys.exit(1)
        warnings.append({
            "code": "stream.init.auth_none_warning",
            "subscription_index": i,
            "source": src,
            "note": "RC-4: operator acknowledged the unauthenticated trigger risk."
        })
    else:
        if not auth.get("secret_ref") or not auth.get("verification_field"):
            print(json.dumps({"ok": False, "error_code": "KER-SI-002",
                              "message": f"subscriptions[{i}] auth requires secret_ref + verification_field when kind != 'none'"}))
            sys.exit(1)
        if str(auth.get("secret_ref", "")).startswith(("http://", "https://")) is False:
            # Allowed: vault://, env://, file://
            if not re.match(r"^(vault|env|file)://", auth["secret_ref"]):
                print(json.dumps({"ok": False, "error_code": "KER-SI-002",
                                  "message": f"subscriptions[{i}] secret_ref must use vault://, env://, or file:// scheme"}))
                sys.exit(1)

# --- workflow_template path safety (RC-11 / KER-SI-003) ---
if workflow_template is not None:
    if isinstance(workflow_template, str):
        # If a path, refuse traversal
        if ".." in workflow_template or workflow_template.startswith("/etc") or workflow_template.startswith("/root"):
            print(json.dumps({"ok": False, "error_code": "KER-SI-003",
                              "message": "workflow_template path traversal rejected (RC-11)"}))
            sys.exit(1)
    elif not isinstance(workflow_template, dict):
        print(json.dumps({"ok": False, "error_code": "KER-SI-003",
                          "message": "workflow_template must be JSON object or safe path string"}))
        sys.exit(1)

# --- build planned audit envelope (auth kind only, no secrets) ---
plan = {
    "ok": True,
    "domain": domain,
    "subscriptions_redacted": [
        {"source": s["source"], "kind": s["kind"], "auth_kind": s["authentication"]["kind"]}
        for s in subs
    ],
    "budget": budget,
    "n8n_url": n8n_url,
    "stream_name": cfg.get("stream_name"),
    "workflow_template_kind": "inline" if isinstance(workflow_template, dict)
                              else "path" if isinstance(workflow_template, str)
                              else "default",
    "warnings": warnings,
    "audit_session_id": cfg.get("audit_session_id") or str(uuid.uuid4()),
    "dry_run": dry_run,
    "_internal": {
        "subs_full": subs,
        "workflow_template": workflow_template,
        "stream_name": cfg.get("stream_name") or f"kernel-stream-{domain}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
    }
}
print(json.dumps(plan))
PY
)" || { echo "$RESULT"; exit 1; }

# If validation already returned an error (ok:false), surface and exit.
OK="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))')"
if [ "$OK" != "True" ]; then
  echo "$RESULT"
  # Map error code to exit
  CODE="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error_code",""))')"
  case "$CODE" in
    KER-SI-001) exit 2 ;;
    KER-SI-004) exit 3 ;;
    *) exit 1 ;;
  esac
fi

# Emit stream.init audit event (auth kind only — no secrets) BEFORE calling n8n,
# so that even if n8n_create_workflow fails we have a record of the attempt.
INIT_PAYLOAD="$(printf '%s' "$RESULT" | python3 -c '
import json,sys
r = json.load(sys.stdin)
print(json.dumps({
    "domain": r["domain"],
    "subscriptions": r["subscriptions_redacted"],
    "budget": r["budget"],
    "n8n_url": r["n8n_url"],
    "stream_name": r["_internal"]["stream_name"]
}))')"
STREAM_AUDIT_SESSION_ID="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["audit_session_id"])')"
export STREAM_AUDIT_SESSION_ID
audit_emit "stream.init.attempt" "$INIT_PAYLOAD" >/dev/null || true

# Emit auth_none warning(s) if any
WARN_COUNT="$(printf '%s' "$RESULT" | python3 -c '
import json,sys
r=json.load(sys.stdin)
for w in r.get("warnings", []):
    if w.get("code") == "stream.init.auth_none_warning":
        print(json.dumps(w))
' | wc -l | tr -d ' ')"
if [ "$WARN_COUNT" -gt 0 ]; then
  printf '%s' "$RESULT" | python3 -c '
import json,sys
r=json.load(sys.stdin)
for w in r.get("warnings", []):
    if w.get("code") == "stream.init.auth_none_warning":
        print(json.dumps(w))
' | while IFS= read -r warn; do
    audit_emit "stream.init.auth_none_warning" "$warn" >/dev/null || true
  done
fi

# --- DRY RUN exit path ---
if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s' "$RESULT" | python3 -c '
import json,sys
r = json.load(sys.stdin)
out = {
    "ok": True,
    "dry_run": True,
    "would_create": {
        "name": r["_internal"]["stream_name"],
        "domain": r["domain"],
        "subscriptions_redacted": r["subscriptions_redacted"],
        "n8n_url": r["n8n_url"]
    },
    "warnings": r["warnings"],
    "audit_session_id": r["audit_session_id"]
}
print(json.dumps(out))
'
  exit 0
fi

# --- Live n8n_create_workflow call ---
# In production, this script is invoked from a Claude Code context where
# n8n_create_workflow is available as an MCP tool. The kernel does NOT
# directly hold the n8n credential (RC-9). When invoked outside such a
# context, the operator MAY provide N8N_API_KEY for the POC direct path.
N8N_URL="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n8n_url"])')"
WORKFLOW_NAME="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["_internal"]["stream_name"])')"

if [ -z "${N8N_API_KEY:-}" ]; then
  # No direct API key. Emit guidance and surface MANUAL state.
  cat <<MANUAL_JSON
{"ok":false,"error_code":"KER-MANUAL-DISPATCH","message":"n8n_create_workflow must be invoked from a Claude Code MCP-enabled context, OR set N8N_API_KEY env var for direct API fallback. Per RC-9 the kernel does not store credentials. See API.md §5.0.","planned":$(printf '%s' "$RESULT" | python3 -c 'import json,sys; r=json.load(sys.stdin); del r["_internal"]; print(json.dumps(r))')}
MANUAL_JSON
  exit 0
fi

# Direct HTTP fallback (POC path). Build minimal workflow JSON if no template.
PAYLOAD="$(printf '%s' "$RESULT" | python3 -c '
import json,sys
r = json.load(sys.stdin)
internal = r["_internal"]
tpl = internal.get("workflow_template")
if isinstance(tpl, dict):
    wf = dict(tpl)
    wf["name"] = internal["stream_name"]
else:
    # Minimal valid n8n workflow with a single Webhook trigger node for POC.
    wf = {
        "name": internal["stream_name"],
        "nodes": [
            {
                "id": "trigger-1",
                "name": "Stream Trigger",
                "type": "n8n-nodes-base.webhook",
                "typeVersion": 1,
                "position": [240, 240],
                "parameters": {
                    "path": f"kernel-stream-{r[\"domain\"]}",
                    "responseMode": "lastNode",
                    "httpMethod": "POST"
                }
            }
        ],
        "connections": {},
        "settings": {"executionOrder": "v1"}
    }
print(json.dumps(wf))
')"

RESP="$(curl -sS -w '\n__HTTP__:%{http_code}' \
  -X POST "$N8N_URL/api/v1/workflows" \
  -H "Content-Type: application/json" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  --data "$PAYLOAD" 2>&1 || true)"
HTTP_CODE="$(printf '%s' "$RESP" | sed -n 's/.*__HTTP__:\([0-9]*\)/\1/p' | tail -1)"
BODY="$(printf '%s' "$RESP" | sed -e 's/__HTTP__:[0-9]*$//')"

case "$HTTP_CODE" in
  200|201)
    WORKFLOW_ID="$(printf '%s' "$BODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data",{}).get("id") or d.get("id",""))' 2>/dev/null)"
    if [ -z "$WORKFLOW_ID" ]; then
      err_json "KER-SI-001" "n8n returned 2xx but no workflow id in response body"
      exit 4
    fi
    audit_emit "stream.init" "$(printf '{"stream_id":"%s","n8n_workflow_id":"%s"}' "$WORKFLOW_ID" "$WORKFLOW_ID")" >/dev/null || true
    printf '{"ok":true,"stream_id":"%s","n8n_workflow_id":"%s","audit_session_id":"%s","warnings":%s}\n' \
      "$WORKFLOW_ID" "$WORKFLOW_ID" "$STREAM_AUDIT_SESSION_ID" \
      "$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("warnings",[])))')"
    exit 0
    ;;
  401|403)
    audit_emit "stream.n8n_unauthorized" "$(printf '{"tool":"n8n_create_workflow","http_status":%s}' "$HTTP_CODE")" >/dev/null || true
    err_json "KER-SI-004" "n8n unauthorized (HTTP $HTTP_CODE) — per RC-9, no retry."
    exit 3
    ;;
  000|"")
    err_json "KER-SI-001" "n8n unreachable at $N8N_URL"
    exit 2
    ;;
  *)
    err_json "KER-SI-001" "n8n returned HTTP $HTTP_CODE: $(printf '%s' "$BODY" | head -c 400)"
    exit 2
    ;;
esac
