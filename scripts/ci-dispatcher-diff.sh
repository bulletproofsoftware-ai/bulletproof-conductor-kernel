#!/bin/bash
# scripts/ci-dispatcher-diff.sh
# DRIFT DETECTOR for kernel-api.md §9 (REQ-KER-004 / RC-16 hash gate + content diff).
#
# v0.1.0 STATUS: STUB.
#
# Per extraction-plan.md §1.6.1 and §2.6, Phase 2 (the conductor-dev migration
# phase) is responsible for the live implementation of this script — because
# the duplicating domain files (conductor-dev/commands/conduct.md and the
# eventual clue-soc/commands/clue.md) do not exist as duplicated copies yet at
# Phase 1 exit. Authoring a "live" diff script in Phase 1 would either:
#   - fail the build on every run (no domain copies to compare against), or
#   - silently exit 0 without doing anything, which is worse.
#
# This stub:
#   1. Documents the eventual contract (per kernel-api.md §9.3) so the Phase 2
#      builder authors the live implementation directly from this file's
#      header comment.
#   2. Exits 0 with a clear STUB-MODE banner so CI runners see green during
#      the Phase 1 → Phase 2 window.
#
# Phase 2 contract (PER kernel-api.md §9.3):
# -------------------------------------------------------------------------
# KERNEL_CORE="conductor-kernel/lib/dispatcher-core.md"
# DOMAIN_FILES=(
#   "conductor-dev/commands/conduct.md"
#   "clue-soc/commands/clue.md"
# )
#
# # RC-16 hash gate (first stage):
# EXPECTED_HASH=$(sha256sum "$KERNEL_CORE" | awk '{print $1}')
#
# for f in "${DOMAIN_FILES[@]}"; do
#   [ -f "$f" ] || continue
#   DECLARED_HASH=$(grep -E '^[[:space:]]*sync_hash:[[:space:]]*' "$f" | head -1 | awk -F: '{print $2}' | tr -d ' ')
#   if [ "$DECLARED_HASH" != "$EXPECTED_HASH" ]; then
#     echo "DRIFT (hash): $f sync_hash=$DECLARED_HASH expected=$EXPECTED_HASH"
#     exit 1
#   fi
#
#   # Block-content diff (second stage):
#   #   - Extract block between BEGIN_CANONICAL and END_CANONICAL markers from $f
#   #   - Diff against $KERNEL_CORE
#   #   - Print unified diff on mismatch, exit 1
# done
#
# CI runs this on every PR (and pre-commit hook in domain plugins runs it
# locally before push). Drift fails the build.
# -------------------------------------------------------------------------
#
# Exit codes:
#   0  — stub OK or all hashes/blocks match (Phase 2+ live mode)
#   1  — drift detected (Phase 2+ live mode)

set -eu

KERNEL_CORE="$(dirname "$0")/../lib/dispatcher-core.md"

if [ ! -f "$KERNEL_CORE" ]; then
  echo "FAIL: canonical source not found at $KERNEL_CORE"
  exit 1
fi

cat <<BANNER
ci-dispatcher-diff.sh — STUB MODE (Phase 1)
--------------------------------------------
This script ships as a placeholder during the Phase 1 → Phase 2 window.
Live drift detection lands in Phase 2 alongside the conductor-dev
commands/conduct.md duplicate of conductor-kernel/lib/dispatcher-core.md.
Phase 2 builder: replace this stub with the implementation per the
contract in this file's header comment block.

Canonical source:        $KERNEL_CORE
Canonical sha256:        $(sha256sum "$KERNEL_CORE" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$KERNEL_CORE" | awk '{print $1}')
Domain duplicate files:  (none yet — pending Phase 2)
BANNER

exit 0
