#!/usr/bin/env bash
# code-mode-dispatch.sh — Hermes E3 code-mode dispatch helper.
#
# Conductor invokes this script during fan-out to prepare a code-mode
# dispatch. Given (agent name, task JSON, tool surface, output schema), the
# helper:
#   1. Validates the inputs (CISO-002 §3.6: tool surface MUST be MCP-only).
#   2. Reads conductor-state.json.intent and assembles the constraint envelope.
#   3. Computes the envelope hash via shasum -a 256.
#   4. Renders lib/code-mode-template.js by substituting all <<PLACEHOLDER>>
#      tokens.
#   5. Emits a structured JSON object on stdout:
#        {
#          "registered_tool_name": "code-mode-<unique>",
#          "javascript_source":    "<full JS program>",
#          "envelope_hash":        "sha256:<hex>",
#          "expected_servers":     [<mcp servers including code-mode-audit>]
#        }
#      The conductor consumes that object and performs the actual
#      `mcp__MCP_DOCKER__code-mode` registration + `code-mode-<unique>`
#      invocation via its own MCP tool calls.
#
# Usage:
#   code-mode-dispatch.sh \
#     --agent <name> \
#     --task <path-to-task-json> \
#     --tool-surface <comma-list-of-mcp-tools> \
#     --output-schema <path-to-schema.json> \
#     [--state-file <path-to-conductor-state.json>]
#
# Exit codes (per spec §2):
#   0 success
#   1 invalid task JSON / missing required field
#   2 tool surface includes non-MCP tools
#   3 envelope assembly failed (intent block missing or malformed)
#   4 template rendering failed (placeholder leak)

set -euo pipefail

# ---------- Constants ----------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_PATH="${SCRIPT_DIR}/lib/code-mode-template.js"
readonly AUDIT_MCP_SERVER_NAME="code-mode-audit"   # registered by operator
readonly DEFAULT_STATE_FILE="conductor-state.json"

# ---------- Arg parsing ----------

AGENT=""
TASK_FILE=""
TOOL_SURFACE=""
OUTPUT_SCHEMA=""
STATE_FILE="${DEFAULT_STATE_FILE}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)         AGENT="$2";          shift 2 ;;
    --task)          TASK_FILE="$2";      shift 2 ;;
    --tool-surface)  TOOL_SURFACE="$2";   shift 2 ;;
    --output-schema) OUTPUT_SCHEMA="$2";  shift 2 ;;
    --state-file)    STATE_FILE="$2";     shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0" >&2
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

# ---------- Required-arg gate ----------

for var in AGENT TASK_FILE TOOL_SURFACE OUTPUT_SCHEMA; do
  if [[ -z "${!var}" ]]; then
    printf 'missing required arg: --%s\n' "$(tr '[:upper:]' '[:lower:]' <<<"${var//_/-}")" >&2
    exit 1
  fi
done

# ---------- Dependency check ----------

for cmd in jq shasum python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'missing required dependency: %s\n' "$cmd" >&2
    exit 1
  fi
done

# ---------- Step 1: Validate task JSON ----------

if [[ ! -r "${TASK_FILE}" ]]; then
  printf 'task file not readable: %s\n' "${TASK_FILE}" >&2
  exit 1
fi

# Required task fields: trajectory_id, steps (deterministic pipeline marker).
if ! jq -e '.trajectory_id and (.steps | type == "array")' "${TASK_FILE}" >/dev/null 2>&1; then
  printf 'task JSON missing required fields (trajectory_id, steps[]): %s\n' "${TASK_FILE}" >&2
  exit 1
fi

TRAJECTORY_ID="$(jq -r '.trajectory_id' "${TASK_FILE}")"

# ---------- Step 2: Validate tool surface is MCP-only ----------

# Allow only tool names starting with "mcp__" or matching the prefix patterns
# of registered MCP servers (e.g., "siem__", "edr__"). Block Task, Skill,
# Bash, raw Read/Write/Edit — those are NOT code-mode-eligible per spec §1
# selector logic.
IFS=',' read -ra TOOL_LIST <<<"${TOOL_SURFACE}"
NON_MCP_TOOLS=()
for tool in "${TOOL_LIST[@]}"; do
  tool="${tool// /}"  # strip whitespace
  if [[ -z "${tool}" ]]; then continue; fi
  case "${tool}" in
    mcp__*|*__*)   ;;  # accept: MCP-prefixed or server__tool format
    *)             NON_MCP_TOOLS+=("${tool}") ;;
  esac
