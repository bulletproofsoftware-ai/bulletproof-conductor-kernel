#!/usr/bin/env bash
# PostToolUse hook: validate conductor-state.json after Write/Edit
# Reads tool input from stdin, checks if the written file is conductor-state.json
# If so, validates against the bundled schema AND enforces phase transition gates
#
# Exit codes:
#   0 = allowed (pass, advisory tier, or hook error — fail-open)
#   1 = blocked (mandatory gate not passed for STANDARD/MAJOR tier)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMA_FILE="$PLUGIN_ROOT/schemas/workflow-state.schema.json"

# Read tool input from stdin
INPUT="$(cat)"

# Extract file_path from the tool input JSON
FILE_PATH=""
if command -v jq &>/dev/null; then
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null)" || true
else
    FILE_PATH="$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    ti = data.get('tool_input', {})
    print(ti.get('file_path', ti.get('filePath', '')))
except Exception:
    pass
" 2>/dev/null)" || true
fi

# Only validate if the written file is conductor-state.json
if [ -z "$FILE_PATH" ] || [[ "$(basename "$FILE_PATH")" != "conductor-state.json" ]]; then
    exit 0
fi

# File must exist to validate
if [ ! -f "$FILE_PATH" ]; then
    exit 0
fi

# Validate JSON syntax first
if command -v jq &>/dev/null; then
    if ! jq empty "$FILE_PATH" 2>/dev/null; then
        cat <<EOF
{"systemMessage": "WARNING: conductor-state.json has invalid JSON syntax. Fix before proceeding."}
EOF
        exit 0
    fi
fi

# Validate against schema using python3 + jsonschema (if available)
if python3 -c "import jsonschema" 2>/dev/null && [ -f "$SCHEMA_FILE" ]; then
    VALIDATION_RESULT="$(python3 -c "
import json, sys
try:
    from jsonschema import validate, ValidationError
    with open('$FILE_PATH') as f:
        instance = json.load(f)
    with open('$SCHEMA_FILE') as f:
        schema = json.load(f)
    validate(instance=instance, schema=schema)
    print('valid')
except ValidationError as e:
    print(f'invalid: {e.message}')
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null)" || true

    case "$VALIDATION_RESULT" in
        valid)
            # Silent success
            ;;
        invalid:*)
            REASON="${VALIDATION_RESULT#invalid: }"
            cat <<EOF
{"systemMessage": "WARNING: conductor-state.json schema validation failed: ${REASON}"}
EOF
            ;;
        error:*)
            # Schema validation not critical — don't block
            ;;
    esac
elif command -v jq &>/dev/null && [ -f "$SCHEMA_FILE" ]; then
    # Fallback: basic required field check with jq
    MISSING="$(jq -r '
        [
            (if .project_name then empty else "project_name" end),
            (if .initiated_at then empty else "initiated_at" end),
            (if .last_updated then empty else "last_updated" end),
            (if .current_phase then empty else "current_phase" end),
            (if .current_step then empty else "current_step" end),
            (if .task_queue then empty else "task_queue" end),
            (if .completed_tasks then empty else "completed_tasks" end),
            (if .verification_status then empty else "verification_status" end)
        ] | join(", ")
    ' "$FILE_PATH" 2>/dev/null)" || true

    if [ -n "$MISSING" ]; then
        cat <<EOF
{"systemMessage": "WARNING: conductor-state.json missing required fields: ${MISSING}"}
EOF
    fi
fi

# ============================================================================
# PHASE TRANSITION GATE ENFORCEMENT
# Blocks invalid phase transitions for STANDARD/MAJOR tiers.
# Advisory warnings only for MINOR/TRIVIAL.
# Fail-open on any error in this section's own logic.
# ============================================================================

# Phase gates: which verification_status fields must be "pass" before transitioning FROM this phase
# Format: phase_number:gate1,gate2,...
PHASE_GATES="
1:post_brd_extraction
2:spec_alignment_check
3:builder_readback,post_architect
4:post_implementation
5:post_qa,ciso_review
6:post_hardening,adversarial_review,completeness_validation
"

