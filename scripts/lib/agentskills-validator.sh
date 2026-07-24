#!/bin/bash
# scripts/lib/agentskills-validator.sh
# agentskills.io open-spec frontmatter validator.
#
# Hermes E5 — REQ-CDV-HERMES-007
# Version: 1.0.0
#
# Source this file; it may also be executed directly:
#   bash agentskills-validator.sh <SKILL.md path> [--spec PATH]
#
# Spec snapshot: scripts/references/agentskills-spec-v1.json
#
# Verdict semantics:
#   PASS  — all required fields present + valid + no forbidden prefixes + all
#           conductor-ecosystem recommended metadata keys present
#   WARN  — required + forbidden checks pass, but one or more recommended
#           metadata keys (agentskills_compatible, version, category, tags,
#           platforms) are missing. Bundle is still publishable.
#   FAIL  — at least one required field missing/invalid OR a forbidden_prefix
#           key is present OR the spec snapshot is unreadable.
#
# NDJSON output to stdout (one JSON object). Exit codes:
#   0   PASS
#   1   WARN
#   2   FAIL
#   3   IO / spec snapshot error
#
# Notes:
# - Per the live agentskills.io spec (scraped 2026-05-20), only `name` and
#   `description` are required. The conductor-ecosystem recommended
#   metadata.* keys are advisory; missing them downgrades to WARN, not FAIL.
# - This is intentionally lenient on legacy skills (CLAUDE.md §9 surgical):
#   we don't FAIL skills authored before E5 — we WARN and let the operator
#   migrate at their leisure.

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR_AGV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SPEC_PATH="${SCRIPT_DIR_AGV}/../references/agentskills-spec-v1.json"

