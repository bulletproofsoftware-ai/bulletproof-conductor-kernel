#!/bin/bash
# scripts/lib/paths.sh
#
# Shared path resolution for the kernel. Source this instead of hardcoding
# any absolute path.
#
# The kernel makes NO assumption about where sibling plugins live on disk.
# Every externally-owned path resolves in this order:
#
#   1. An explicit environment override, if the operator set one.
#   2. A conventional, XDG-ish location the operator can create.
#   3. A kernel-local fallback inside the plugin directory.
#
# Nothing here depends on a particular checkout layout (e.g. "~/Code/..").
#
# Usage:
#     . "${CLAUDE_PLUGIN_ROOT:-...}/scripts/lib/paths.sh"
#     db="$(kernel_audit_db_path)"

# --- kernel root -------------------------------------------------------------

# Resolve the kernel's own directory. CLAUDE_PLUGIN_ROOT is set by Claude Code
# when the kernel runs as an installed plugin; otherwise derive it from this
# file's location so the scripts also work from a plain git checkout.
kernel_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT}" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_ROOT}"
    return 0
  fi
  local this_dir
  this_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
  # scripts/lib -> scripts -> <kernel root>
  ( cd "${this_dir}/../.." && pwd )
}

# --- kernel-owned state ------------------------------------------------------

# Where the kernel keeps data it owns. Operators may relocate this wholesale.
kernel_state_dir() {
  if [ -n "${CONDUCTOR_STATE_DIR:-}" ]; then
    printf '%s\n' "${CONDUCTOR_STATE_DIR}"
    return 0
  fi
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/conductor-kernel"
}

# --- governance audit trail --------------------------------------------------

# Path to the governance-plugin audit database.
#
# governance-plugin is an OPTIONAL dependency. When it is not installed, audit
# emission degrades to a local JSONL fallback (see kernel_audit_fallback_path)
# rather than failing.
#
# Resolution order:
#   1. $AUDIT_DB_OVERRIDE            — explicit operator override
#   2. $GOVERNANCE_PLUGIN_ROOT/state/audit.db
#   3. $XDG_STATE_HOME/governance-plugin/state/audit.db  (conventional)
kernel_audit_db_path() {
  if [ -n "${AUDIT_DB_OVERRIDE:-}" ]; then
    printf '%s\n' "${AUDIT_DB_OVERRIDE}"
    return 0
  fi
  if [ -n "${GOVERNANCE_PLUGIN_ROOT:-}" ]; then
    printf '%s\n' "${GOVERNANCE_PLUGIN_ROOT}/state/audit.db"
    return 0
  fi
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/governance-plugin/state/audit.db"
}

# Local append-only fallback used when the audit DB is unavailable. Keeping
# events here means a missing governance-plugin never loses an event.
kernel_audit_fallback_path() {
  if [ -n "${CONDUCTOR_AUDIT_FALLBACK:-}" ]; then
    printf '%s\n' "${CONDUCTOR_AUDIT_FALLBACK}"
    return 0
  fi
  printf '%s\n' "$(kernel_root)/.audit-fallback.jsonl"
}

# --- Qdrant ------------------------------------------------------------------

# Qdrant REST endpoint. 6333 is Qdrant's documented default; operators who
# remap the host port set QDRANT_URL.
kernel_qdrant_url() {
  printf '%s\n' "${QDRANT_URL:-http://localhost:6333}"
}

# --- skill index -------------------------------------------------------------

# Directories scanned when building the skill index. The kernel's own skills
# are always included; operators add more via CONDUCTOR_SKILL_DIRS
# (colon-separated), which is how a sibling plugin's skills get indexed.
kernel_skill_dirs() {
  printf '%s\n' "$(kernel_root)/skills"
  if [ -n "${CONDUCTOR_SKILL_DIRS:-}" ]; then
    printf '%s\n' "${CONDUCTOR_SKILL_DIRS}" | tr ':' '\n' | while IFS= read -r d; do
      [ -n "$d" ] && printf '%s\n' "$d"
    done
  fi
}

# Where the generated skill index is written.
kernel_skill_index_path() {
  if [ -n "${CONDUCTOR_SKILL_INDEX:-}" ]; then
    printf '%s\n' "${CONDUCTOR_SKILL_INDEX}"
    return 0
  fi
  printf '%s\n' "$(kernel_state_dir)/skill-index.json"
}