# Wrap gate enforcement in a function so errors fail-open
_enforce_phase_gates() {
    # jq is required for gate enforcement
    if ! command -v jq &>/dev/null; then
        return 0
    fi

    local STATE_FILE="$FILE_PATH"

    # Read current phase and tier from the state file
    local CURR_PHASE
    CURR_PHASE="$(jq -r '.current_phase.number // empty' "$STATE_FILE" 2>/dev/null)" || return 0
    local TIER
    TIER="$(jq -r '.governance.conductor_tier // "MINOR"' "$STATE_FILE" 2>/dev/null)" || return 0

    # H4 fix: per-project cache (no /tmp symlink race vector).
    # SESSION_DIR overrides if explicitly set by the harness.
    local STATE_DIR
    STATE_DIR="$(dirname "$STATE_FILE")"
    local CACHE_DIR="${SESSION_DIR:-${STATE_DIR}/.conductor-cache}"
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
        chmod 700 "$CACHE_DIR" 2>/dev/null || true
    fi
    local PHASE_CACHE_FILE="${CACHE_DIR}/conductor_last_phase"
    # Refuse to follow symlinks for the cache file
    if [ -L "$PHASE_CACHE_FILE" ]; then
        rm -f "$PHASE_CACHE_FILE" 2>/dev/null || return 0
    fi
    local PREV_PHASE=""
    if [ -f "$PHASE_CACHE_FILE" ]; then
        PREV_PHASE="$(cat "$PHASE_CACHE_FILE" 2>/dev/null)" || true
    fi

    # Detect phase transition
    if [ -n "$PREV_PHASE" ] && [ -n "$CURR_PHASE" ] && [ "$PREV_PHASE" != "$CURR_PHASE" ]; then
        # Phase transition detected

        if [ "$TIER" = "MAJOR" ] || [ "$TIER" = "STANDARD" ]; then
            # --- Gate validation: check all required gates for the PREVIOUS phase ---
            local REQUIRED_GATES
            REQUIRED_GATES="$(echo "$PHASE_GATES" | grep "^${PREV_PHASE}:" | cut -d: -f2)" || true

            if [ -n "$REQUIRED_GATES" ]; then
                # Split comma-separated gates and check each one
                local -a GATES
                IFS=',' read -ra GATES <<< "$REQUIRED_GATES"

                for gate in "${GATES[@]}"; do
                    gate="$(echo "$gate" | tr -d ' ')"
                    [ -z "$gate" ] && continue

                    local STATUS
                    STATUS="$(jq -r ".verification_status.${gate} // \"null\"" "$STATE_FILE" 2>/dev/null)" || STATUS="null"

                    if [ "$STATUS" != "pass" ]; then
                        echo "{\"decision\": \"block\", \"reason\": \"Phase transition blocked: gate '${gate}' is '${STATUS}', must be 'pass' before leaving phase ${PREV_PHASE}\"}"
                        # Do NOT update the phase cache — keep it at PREV_PHASE so the block persists
                        exit 1
                    fi
                done
            fi

            # --- Git ratcheting: uncommitted changes block phase transitions ---
            # STATE_DIR already set above
            if [ -d "${STATE_DIR}/.git" ] || git -C "$STATE_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
                if [ -n "$(git -C "$STATE_DIR" status --porcelain 2>/dev/null)" ]; then
                    echo "{\"decision\": \"block\", \"reason\": \"Phase transition blocked: uncommitted changes detected. Commit before advancing to phase ${CURR_PHASE}.\"}"
                    # Do NOT update the phase cache
                    exit 1
                fi
            fi

        elif [ "$TIER" = "MINOR" ] || [ "$TIER" = "TRIVIAL" ]; then
            # Advisory only for MINOR/TRIVIAL — check gates but only warn
            local REQUIRED_GATES
            REQUIRED_GATES="$(echo "$PHASE_GATES" | grep "^${PREV_PHASE}:" | cut -d: -f2)" || true

            if [ -n "$REQUIRED_GATES" ]; then
                local -a GATES
                IFS=',' read -ra GATES <<< "$REQUIRED_GATES"
                local WARNINGS=""

                for gate in "${GATES[@]}"; do
                    gate="$(echo "$gate" | tr -d ' ')"
                    [ -z "$gate" ] && continue

                    local STATUS
                    STATUS="$(jq -r ".verification_status.${gate} // \"null\"" "$STATE_FILE" 2>/dev/null)" || STATUS="null"

                    if [ "$STATUS" != "pass" ]; then
                        WARNINGS="${WARNINGS}gate '${gate}' is '${STATUS}'; "
                    fi
                done

                if [ -n "$WARNINGS" ]; then
                    cat <<EOF
{"systemMessage": "ADVISORY: Phase transition from ${PREV_PHASE} to ${CURR_PHASE} has unchecked gates: ${WARNINGS}Consider completing these before proceeding."}
EOF
                fi
            fi
        fi
    fi

    # Save current phase for next comparison (only reached if transition was allowed)
    if [ -n "$CURR_PHASE" ]; then
        echo "$CURR_PHASE" > "$PHASE_CACHE_FILE" 2>/dev/null || true
    fi

    return 0
}

# Run gate enforcement — any error in this block fails open (exit 0)
_enforce_phase_gates || exit 0

# ============================================================================
# AUDIT EMITTER — send opted-in events to external SIEM (Wazuh, etc.)
# Fail-open: emitter errors NEVER block the state write.
# ============================================================================
EMITTER="$SCRIPT_DIR/lib/audit_emitter.py"
if [ -x "$EMITTER" ] && command -v python3 &>/dev/null; then
    python3 "$EMITTER" "$FILE_PATH" 2>/dev/null || true
fi

exit 0
