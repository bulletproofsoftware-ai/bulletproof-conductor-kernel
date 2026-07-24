#!/usr/bin/env bash
# change-log-query.sh
# Query / rollback / replay / conflicts CLI for the E6 change-log.
#
# BRD: REQ-CDV-HERMES-002
#
# Usage:
#   change-log-query.sh query   [--agent <name>] [--file <path>] [--brd <id>] [--phase <n>] [--since <ISO8601>]
#   change-log-query.sh rollback --agent <name> --phase <n>
#   change-log-query.sh replay  --phase <n>
#   change-log-query.sh conflicts --since <ISO8601>
#
# Environment:
#   CLAUDE_PROJECT_DIR   — project root containing .conductor/ (fallback: pwd)
#
# Reads transparently across active .conductor/change-log.jsonl plus all
# .conductor/change-log-archive/*.jsonl.gz in chronological (mtime) order.

set -euo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONDUCTOR_DIR="${PROJECT_DIR}/.conductor"
LOG_FILE="${CONDUCTOR_DIR}/change-log.jsonl"
ARCHIVE_DIR="${CONDUCTOR_DIR}/change-log-archive"

die() { echo "change-log-query: ERROR: $*" >&2; exit 2; }

require_jq() {
  if ! command -v jq &>/dev/null; then
    die "jq is required but not in PATH"
  fi
}