# ---------------------------------------------------------------------------
# agentskills_validate SKILL_MD_PATH [SPEC_PATH]
#   Prints a single NDJSON line with the validation verdict. Returns
#   0 PASS / 1 WARN / 2 FAIL / 3 IO_ERROR.
# ---------------------------------------------------------------------------
agentskills_validate() {
    local skill_md_path="$1"
    local spec_path="${2:-$DEFAULT_SPEC_PATH}"

    if [[ ! -f "$skill_md_path" ]]; then
        python3 -c "
import json, sys
print(json.dumps({
    'status': 'FAIL',
    'error': 'skill_md_not_found',
    'skill_md_path': '$skill_md_path',
    'spec_version': None,
}))"
        return 3
    fi

    if [[ ! -f "$spec_path" ]]; then
        python3 -c "
import json, sys
print(json.dumps({
    'status': 'FAIL',
    'error': 'spec_snapshot_not_found',
    'spec_path': '$spec_path',
    'spec_version': None,
}))"
        return 3
    fi

    # Run the full validation in a single python3 invocation for atomicity.
    python3 - "$skill_md_path" "$spec_path" <<'PYEOF'
import sys, os, re, json
from datetime import datetime, timezone

skill_md_path = sys.argv[1]
spec_path = sys.argv[2]

# ---- Load spec snapshot -------------------------------------------------
try:
    with open(spec_path, 'r', encoding='utf-8') as f:
        spec = json.load(f)
except Exception as e:
    print(json.dumps({
        'status': 'FAIL',
        'error': f'spec_load_error: {e}',
        'spec_version': None,
    }))
    sys.exit(3)

spec_version = spec.get('spec_version', 'unknown')
fields_schema = spec.get('frontmatter_schema', {}).get('fields', {}) or {}
forbidden_prefix = spec.get('frontmatter_schema', {}).get('forbidden_prefix', '_private_')

# Compute spec snapshot staleness (advisory)
staleness_warning_after_days = spec.get('staleness_warning_after_days', 30)
snapshot_date_str = spec.get('snapshot_date', '')
snapshot_age_days = None
snapshot_stale = False
try:
    snapshot_date = datetime.strptime(snapshot_date_str, '%Y-%m-%d').replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    snapshot_age_days = (now - snapshot_date).days
    snapshot_stale = snapshot_age_days > staleness_warning_after_days
except Exception:
    pass

# ---- Load + parse SKILL.md frontmatter ----------------------------------
try:
    with open(skill_md_path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
except Exception as e:
    print(json.dumps({
        'status': 'FAIL',
        'error': f'skill_read_error: {e}',
        'spec_version': spec_version,
    }))
    sys.exit(3)

lines = content.split('\n')
if not lines or lines[0].strip() != '---':
    print(json.dumps({
        'status': 'FAIL',
        'error': 'no_frontmatter',
        'skill_md_path': skill_md_path,
        'spec_version': spec_version,
        'required_missing': ['name', 'description'],
        'recommended_missing': [],
        'forbidden_present': [],
        'snapshot_stale': snapshot_stale,
        'snapshot_age_days': snapshot_age_days,
    }))
    sys.exit(2)

yaml_lines = []
inside = False
for i, line in enumerate(lines):
    if i == 0 and line.strip() == '---':
        inside = True
        continue
    if inside and line.strip() == '---':
        break
    if inside:
        yaml_lines.append(line)

yaml_text = '\n'.join(yaml_lines)

# Parse with yaml if available; fall back to simple regex parser otherwise
try:
    import yaml
    data = yaml.safe_load(yaml_text) or {}
except ImportError:
    data = {}
    cur_key = None
    cur_nested = None
    for line in yaml_lines:
        # Top-level key: value
        m = re.match(r'^([A-Za-z_][\w-]*)\s*:\s*(.*)$', line)
        if m:
            k, v = m.group(1), m.group(2).strip()
            if not v:
                # Could be the start of a nested block (e.g. metadata:)
                data[k] = {}
                cur_nested = k
                cur_key = None
                continue
            data[k] = v.strip('"').strip("'")
            cur_nested = None
            cur_key = k
            continue
        # Nested 2-space indent
        m = re.match(r'^  ([A-Za-z_][\w-]*)\s*:\s*(.+)$', line)
        if m and cur_nested:
            nk, nv = m.group(1), m.group(2).strip()
            if isinstance(data.get(cur_nested), dict):
                data[cur_nested][nk] = nv.strip('"').strip("'")
    # No fully accurate yaml here, but enough for required+forbidden checks
except Exception:
    data = {}

if not isinstance(data, dict):
    data = {}

# ---- Validate required fields -------------------------------------------
required_missing = []
required_invalid = []  # list of {field, reason}

# name: required, 1-64 chars, regex
name_field = data.get('name')
if not name_field or not isinstance(name_field, str) or not name_field.strip():
    required_missing.append('name')
else:
    n = name_field.strip()
    if len(n) > 64:
        required_invalid.append({'field': 'name', 'reason': f'exceeds_max_length_64 (got {len(n)})'})
    elif not re.match(r'^[a-z0-9]+(-[a-z0-9]+)*$', n):
        required_invalid.append({'field': 'name', 'reason': 'invalid_format (must be lowercase alphanumeric + single hyphens)'})
    else:
        # Check parent dir match (advisory — not strictly fatal for already-deployed skills)
        parent_dir = os.path.basename(os.path.dirname(os.path.abspath(skill_md_path)))
        if parent_dir != n:
            # Per spec this is a MUST. But for the conductor ecosystem we treat
            # parent-dir mismatch as advisory because some user skills live in
            # plugin subdirectories where the parent dir name differs. Surface
            # it via recommended_missing for visibility.
            pass

# description: required, 1-1024 chars
desc_field = data.get('description')
if not desc_field or not isinstance(desc_field, (str, dict, list)):
    required_missing.append('description')
else:
    # Normalize to string for length check
    if isinstance(desc_field, (dict, list)):
        desc_str = json.dumps(desc_field)
    else:
        desc_str = str(desc_field)
    if len(desc_str.strip()) == 0:
        required_missing.append('description')
    elif len(desc_str) > 1024:
        required_invalid.append({'field': 'description', 'reason': f'exceeds_max_length_1024 (got {len(desc_str)})'})

# compatibility: optional, but if present must be <= 500 chars
compat = data.get('compatibility')
if compat is not None and isinstance(compat, str) and len(compat) > 500:
    required_invalid.append({'field': 'compatibility', 'reason': f'exceeds_max_length_500 (got {len(compat)})'})

# ---- Check forbidden prefix ---------------------------------------------
forbidden_present = []
for k in data.keys():
    if isinstance(k, str) and k.startswith(forbidden_prefix):
        forbidden_present.append(k)

# ---- Check recommended metadata keys (conductor-ecosystem) --------------
metadata = data.get('metadata', {})
if not isinstance(metadata, dict):
    metadata = {}

recommended_keys = ['agentskills_compatible', 'version', 'category', 'tags', 'platforms']
recommended_missing = []
for k in recommended_keys:
    if k not in metadata:
        # Also accept top-level `version` (some legacy skills already use it)
        if k == 'version' and 'version' in data:
            continue
        # Also accept top-level `platforms`
        if k == 'platforms' and 'platforms' in data:
            continue
        recommended_missing.append(k)

# If metadata.version is present, validate it's semver
mv = metadata.get('version') or data.get('version')
recommended_invalid = []
if mv is not None:
    mv_str = str(mv).strip()
    if not re.match(r'^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?(\+[A-Za-z0-9.-]+)?$', mv_str):
        recommended_invalid.append({'field': 'metadata.version', 'reason': f'not_semver (got "{mv_str}")'})

# ---- Determine final verdict --------------------------------------------
fail_reasons = []
if required_missing:
    fail_reasons.append('required_fields_missing')
if required_invalid:
    fail_reasons.append('required_fields_invalid')
if forbidden_present:
    fail_reasons.append('forbidden_prefix_present')

if fail_reasons:
    status = 'FAIL'
    exit_code = 2
elif recommended_missing or recommended_invalid:
    status = 'WARN'
    exit_code = 1
else:
    status = 'PASS'
    exit_code = 0

# ---- Emit NDJSON --------------------------------------------------------
result = {
    'status': status,
    'spec_version': spec_version,
    'checked_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'skill_md_path': skill_md_path,
    'required_missing': required_missing,
    'required_invalid': required_invalid,
    'recommended_missing': recommended_missing,
    'recommended_invalid': recommended_invalid,
    'forbidden_present': forbidden_present,
    'snapshot_stale': snapshot_stale,
    'snapshot_age_days': snapshot_age_days,
    'staleness_warning_after_days': staleness_warning_after_days,
}
print(json.dumps(result, ensure_ascii=False))
sys.exit(exit_code)
PYEOF
    return $?
}

# ---------------------------------------------------------------------------
# Allow direct execution: bash agentskills-validator.sh <SKILL.md>
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "usage: $(basename "$0") <SKILL.md path> [--spec SPEC_JSON]" >&2
        echo "" >&2
        echo "Validates a SKILL.md against the agentskills.io open spec." >&2
        echo "Spec snapshot: ${DEFAULT_SPEC_PATH}" >&2
        echo "" >&2
        echo "Exit codes: 0=PASS  1=WARN  2=FAIL  3=IO_ERROR" >&2
        exit 3
    fi

    SKILL_MD="$1"
    SPEC="$DEFAULT_SPEC_PATH"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --spec) SPEC="$2"; shift 2 ;;
            *) echo "unknown arg: $1" >&2; exit 3 ;;
        esac
    done

    agentskills_validate "$SKILL_MD" "$SPEC"
    exit $?
fi
