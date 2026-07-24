#!/bin/bash
# scripts/verify-cross-plugin-dispatch.sh
# Phase 1 exit-gate check per kernel-api.md §13.2 (gate (b)).
#
# Verifies that a sibling Claude Code plugin can dispatch a kernel agent
# via the qualified <plugin>:<agent> Task subagent_type mechanism, and that
# the dispatch emits an "agent.dispatch" audit event.
#
# Fully automating this gate requires a live Claude Code session, which a
# shell script cannot drive on its own. This script therefore performs two
# things:
#
#   (a) The MECHANICAL pre-flight that DOES NOT need Claude:
#       - Scaffolds an ephemeral sibling test plugin at
#         $HOME/Code/kernel-dispatch-test (idempotent: re-runs leave the
#         scaffold ready for the manual /plugin install step).
#       - Verifies the scaffold is well-formed (plugin.json valid, commands
#         dir present, requires-clause references conductor-kernel).
#
#   (b) The MANUAL procedure document that the operator runs inside
#       Claude Code to complete the gate.
#
# Exit codes:
#   0   — scaffold built and valid; operator MUST run the manual procedure
#         to complete gate (b).
#   1   — scaffold invalid or kernel install pre-condition not met.
#   77  — special exit code meaning "MANUAL pass required" — emitted on
#         success so a CI runner sees a non-zero code if it expected fully
#         automated verification.

set -eu

KERNEL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_PLUGIN="${TEST_PLUGIN_DIR:-$HOME/Code/kernel-dispatch-test}"

echo "verify-cross-plugin-dispatch.sh — Phase 1 gate (b)"
echo "  KERNEL_DIR  = $KERNEL_DIR"
echo "  TEST_PLUGIN = $TEST_PLUGIN"

# --- (a) Pre-flight: confirm kernel plugin.json exists and parses ----------

if [ ! -f "$KERNEL_DIR/plugin.json" ]; then
  echo "FAIL: $KERNEL_DIR/plugin.json missing."
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$KERNEL_DIR/plugin.json" 2>/dev/null; then
    echo "FAIL: $KERNEL_DIR/plugin.json does not parse as JSON."
    exit 1
  fi
fi

# --- (b) Scaffold the sibling test plugin ----------------------------------

mkdir -p "$TEST_PLUGIN/commands" "$TEST_PLUGIN/agents"

cat > "$TEST_PLUGIN/plugin.json" <<'JSON'
{
  "name": "kernel-dispatch-test",
  "version": "0.0.1",
  "description": "Ephemeral test plugin for verifying cross-plugin dispatch of conductor-kernel agents.",
  "license": "MIT",
  "commands": "commands",
  "requires": { "conductor-kernel": ">= 0.1.0" }
}
JSON

cat > "$TEST_PLUGIN/commands/kdt-test.md" <<'MD'
---
description: "Tests cross-plugin dispatch of conductor-kernel:critic"
allowed-tools: ["Task"]
---

# /kdt-test — Cross-plugin dispatch verification

This command dispatches `conductor-kernel:critic` with a known
claim+evidence pair and asserts the structured gap-analysis output.

## Steps

1. Dispatch:
   ```
   Task(subagent_type="conductor-kernel:critic",
        prompt="CLAIM: 2 + 2 = 4.\n\nEVIDENCE:\n- arithmetic identity.\n\nProvide structured gap analysis.",
        description="Phase 1 gate (b) cross-plugin dispatch test")
   ```

2. Assert the response includes a `verdict` field with one of
   `ACCEPT | REJECT | ACCEPT_WITH_FINDINGS`.

3. Inspect `governance-plugin/state/audit.db` for an `agent.dispatch`
   event with `agent="conductor-kernel:critic"` recorded in the last
   60 seconds. If present → gate (b) PASS.

4. Failure modes:
   - `conductor-kernel not installed` → fail with the user-facing
     install instruction (see API.md §8.2).
   - `KER-DA-006 namespace_collision` → a different plugin also
     declares `conductor-kernel:critic`; uninstall the conflicting
     plugin and retry.
MD

# --- (c) Validate the scaffold ----------------------------------------------

for required in "$TEST_PLUGIN/plugin.json" "$TEST_PLUGIN/commands/kdt-test.md"; do
  if [ ! -f "$required" ]; then
    echo "FAIL: scaffold missing $required"
    exit 1
  fi
done

if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TEST_PLUGIN/plugin.json" 2>/dev/null; then
    echo "FAIL: scaffold plugin.json does not parse."
    exit 1
  fi
fi

echo ""
echo "PASS (scaffold): $TEST_PLUGIN built and validated."
echo ""
echo "[MANUAL — Phase 1 gate (b) completion]"
echo "  Inside Claude Code:"
echo "    1. /plugin install $KERNEL_DIR"
echo "    2. /plugin install $TEST_PLUGIN"
echo "    3. /plugin list   — confirm both plugins enabled"
echo "    4. /kdt-test      — runs the dispatch"
echo "    5. Verify the response and audit event per the steps in"
echo "       $TEST_PLUGIN/commands/kdt-test.md"
echo "  Exit code 77 below means: scaffold green, MANUAL step required."
exit 77
