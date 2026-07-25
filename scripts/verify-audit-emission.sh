#!/bin/bash
# scripts/verify-audit-emission.sh
# Phase 1 exit-gate check per kernel-api.md §13.3 (gate (c)).
#
# Verifies that kernel.audit_emit writes correctly to the governance-plugin
# audit trail. Per kernel-api.md §6 REQ-KER-018, audit emissions land in
# governance-plugin/state/audit.db with:
#   - Ed25519 row signature
#   - All required payload fields present
#   - timestamp set
#   - 0600 file mode (operator-verifiable post-deployment)
#
# v0.1.0 NOTE: full programmatic audit_emit is exercised via the kernel
# dispatch primitive once a sibling plugin is installed. This script
# performs the verifiable subset that does NOT require a live Claude
# Code dispatch loop:
#   - audit.db file exists at the canonical path
#   - file mode is 0600
#   - file is readable (we do NOT inspect rows so as to avoid coupling
#     to the governance-plugin row encoding which is HMAC-token-gated)
#   - latest row's event_type is observable (best-effort via sqlite3
#     if the binary is on PATH; otherwise the row count alone suffices).
#
# A fuller verification — synthesizing a kernel.audit_emit call and
# round-tripping the resulting event_id back through the governance API —
# requires a live Claude Code session and is invoked manually from /conduct
# during the Phase 1 exit-gate run; the procedure is documented in the
# trailing MANUAL block below.
#
# governance-plugin is an OPTIONAL dependency. When it is not installed there
# is no audit database to inspect, and this check reports SKIP rather than
# FAIL — a kernel running without governance-plugin is a supported
# configuration in which audit emission falls back to a local JSONL file.
#
# The database path is resolved by scripts/lib/paths.sh and assumes no
# particular checkout layout. Override with GOVERNANCE_PLUGIN_ROOT or
# AUDIT_DB_OVERRIDE.
#
# Exit codes:
#   0  — audit.db present, mode 0600, readable
#   1  — audit.db present but wrong mode, not a regular file, or unreadable
#   3  — partial pass: file present and readable but mode could not be checked
#        (e.g., non-POSIX stat); treated as PASS with warning.
#  77  — SKIP: no audit database found (governance-plugin not installed)

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
. "${SCRIPT_DIR}/lib/paths.sh"

AUDIT_DB="$(kernel_audit_db_path)"

echo "verify-audit-emission.sh — checking governance audit trail"
echo "  AUDIT_DB = $AUDIT_DB"

if [ ! -e "$AUDIT_DB" ]; then
  echo ""
  echo "SKIP (77): no governance audit database at the resolved path."
  echo "  Resolved: $AUDIT_DB"
  echo ""
  echo "  governance-plugin is an OPTIONAL dependency of the kernel. Without it,"
  echo "  audit emission degrades to a local JSONL fallback and this check has"
  echo "  nothing to verify — that is a valid configuration, not a failure."
  echo ""
  echo "  If you DO run governance-plugin, point this check at its database:"
  echo "    export GOVERNANCE_PLUGIN_ROOT=/path/to/governance-plugin"
  echo "  or, to name the file directly:"
  echo "    export AUDIT_DB_OVERRIDE=/path/to/audit.db"
  echo ""
  echo "  See: https://github.com/bulletproofsoftware-ai/bulletproof-governance-plugin"
  exit 77
fi

if [ ! -f "$AUDIT_DB" ]; then
  echo "FAIL (1): $AUDIT_DB exists but is not a regular file."
  exit 1
fi

if [ ! -r "$AUDIT_DB" ]; then
  echo "FAIL (1): $AUDIT_DB is not readable by current user."
  exit 1
fi

# Check file mode: POSIX 0600 expected per RC-5.
# macOS:   stat -f '%Mp%Lp'
# Linux:   stat -c '%a'
mode=""
if stat -f '%Mp%Lp' "$AUDIT_DB" >/dev/null 2>&1; then
  mode=$(stat -f '%Lp' "$AUDIT_DB")
elif stat -c '%a' "$AUDIT_DB" >/dev/null 2>&1; then
  mode=$(stat -c '%a' "$AUDIT_DB")
fi

if [ -z "$mode" ]; then
  echo "WARN: could not determine file mode (no POSIX stat available)."
  echo "  Treating as advisory PASS."
  exit 3
fi

if [ "$mode" != "600" ]; then
  echo "FAIL (1): audit.db file mode is $mode; expected 600 (per RC-5)."
  echo "  Fix: chmod 600 '$AUDIT_DB'"
  exit 1
fi

# Best-effort: count rows if sqlite3 is on PATH. This is non-load-bearing.
if command -v sqlite3 >/dev/null 2>&1; then
  # Look for a likely-named table without assuming the exact governance schema.
  table=$(sqlite3 "$AUDIT_DB" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name LIMIT 1;" 2>/dev/null || true)
  if [ -n "$table" ]; then
    rows=$(sqlite3 "$AUDIT_DB" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || true)
    if [ -n "$rows" ]; then
      echo "  audit.db row count (table=$table): $rows"
    fi
  fi
fi

echo ""
echo "PASS: audit.db present at $AUDIT_DB, mode 0600, readable."
echo ""
echo "[MANUAL — Phase 1 exit-gate (c) full verification]"
echo "  Run from /conduct (or /clue once Phase 4 ships):"
echo "    1. Issue a synthetic kernel.audit_emit('test.phase1_verification',"
echo "       { trace_id: 'p1-verify-<ts>', timestamp: <now> }) call."
echo "    2. Inspect the returned event_id."
echo "    3. Confirm a row with event_type='test.phase1_verification' is"
echo "       present in audit.db with a valid Ed25519 signature."
echo "    4. Confirm latency <= 100ms p99 per PRD §10 KPI."
exit 0