done

if (( ${#NON_MCP_TOOLS[@]} > 0 )); then
  printf 'tool surface includes non-MCP tools: %s\n' "${NON_MCP_TOOLS[*]}" >&2
  exit 2
fi

# ---------- Step 3: Read intent + assemble envelope ----------

if [[ ! -r "${STATE_FILE}" ]]; then
  printf 'state file not readable: %s\n' "${STATE_FILE}" >&2
  exit 3
fi

# The constraint envelope content is the canonical Markdown block from
# conductor.md "## ACTIVE CONSTRAINTS (auto-injected by conductor)". Here we
# render the same content but as the BODY of a /* */ comment — the leading
# `/* ## ACTIVE CONSTRAINTS ... */` wrapper is added by the template
# substitution step.
INTENT_JSON="$(jq -c '.intent // empty' "${STATE_FILE}")"
if [[ -z "${INTENT_JSON}" || "${INTENT_JSON}" == "null" ]]; then
  printf 'state.intent missing or empty in %s\n' "${STATE_FILE}" >&2
  exit 3
fi

# Build the envelope block by extracting hard_limits[], prohibited_behaviors[],
# objectives[] (top 3 by priority), and trade_offs[]. Each line is prefixed
# with " * " so it nests cleanly inside the /* */ comment we wrap later.
ENVELOPE_BLOCK="$(
  jq -r '
    [
      " * ### Hard Limits (inviolable)",
      (.hard_limits // [] | map(" * - " + .) | join("\n")),
      " *",
      " * ### Prohibited Behaviors (immediate stop)",
      (.prohibited_behaviors // [] | map(" * - " + .) | join("\n")),
      " *",
      " * ### Active Objectives (ranked)",
      (.objectives // [] | sort_by(-(.priority // 0)) | .[0:3]
        | to_entries | map(" * " + ((.key + 1) | tostring) + ". " + (.value.goal // "")) | join("\n")),
      " *",
      " * ### Trade-Off Resolutions",
      (.trade_offs // [] | map(" * - When " + (.dimension_a // "?") + " conflicts with " + (.dimension_b // "?") + ": " + (.resolution // "?")) | join("\n"))
    ] | join("\n")
  ' <<<"${INTENT_JSON}"
)"

# Prefer the live envelope_hash from state.intent if present (it is the
# authoritative source per critic regex /\(Envelope hash:\s*(sha256:[a-f0-9]{64})\)/);
# otherwise compute one from the counts to preserve the existing format.
ENVELOPE_HASH="$(jq -r '.envelope_hash // empty' <<<"${INTENT_JSON}")"
if [[ -z "${ENVELOPE_HASH}" ]]; then
  HARD_COUNT="$(jq -r '(.hard_limits // []) | length' <<<"${INTENT_JSON}")"
  PROHIB_COUNT="$(jq -r '(.prohibited_behaviors // []) | length' <<<"${INTENT_JSON}")"
  OBJ_COUNT="$(jq -r '(.objectives // []) | length' <<<"${INTENT_JSON}")"
  RAW_HASH="$(printf 'hard_limits_count:%s,prohibited_behaviors_count:%s,objectives_count:%s' \
              "${HARD_COUNT}" "${PROHIB_COUNT}" "${OBJ_COUNT}" \
              | shasum -a 256 | cut -d' ' -f1)"
  ENVELOPE_HASH="sha256:${RAW_HASH}"
fi

# ---------- Step 4: Render template ----------

if [[ ! -r "${TEMPLATE_PATH}" ]]; then
  printf 'template not readable: %s\n' "${TEMPLATE_PATH}" >&2
  exit 4
fi

# Build per-task tool calls block from task.steps[].
# Each step is expected to be {tool, args} where tool is fully qualified
# (e.g., "siem__query") and args is a JSON object.
PER_TASK_CALLS="$(
  jq -r '
    (.steps // [])
    | to_entries
    | map(
        "    const step_" + (.key | tostring) + " = await "
        + (.value.tool // "noop") + "("
        + ((.value.args // {}) | tojson) + ");"
      )
    | join("\n")
  ' "${TASK_FILE}"
)"

# Build output schema shape from the schema file (jq dumps the top-level
# `properties` keys as a comma-separated JS-object stub).
if [[ -r "${OUTPUT_SCHEMA}" ]]; then
  OUTPUT_SHAPE="$(
    jq -r '
      (.properties // {}) | keys
      | map("      " + . + ": null,")
      | join("\n")
    ' "${OUTPUT_SCHEMA}" 2>/dev/null || true
  )"
else
  OUTPUT_SHAPE="      // (output schema unavailable: ${OUTPUT_SCHEMA})"
fi

# Read the template and substitute placeholders. We use python3 rather than
# sed/awk because the envelope block contains slashes, ampersands, and
# embedded newlines that break BSD sed and BSD awk's -v parsing on macOS.
# python3 is already an implicit dependency (the audit MCP server is Python).
RENDERED_JS="$(
  ENVHASH="${ENVELOPE_HASH}" \
  ENVBLOCK="${ENVELOPE_BLOCK}" \
  TRAJID="${TRAJECTORY_ID}" \
  AGENT_NAME="${AGENT}" \
  CALLS="${PER_TASK_CALLS}" \
  SHAPE="${OUTPUT_SHAPE}" \
  TEMPLATE="${TEMPLATE_PATH}" \
  python3 -c '
import os, sys
with open(os.environ["TEMPLATE"], "r", encoding="utf-8") as fh:
    src = fh.read()
sub = {
    "<<ENVELOPE_HASH>>":             os.environ["ENVHASH"],
    "<<CONSTRAINT_ENVELOPE_BLOCK>>": os.environ["ENVBLOCK"],
    "<<TRAJECTORY_ID>>":             os.environ["TRAJID"],
    "<<AGENT_NAME>>":                os.environ["AGENT_NAME"],
    "<<PER_TASK_TOOL_CALLS>>":       os.environ["CALLS"],
    "<<OUTPUT_SCHEMA_SHAPE>>":       os.environ["SHAPE"],
}
for placeholder, value in sub.items():
    src = src.replace(placeholder, value)
sys.stdout.write(src)
'
)"

# Sanity: any remaining placeholder is a rendering failure.
if grep -q '<<[A-Z_]*>>' <<<"${RENDERED_JS}"; then
  printf 'template rendering failed — unsubstituted placeholders remain:\n%s\n' \
    "$(grep -o '<<[A-Z_]*>>' <<<"${RENDERED_JS}" | sort -u)" >&2
  exit 4
fi

# ---------- Step 5: Build registered_tool_name + expected_servers ----------

# Unique tool name combines agent + first 8 chars of envelope hash to make
# re-registration idempotent within a workflow.
HASH_TAIL="${ENVELOPE_HASH#sha256:}"
HASH_TAIL="${HASH_TAIL:0:8}"
REGISTERED_TOOL_NAME="code-mode-${AGENT}-${HASH_TAIL}"

# Build expected_servers[] by extracting server prefixes from the tool surface
# and adding the audit-emit server.
# Per Gemini E3 validation fix 2026-05-20: tools follow the documented 3-part
# format mcp__SERVER__tool (e.g., mcp__siem__query). awk -F'__' splits on '__'
# producing fields: $1='mcp', $2='SERVER', $3='tool'. We want $2 for mcp__-prefixed
# tools. For non-MCP tools that snuck through (shouldn't happen — selector exits 2
# in that case), fall back to $1.
EXPECTED_SERVERS_JSON="$(
  printf '%s\n' "${TOOL_LIST[@]}" \
    | awk -F'__' '
        /^mcp__/ && NF>=3 { print $2; next }
        NF>=2          { print $1; next }
      ' \
    | sort -u \
    | jq -R . \
    | jq -s "(. + [\"${AUDIT_MCP_SERVER_NAME}\"]) | unique"
)"

# ---------- Step 6: Emit structured output ----------

jq -n \
  --arg name "${REGISTERED_TOOL_NAME}" \
  --arg js "${RENDERED_JS}" \
  --arg hash "${ENVELOPE_HASH}" \
  --argjson servers "${EXPECTED_SERVERS_JSON}" \
  '{
    registered_tool_name: $name,
    javascript_source:    $js,
    envelope_hash:        $hash,
    expected_servers:     $servers
  }'
