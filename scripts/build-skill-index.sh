#!/bin/bash
# scripts/build-skill-index.sh
# Build the progressive-disclosure skill index (~/.claude/skill-index.json).
#
# Hermes E2 — REQ-CDV-HERMES-005 / REQ-CDV-HERMES-006
# Version: 1.0.0
#
# Usage:
#   bash build-skill-index.sh [--output PATH] [--source DIR ...]
#
# Defaults:
#   --output  ~/.claude/skill-index.json
#   Sources   (in walk order):
#     1. ~/.claude/skills/
#     2. ~/Code/conductor-kernel/skills/
#     3. ~/Code/clue-soc/skills/
#     4. ~/Code/conductor-dev/skills/  (tolerated — may not exist)
#     5. ~/.claude/plugins/marketplaces/*/plugins/*/skills/
#     6. ~/.claude/plugins/local/*/skills/
#     7. ~/.claude/plugins/marketplaces/anthropic-agent-skills/skills/
#     Plus any dirs passed via --source
#
# Exit codes:
#   0  success
#   1  no skills found (warn only)
#   2  output file unwritable
#   3  invalid frontmatter in >=1 skill (warn only — skip and continue)
#
# Index size cap: if JSON > 50KB, switch to category-only mode (drop description)
# and emit a warning to stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR_VERSION="1.0.0"

# Source shared helpers
# shellcheck source=lib/skill-index-helpers.sh
source "${SCRIPT_DIR}/lib/skill-index-helpers.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OUTPUT_FILE="${HOME}/.claude/skill-index.json"
FALLBACK_OUTPUT="~/Code/conductor-dev/proposals/skill-index.json"

USER_SKILLS_DIR="${HOME}/.claude/skills"
KERNEL_SKILLS_DIR="${HOME}/Code/conductor-kernel/skills"
CLUESOC_SKILLS_DIR="${HOME}/Code/clue-soc/skills"
CONDUCTOR_DEV_SKILLS_DIR="${HOME}/Code/conductor-dev/skills"

# Directories to skip (basename match)
SKIP_DIRS=("archive" "_proposed" "_rejected" "_patches" ".git" "node_modules")

# Max entries per source directory (R-E2-B defense)
MAX_PER_SOURCE_DIR=500

# Index size cap in bytes (50KB)
INDEX_SIZE_CAP=51200

# Extra source directories (populated by --source args)
EXTRA_SOURCES=()

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --source)
            EXTRA_SOURCES+=("$2")
            shift 2
            ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helper: should we skip this directory?
