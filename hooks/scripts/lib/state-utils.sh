#!/usr/bin/env bash
# Shared utilities for reading conductor-state.json

# Find conductor-state.json in current directory or parents
find_state_file() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/conductor-state.json" ]; then
            echo "$dir/conductor-state.json"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Read a field from conductor-state.json using jq
# Usage: read_state_field ".current_phase.name"
read_state_field() {
    local field="$1"
    local state_file
    state_file="$(find_state_file)" || return 1

    if command -v jq &>/dev/null; then
        jq -r "$field // empty" "$state_file" 2>/dev/null
    else
        # Fallback: basic python json parsing
        python3 -c "
import json, sys
try:
    with open('$state_file') as f:
        data = json.load(f)
    keys = '$field'.lstrip('.').split('.')
    val = data
    for k in keys:
        val = val[k]
    print(val if val is not None else '')
except Exception:
    sys.exit(1)
" 2>/dev/null
    fi
}

# Get a brief status summary from conductor-state.json
get_status_summary() {
    local state_file
    state_file="$(find_state_file)" || return 1

    if command -v jq &>/dev/null; then
        jq -r '
            "Project: \(.project_name // "unknown")" +
            " | Tier: \(.tier // "unclassified")" +
            " | Phase \(.current_phase.number // "?"): \(.current_phase.name // "unknown")" +
            " | Step \(.current_step.number // "?"): \(.current_step.name // "unknown")" +
            " | Status: \(.current_step.status // "unknown")" +
            " | Completed: \(.completed_tasks | length) tasks"
        ' "$state_file" 2>/dev/null
    else
        python3 -c "
import json
try:
    with open('$state_file') as f:
        d = json.load(f)
    p = d.get('current_phase', {})
    s = d.get('current_step', {})
    ct = len(d.get('completed_tasks', []))
    print(f\"Project: {d.get('project_name', '?')} | Tier: {d.get('tier', '?')} | Phase {p.get('number', '?')}: {p.get('name', '?')} | Step {s.get('number', '?')}: {s.get('name', '?')} | Status: {s.get('status', '?')} | Completed: {ct} tasks\")
except Exception:
    pass
" 2>/dev/null
    fi
}
