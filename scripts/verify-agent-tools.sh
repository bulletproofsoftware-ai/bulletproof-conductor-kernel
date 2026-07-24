#!/bin/bash
# scripts/verify-agent-tools.sh
# Phase 1 exit-gate check per kernel-api.md §13.5 (RC-12 / F-15).
#
# Verifies every agent file under agents/ declares an explicit `allowed-tools`
# list in its YAML frontmatter. Missing or empty declaration = FAIL.
#
# Exit codes:
#   0  — every agent file declares allowed-tools
#   1  — at least one agent is missing the declaration
#   2  — unexpected error (no agents/ directory, no agent files, etc.)

set -eu

AGENTS_DIR="$(dirname "$0")/../agents"

if [ ! -d "$AGENTS_DIR" ]; then
  echo "FAIL: agents/ directory not found at $AGENTS_DIR"
  exit 2
fi

shopt -s nullglob 2>/dev/null || true   # bash; zsh users invoke via bash
AGENT_FILES=( "$AGENTS_DIR"/*.md )
if [ "${#AGENT_FILES[@]}" -eq 0 ]; then
  echo "FAIL: no agent files found under $AGENTS_DIR"
  exit 2
fi

EXIT=0
TOTAL=0
PASSED=0
MISSING=()
for f in "${AGENT_FILES[@]}"; do
  TOTAL=$((TOTAL + 1))
  agent_name=$(basename "$f" .md)
  # awk scans the YAML frontmatter (between the first two `---` lines) and
  # looks for a line beginning with `allowed-tools:`. Returns exit 0 if found.
  if awk '/^---$/{f=!f; next} f && /^allowed-tools:/{found=1; exit 0} END{exit !found}' "$f" >/dev/null; then
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $agent_name — missing allowed-tools frontmatter"
    MISSING+=( "$agent_name" )
    EXIT=1
  fi
done

if [ "$EXIT" -eq 0 ]; then
  echo "PASS: all $TOTAL kernel agents declare allowed-tools"
else
  echo "----------------------------------------"
  echo "Summary: $PASSED/$TOTAL agents passed; ${#MISSING[@]} missing."
  echo "Missing: ${MISSING[*]}"
fi
exit $EXIT