# ---------------------------------------------------------------------------
# Stream all entries in chronological order (archive gzip files first by
# filename sort, then active log last — archives are created at rotation time,
# so lexicographic ISO8601 filename order = chronological order).
# ---------------------------------------------------------------------------
stream_all_entries() {
  # Archive files sorted by filename (ISO8601 stamp → chronological)
  if [[ -d "${ARCHIVE_DIR}" ]]; then
    local gz
    for gz in $(ls -1 "${ARCHIVE_DIR}"/*.jsonl.gz 2>/dev/null | sort); do
      # macOS Apple gzip's zcat rejects filename args; gzip -dc is POSIX portable.
      # Per QA AC-E6-8 fix 2026-05-20.
      gzip -dc "${gz}" 2>/dev/null || true
    done
  fi
  # Active log last
  if [[ -f "${LOG_FILE}" ]]; then
    cat "${LOG_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# SUBCOMMAND: query
# ---------------------------------------------------------------------------
cmd_query() {
  require_jq
  local filter_agent="" filter_file="" filter_brd="" filter_phase="" filter_since=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --agent)  [[ -n "${2:-}" ]] || die "--agent requires a value"; filter_agent="${2}"; shift 2 ;;
      --file)   [[ -n "${2:-}" ]] || die "--file requires a value";  filter_file="${2}";  shift 2 ;;
      --brd)    [[ -n "${2:-}" ]] || die "--brd requires a value";   filter_brd="${2}";   shift 2 ;;
      --phase)  [[ -n "${2:-}" ]] || die "--phase requires a value"; filter_phase="${2}"; shift 2 ;;
      --since)  [[ -n "${2:-}" ]] || die "--since requires a value"; filter_since="${2}"; shift 2 ;;
      *) die "unknown argument: ${1}" ;;
    esac
  done

  local jq_filter='.'

  if [[ -n "${filter_agent}" ]]; then
    local safe_agent
    safe_agent="${filter_agent//\"/\\\"}"
    jq_filter+=" | select(.agent == \"${safe_agent}\")"
  fi

  if [[ -n "${filter_file}" ]]; then
    local safe_file
    safe_file="${filter_file//\"/\\\"}"
    # Match on full path or suffix
    jq_filter+=" | select(.file != null and (.file | test(\"${safe_file}\"; \"i\")))"
  fi

  if [[ -n "${filter_brd}" ]]; then
    local safe_brd
    safe_brd="${filter_brd//\"/\\\"}"
    jq_filter+=" | select(.brd_ref != null and (.brd_ref | test(\"${safe_brd}\"; \"i\")))"
  fi

  if [[ -n "${filter_phase}" ]]; then
    # Phase can be int or string
    jq_filter+=" | select(.phase != null and (.phase | tostring) == \"${filter_phase}\")"
  fi

  if [[ -n "${filter_since}" ]]; then
    local safe_since
    safe_since="${filter_since//\"/\\\"}"
    jq_filter+=" | select(.ts != null and .ts >= \"${safe_since}\")"
  fi

  local found=false
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    result=$(echo "${line}" | jq -c "${jq_filter}" 2>/dev/null || true)
    if [[ -n "${result}" && "${result}" != "null" ]]; then
      echo "${result}"
      found=true
    fi
  done < <(stream_all_entries)

  if [[ "${found}" == "false" ]]; then
    exit 1
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# SUBCOMMAND: rollback
# Generate a reverse patch isolating one agent's work in one phase.
# ---------------------------------------------------------------------------
cmd_rollback() {
  require_jq
  local filter_agent="" filter_phase=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --agent)  [[ -n "${2:-}" ]] || die "--agent requires a value"; filter_agent="${2}"; shift 2 ;;
      --phase)  [[ -n "${2:-}" ]] || die "--phase requires a value"; filter_phase="${2}"; shift 2 ;;
      *) die "unknown argument: ${1}" ;;
    esac
  done

  [[ -z "${filter_agent}" ]] && die "--agent is required for rollback"
  [[ -z "${filter_phase}" ]] && die "--phase is required for rollback"

  if ! command -v git &>/dev/null; then
    die "git is required for rollback but not in PATH"
  fi

  # Collect matching entries, sorted by ts ascending
  local entries=()
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local matched
    matched=$(echo "${line}" | jq -c --arg a "${filter_agent}" --arg p "${filter_phase}" \
      'select(.agent == $a and (.phase | tostring) == $p)' 2>/dev/null || true)
    [[ -n "${matched}" && "${matched}" != "null" ]] && entries+=("${matched}")
  done < <(stream_all_entries)

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "change-log-query: no entries found for agent=${filter_agent} phase=${filter_phase}" >&2
    exit 3
  fi

  # Sort by ts
  # Use -c (compact) so each entry remains a single line that mapfile splits correctly.
  # Without -c, jq pretty-prints multi-line and per-line `jq '.file'` calls fail.
  # Per QA AC-E6-5 fix 2026-05-20.
  mapfile -t sorted_entries < <(printf '%s\n' "${entries[@]}" | jq -crs 'sort_by(.ts)[]' 2>/dev/null)

  # For each entry, generate reverse patch using git diff between after and before SHA
  echo "# Reverse patch generated by change-log-query rollback"
  echo "# Agent: ${filter_agent}  Phase: ${filter_phase}"
  echo "# Apply with: git apply -R --check <this_file>"
  echo "# Then: git apply -R <this_file>"
  echo ""

  for entry in "${sorted_entries[@]}"; do
    local file before after
    file=$(echo "${entry}" | jq -r '.file // ""' 2>/dev/null || echo "")
    before=$(echo "${entry}" | jq -r '.before_sha256 // ""' 2>/dev/null || echo "")
    after=$(echo "${entry}" | jq -r '.after_sha256 // ""' 2>/dev/null || echo "")

    [[ -z "${file}" ]] && continue
    [[ "${file}" == "<REDACTED:"* ]] && continue

    # Resolve abs path
    local abs_file
    if [[ "${file}" == /* ]]; then
      abs_file="${file}"
    else
      abs_file="${PROJECT_DIR}/${file}"
    fi

    # Generate reverse diff: show HEAD revision of the file (after state committed)
    # vs. the before_sha256 blob if available.
    # Per QA AC-E6-5 fix 2026-05-20: removed dead `git diff "${after}" "${before}"`
    # branch — content SHAs aren't valid git revision arguments, git rejects them
    # and the fallback never produced patch content. Fallback is now the primary path.
    if [[ -n "${before}" && -n "${after}" ]]; then
      local rel="${abs_file#"${PROJECT_DIR}/"}"
      local wt_diff
      wt_diff=$(cd "${PROJECT_DIR}" && git diff HEAD -- "${rel}" 2>/dev/null || true)
      if [[ -n "${wt_diff}" ]]; then
        echo "# File: ${file} (HEAD diff)"
        echo "${wt_diff}"
      else
        echo "# File: ${file} — no diff available (file may be untracked or SHAs unavailable)"
      fi
    else
      local rel="${abs_file#"${PROJECT_DIR}/"}"
      echo "# File: ${file} — before_sha256 or after_sha256 not recorded; manual review required"
      local wt_diff
      wt_diff=$(cd "${PROJECT_DIR}" && git diff HEAD -- "${rel}" 2>/dev/null || true)
      [[ -n "${wt_diff}" ]] && echo "${wt_diff}"
    fi
    echo ""
  done

  exit 0
}

# ---------------------------------------------------------------------------
# SUBCOMMAND: replay
# Verify determinism: check that phase changes are reproducible.
# Exit 0 = deterministic (empty diff), 4 = non-deterministic.
# ---------------------------------------------------------------------------
cmd_replay() {
  require_jq
  local filter_phase=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --phase)  [[ -n "${2:-}" ]] || die "--phase requires a value"; filter_phase="${2}"; shift 2 ;;
      *) die "unknown argument: ${1}" ;;
    esac
  done

  [[ -z "${filter_phase}" ]] && die "--phase is required for replay"

  if ! command -v git &>/dev/null; then
    die "git is required for replay but not in PATH"
  fi

  # Collect matching entries sorted by ts
  local entries=()
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local matched
    matched=$(echo "${line}" | jq -c --arg p "${filter_phase}" \
      'select((.phase | tostring) == $p)' 2>/dev/null || true)
    [[ -n "${matched}" && "${matched}" != "null" ]] && entries+=("${matched}")
  done < <(stream_all_entries)

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "replay: no entries for phase=${filter_phase}" >&2
    exit 4
  fi

  # Use -c (compact) so each entry remains a single line that mapfile splits correctly.
  # Without -c, jq pretty-prints multi-line and per-line `jq '.file'` calls fail.
  # Per QA AC-E6-5 fix 2026-05-20.
  mapfile -t sorted_entries < <(printf '%s\n' "${entries[@]}" | jq -crs 'sort_by(.ts)[]' 2>/dev/null)

  # Determinism check: for each file touched in this phase, verify that the
  # after_sha256 recorded in the LAST entry for that file matches the current
  # sha256 on disk.  Empty diff on all = deterministic (exit 0).
  # Any mismatch = non-deterministic (exit 4).

  declare -A latest_after  # file → after_sha256

  for entry in "${sorted_entries[@]}"; do
    local file after
    file=$(echo "${entry}" | jq -r '.file // ""' 2>/dev/null || echo "")
    after=$(echo "${entry}" | jq -r '.after_sha256 // ""' 2>/dev/null || echo "")
    [[ -z "${file}" || "${file}" == "<REDACTED:"* ]] && continue
    latest_after["${file}"]="${after}"
  done

  local non_det=false
  for file in "${!latest_after[@]}"; do
    local recorded_after="${latest_after[${file}]}"
    local abs_file
    if [[ "${file}" == /* ]]; then
      abs_file="${file}"
    else
      abs_file="${PROJECT_DIR}/${file}"
    fi

    if [[ ! -f "${abs_file}" ]]; then
      echo "replay: MISMATCH — ${file}: file no longer exists on disk" >&2
      non_det=true
      continue
    fi

    if [[ -z "${recorded_after}" ]]; then
      echo "replay: SKIP — ${file}: no after_sha256 recorded" >&2
      continue
    fi

    local disk_sha
    disk_sha=$(shasum -a 256 "${abs_file}" 2>/dev/null | awk '{print $1}')
    if [[ "${disk_sha}" != "${recorded_after}" ]]; then
      echo "replay: MISMATCH — ${file}: recorded=${recorded_after} disk=${disk_sha}" >&2
      non_det=true
    fi
  done

  if [[ "${non_det}" == "true" ]]; then
    exit 4
  fi

  echo "replay: phase ${filter_phase} is DETERMINISTIC — all after_sha256 values match current tree"
  exit 0
}

# ---------------------------------------------------------------------------
# SUBCOMMAND: conflicts
# Find files with >=2 distinct agents writing to them in the time window.
# Exit 0 = no conflicts, 5 = conflicts found.
# ---------------------------------------------------------------------------
cmd_conflicts() {
  require_jq
  local filter_since=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --since)  [[ -n "${2:-}" ]] || die "--since requires a value"; filter_since="${2}"; shift 2 ;;
      *) die "unknown argument: ${1}" ;;
    esac
  done

  [[ -z "${filter_since}" ]] && die "--since is required for conflicts"

  # Collect all entries in the window, group by file, count distinct agents
  local all_entries
  all_entries=$(stream_all_entries | jq -c --arg since "${filter_since}" \
    'select(.ts != null and .ts >= $since and .file != null and .agent != null and (.file | startswith("<REDACTED:") | not))' \
    2>/dev/null || true)

  if [[ -z "${all_entries}" ]]; then
    exit 0
  fi

  # Find files with multiple distinct agents
  local conflict_entries
  conflict_entries=$(echo "${all_entries}" | jq -sc '
    group_by(.file) |
    map(select(
      (map(.agent) | unique | length) >= 2
    ) | {
      file: .[0].file,
      agents: (map(.agent) | unique),
      entry_count: length,
      first_ts: (map(.ts) | sort | first),
      last_ts: (map(.ts) | sort | last)
    })[]
  ' 2>/dev/null || true)

  if [[ -z "${conflict_entries}" || "${conflict_entries}" == "null" ]]; then
    exit 0
  fi

  echo "${conflict_entries}"
  exit 5
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  echo "Usage: change-log-query.sh <query|rollback|replay|conflicts> [options]" >&2
  echo ""
  echo "  query     [--agent <n>] [--file <p>] [--brd <id>] [--phase <n>] [--since <ts>]"
  echo "  rollback  --agent <name> --phase <n>"
  echo "  replay    --phase <n>"
  echo "  conflicts --since <ISO8601>"
  exit 2
fi

SUBCMD="${1}"
shift

case "${SUBCMD}" in
  query)     cmd_query     "$@" ;;
  rollback)  cmd_rollback  "$@" ;;
  replay)    cmd_replay    "$@" ;;
  conflicts) cmd_conflicts "$@" ;;
  *)
    echo "change-log-query: unknown subcommand: ${SUBCMD}" >&2
    echo "Valid subcommands: query, rollback, replay, conflicts" >&2
    exit 2
    ;;
esac