# ---------------------------------------------------------------------------
should_skip_dir() {
    local dir_name
    dir_name="$(basename "$1")"
    for skip in "${SKIP_DIRS[@]}"; do
        [[ "$dir_name" == "$skip" ]] && return 0
    done
    # Skip any dir whose name starts with .publish/ content
    [[ "$dir_name" == .publish* ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Helper: find SKILL.md files in a directory (non-recursive into skip dirs)
# Returns newline-separated absolute paths.
# ---------------------------------------------------------------------------
find_skills_in_dir() {
    local source_dir="$1"
    [[ -d "$source_dir" ]] || return 0

    # Use python3 for a clean, controlled walk (respects skip dirs, cap)
    python3 - "$source_dir" "${MAX_PER_SOURCE_DIR}" <<'PYTHON_EOF'
import sys, os

source_dir = sys.argv[1]
cap = int(sys.argv[2])
skip_dirs = {'archive', '_proposed', '_rejected', '_patches', '.git', 'node_modules'}
count = 0
results = []

for root, dirs, files in os.walk(source_dir, topdown=True):
    # Prune skip dirs and .publish* dirs in-place
    dirs[:] = [
        d for d in dirs
        if d not in skip_dirs and not d.startswith('.publish')
    ]
    if 'SKILL.md' in files:
        results.append(os.path.join(root, 'SKILL.md'))
        count += 1
        if count >= cap:
            print(f"WARNING: capped at {cap} entries for {source_dir}", file=sys.stderr)
            break

for r in results:
    print(r)
PYTHON_EOF
}

# ---------------------------------------------------------------------------
# Build source directory list
# ---------------------------------------------------------------------------
SOURCES=(
    "$USER_SKILLS_DIR"
    "$KERNEL_SKILLS_DIR"
    "$CLUESOC_SKILLS_DIR"
    "$CONDUCTOR_DEV_SKILLS_DIR"
)

# Marketplace: anthropic-agent-skills (skills/ at top level)
ANTHROPIC_SKILLS="${HOME}/.claude/plugins/marketplaces/anthropic-agent-skills/skills"
[[ -d "$ANTHROPIC_SKILLS" ]] && SOURCES+=("$ANTHROPIC_SKILLS")

# Marketplace: claude-code-plugins — skills are under plugins/<name>/skills/
if [[ -d "${HOME}/.claude/plugins/marketplaces/claude-code-plugins/plugins" ]]; then
    for plugin_dir in "${HOME}/.claude/plugins/marketplaces/claude-code-plugins/plugins"/*/; do
        skills_dir="${plugin_dir}skills"
        [[ -d "$skills_dir" ]] && SOURCES+=("$skills_dir")
    done
fi

# Marketplace: claude-plugins-official
if [[ -d "${HOME}/.claude/plugins/marketplaces/claude-plugins-official/plugins" ]]; then
    for plugin_dir in "${HOME}/.claude/plugins/marketplaces/claude-plugins-official/plugins"/*/; do
        skills_dir="${plugin_dir}skills"
        [[ -d "$skills_dir" ]] && SOURCES+=("$skills_dir")
    done
fi

# Local plugins
if [[ -d "${HOME}/.claude/plugins/local" ]]; then
    for plugin_dir in "${HOME}/.claude/plugins/local"/*/; do
        skills_dir="${plugin_dir}skills"
        [[ -d "$skills_dir" ]] && SOURCES+=("$skills_dir")
    done
fi

# Extra sources from --source args
for extra in "${EXTRA_SOURCES[@]}"; do
    SOURCES+=("$extra")
done

# ---------------------------------------------------------------------------
# Collect all SKILL.md paths
# ---------------------------------------------------------------------------
SKILL_PATHS=()
for src in "${SOURCES[@]}"; do
    while IFS= read -r path; do
        [[ -n "$path" ]] && SKILL_PATHS+=("$path")
    done < <(find_skills_in_dir "$src")
done

# Deduplicate (same file reachable via multiple source additions)
# Use python3 to preserve order while deduplicating
DEDUPED_PATHS=()
if [[ ${#SKILL_PATHS[@]} -gt 0 ]]; then
    while IFS= read -r path; do
        [[ -n "$path" ]] && DEDUPED_PATHS+=("$path")
    done < <(python3 -c "
import sys
seen = set()
for line in sys.stdin:
    p = line.rstrip('\n')
    if p and p not in seen:
        seen.add(p)
        print(p)
" <<< "$(printf '%s\n' "${SKILL_PATHS[@]}")")
fi

if [[ ${#DEDUPED_PATHS[@]} -eq 0 ]]; then
    echo "WARNING: no SKILL.md files found in any source directory" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build JSON records for each skill
# ---------------------------------------------------------------------------
PARSE_ERRORS=0
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Accumulate skill JSON objects as a bash array of strings
SKILL_RECORDS=()

for skill_path in "${DEDUPED_PATHS[@]}"; do
    skill_dir="$(dirname "$skill_path")"

    # Parse frontmatter
    if ! fm_output="$(parse_frontmatter "$skill_path" 2>/dev/null)"; then
        echo "WARNING: failed to parse frontmatter: $skill_path" >&2
        PARSE_ERRORS=$((PARSE_ERRORS + 1))
        continue
    fi

    # Evaluate parsed output into FM_* variables
    eval "$fm_output" 2>/dev/null || true

    # If FM_ERROR is set, skip this skill
    if [[ -n "${FM_ERROR:-}" ]]; then
        echo "WARNING: frontmatter error in $skill_path: $FM_ERROR" >&2
        PARSE_ERRORS=$((PARSE_ERRORS + 1))
        FM_ERROR=""
        continue
    fi

    # Skip skills with no name (truly empty frontmatter)
    # Use the directory name as fallback name
    skill_name="${FM_NAME:-}"
    if [[ -z "$skill_name" ]]; then
        skill_name="$(basename "$skill_dir")"
    fi

    # Source label
    source_label="$(skill_source_label "$skill_path" "$USER_SKILLS_DIR" "$KERNEL_SKILLS_DIR" "$CLUESOC_SKILLS_DIR")"

    # Size estimate
    skill_size_bytes="$(python3 -c "import os; print(os.path.getsize('$skill_path'))" 2>/dev/null || echo "0")"
    skill_size_tokens=$(( skill_size_bytes / 4 ))
    [[ $skill_size_tokens -lt 1 ]] && skill_size_tokens=1

    # Reference enumeration (Level-2)
    references_json="$(enumerate_references "$skill_dir" 2>/dev/null || echo "[]")"

    # Build JSON record via python3 to ensure correct escaping
    record="$(python3 - <<PYEOF
import json, sys

record = {
    "name": """${FM_NAME:-}""" or "$(basename "$skill_dir")",
    "source": """${source_label}""",
    "path": """${skill_path}""",
    "category": """${FM_CATEGORY:-uncategorized}""",
    "description": """${FM_DESCRIPTION:-}""",
    "platforms": json.loads("""${FM_PLATFORMS:-["macos","linux"]}""" or '["macos","linux"]'),
    "tags": json.loads("""${FM_TAGS:-[]}""" or '[]'),
    "size_estimate_tokens": ${skill_size_tokens},
    "references": json.loads("""${references_json}"""),
    "version": """${FM_VERSION:-}""" or None,
    "agentskills_compatible": """${FM_AGENTSKILLS_COMPATIBLE:-false}""" == "true",
}
print(json.dumps(record, ensure_ascii=False))
PYEOF
    )"

    SKILL_RECORDS+=("$record")

    # Clear FM vars for next iteration
    FM_NAME="" FM_DESCRIPTION="" FM_CATEGORY="" FM_PLATFORMS="" FM_TAGS="" FM_VERSION="" FM_AGENTSKILLS_COMPATIBLE="" FM_ERROR=""
done

SKILLS_COUNT=${#SKILL_RECORDS[@]}

# ---------------------------------------------------------------------------
# Assemble full JSON output
# ---------------------------------------------------------------------------
assemble_json() {
    local category_only="${1:-false}"
    python3 - "$category_only" "${GENERATED_AT}" "${GENERATOR_VERSION}" "${SKILLS_COUNT}" <<'PYEOF' -- "${SKILL_RECORDS[@]+"${SKILL_RECORDS[@]}"}"
import sys, json

category_only = sys.argv[1] == "true"
generated_at = sys.argv[2]
generator_version = sys.argv[3]
skills_count = int(sys.argv[4])

# Records are passed as remaining argv (one JSON string per skill)
records_raw = sys.argv[5:]
skills = []
for raw in records_raw:
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        continue
    if category_only:
        # Strip description to reduce size; retain tags as [] so consumers
        # doing `has("tags")` checks still work (QA F-3 fix 2026-05-20).
        obj.pop('description', None)
        obj['tags'] = []
    skills.append(obj)

output = {
    "generated_at": generated_at,
    "generator": "build-skill-index.sh",
    "generator_version": generator_version,
    "category_only": bool(category_only),
    "skills_count": len(skills),
    "skills": skills,
}
print(json.dumps(output, indent=2, ensure_ascii=False))
PYEOF
}

# ---------------------------------------------------------------------------
# Check size and apply cap if needed
# ---------------------------------------------------------------------------
FULL_JSON="$(assemble_json "false" "${GENERATED_AT}" "${GENERATOR_VERSION}" "${SKILLS_COUNT}" "${SKILL_RECORDS[@]+"${SKILL_RECORDS[@]}"}")"
JSON_SIZE=${#FULL_JSON}

CATEGORY_ONLY_MODE=false
if [[ $JSON_SIZE -gt $INDEX_SIZE_CAP ]]; then
    echo "WARNING: skill index exceeds ${INDEX_SIZE_CAP} bytes (actual: ${JSON_SIZE} bytes). Switching to category-only mode (descriptions omitted)." >&2
    CATEGORY_ONLY_MODE=true
    FULL_JSON="$(assemble_json "true" "${GENERATED_AT}" "${GENERATOR_VERSION}" "${SKILLS_COUNT}" "${SKILL_RECORDS[@]+"${SKILL_RECORDS[@]}"}")"
fi

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
write_output() {
    local target="$1"
    local content="$2"
    local target_dir
    target_dir="$(dirname "$target")"

    if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir" 2>/dev/null || true
    fi

    if ! echo "$content" > "$target" 2>/dev/null; then
        return 1
    fi
    return 0
}

if write_output "$OUTPUT_FILE" "$FULL_JSON"; then
    echo "Skill index written: ${OUTPUT_FILE}"
    echo "  Skills indexed : ${SKILLS_COUNT}"
    echo "  Index size     : ${#FULL_JSON} bytes"
    echo "  Category-only  : ${CATEGORY_ONLY_MODE}"
    echo "  Generated at   : ${GENERATED_AT}"
    [[ $PARSE_ERRORS -gt 0 ]] && echo "  Parse warnings : ${PARSE_ERRORS} skill(s) skipped due to frontmatter errors" >&2
else
    echo "WARNING: cannot write to ${OUTPUT_FILE} (permission denied?). Falling back to ${FALLBACK_OUTPUT}" >&2
    if write_output "$FALLBACK_OUTPUT" "$FULL_JSON"; then
        echo "Skill index written to fallback: ${FALLBACK_OUTPUT}"
        echo "  Skills indexed : ${SKILLS_COUNT}"
        echo "  Generated at   : ${GENERATED_AT}"
        echo "  To install: cp '${FALLBACK_OUTPUT}' '${OUTPUT_FILE}'"
        [[ $PARSE_ERRORS -gt 0 ]] && echo "  Parse warnings : ${PARSE_ERRORS} skill(s) skipped" >&2
    else
        echo "ERROR: cannot write to fallback path ${FALLBACK_OUTPUT}" >&2
        exit 2
    fi
fi

[[ $PARSE_ERRORS -gt 0 ]] && exit 3
exit 0
