#!/usr/bin/env bash
# scripts/skill-promote.sh
#
# Hermes E1 — REQ-CDV-HERMES-009 / 010
# Operator-gated promotion of an agent-drafted skill from
# ~/.claude/skills/_proposed/<slug>/ to ~/.claude/skills/<slug>/.
#
# This script is invoked by the `/conduct promote-skill <slug>` subcommand.
# It MUST NEVER auto-promote — operator approval (the literal token APPROVE
# read from stdin) is required to advance.
#
# Process (per spec §1.2 + CISO-003 remediations):
#   1. Load ~/.claude/skills/_proposed/<slug>/SKILL.md (FAIL if missing)
#   2. Run superpowers:writing-skills file-level shape check (frontmatter +
#      seven-section). On FAIL: print findings, exit 2.
#   3. Run agentskills-validator.sh (E5 validator). FAIL = exit 2; WARN = print
#      and proceed.
#   4. Render the sanitized "When To Use" + "Process" preview (CISO-003).
#   5. Print side-by-side draft contents + validator + preview.
#   6. Read operator's APPROVE / REJECT / anything-else from stdin.
#   7. On APPROVE: move draft → ~/.claude/skills/<slug>/, append registry
#      entry, emit `skill_promoted` audit event, refresh skill-index.
#   8. On REJECT: prompt for reason, move draft → _rejected/<slug>-<ts>/,
#      write REJECTION.txt, emit `skill_promotion_rejected` audit event.
#   9. On cancel: leave _proposed/<slug>/ untouched, exit 0.
#
# Exit codes:
#   0 = success / reject / cancel (operator-controlled)
#   1 = missing draft / argument error
#   2 = validator failure (writing-skills shape or agentskills FAIL)
#   3 = reviewer blocking failure (reserved)
#   4 = filesystem error
#   5 = audit emission error (non-blocking — only set if state file unreadable)

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/skill-mining-helpers.sh
source "${LIB_DIR}/skill-mining-helpers.sh"
# shellcheck source=lib/agentskills-validator.sh
source "${LIB_DIR}/agentskills-validator.sh"

USER_SKILLS_DIR="${HOME}/.claude/skills"
PROPOSED_DIR="${USER_SKILLS_DIR}/_proposed"
REJECTED_DIR="${USER_SKILLS_DIR}/_rejected"
REGISTRY_PATH="${HOME}/.claude/skill-registry.json"
BUILD_INDEX_SCRIPT="${SCRIPT_DIR}/build-skill-index.sh"

mkdir -p "$PROPOSED_DIR" "$REJECTED_DIR"

die() { echo "skill-promote: ERROR: $*" >&2; exit "${2:-1}"; }
log() { echo "skill-promote: $*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    cat <<USAGE >&2
usage: skill-promote.sh <slug>

  Promote an agent-drafted skill from ~/.claude/skills/_proposed/<slug>/ to
  ~/.claude/skills/<slug>/ after operator review.

  Operator must type APPROVE (literal) to promote, REJECT to archive, or
  anything else to cancel.

Exit codes:
  0   success / reject / cancel
  1   missing draft / argument error
  2   validator failure
  4   filesystem error
USAGE
    exit 1
fi

SLUG="$1"
# Validate slug shape
if [[ ! "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    die "invalid slug '$SLUG' — must match ^[a-z0-9]+(-[a-z0-9]+)*$" 1
fi

DRAFT_DIR="${PROPOSED_DIR}/${SLUG}"
DRAFT_MD="${DRAFT_DIR}/SKILL.md"

if [[ ! -d "$DRAFT_DIR" ]]; then
    die "no draft directory at $DRAFT_DIR" 1
fi
if [[ ! -f "$DRAFT_MD" ]]; then
    die "draft SKILL.md not found at $DRAFT_MD" 1
fi

# ---------------------------------------------------------------------------
# Step 1: writing-skills file-level shape check
#
# We can't invoke a Skill via bash directly; instead we implement the file-level
# check as documented in writing-skills (frontmatter present + seven-section
# structure). This is the lower-bound — the operator is the final reviewer.
# ---------------------------------------------------------------------------
log "Step 1: writing-skills file-level shape check on $DRAFT_MD"

WRITING_SKILLS_RESULT=$(python3 - "$DRAFT_MD" <<'PYEOF'
import sys, re, json

path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

findings = []

# Frontmatter check
lines = content.split('\n')
if not lines or lines[0].strip() != '---':
    findings.append({'severity': 'CRITICAL', 'rule': 'frontmatter_missing',
                     'detail': 'SKILL.md must start with a --- YAML frontmatter block'})
else:
    fm_end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            fm_end = i
            break
    if fm_end is None:
        findings.append({'severity': 'CRITICAL', 'rule': 'frontmatter_unterminated',
                         'detail': 'Frontmatter block has no closing ---'})
    else:
        fm = '\n'.join(lines[1:fm_end])
        # Required fields per writing-skills + global CLAUDE.md template
        if not re.search(r'^\s*name\s*:\s*\S', fm, re.MULTILINE):
            findings.append({'severity': 'CRITICAL', 'rule': 'name_missing',
                             'detail': 'Frontmatter must include `name:` field'})
        if not re.search(r'^\s*description\s*:\s*\S', fm, re.MULTILINE):
            findings.append({'severity': 'CRITICAL', 'rule': 'description_missing',
                             'detail': 'Frontmatter must include `description:` field'})

# Seven-section structure check (per CLAUDE.md skill template standard)
REQUIRED_SECTIONS = [
    (r'(?im)^#{1,3}\s+when\s+to\s+(use|run)\b', 'when_to_use'),
    (r'(?im)^#{1,3}\s+(context|inputs?)\b', 'context'),
    (r'(?im)^#{1,3}\s+(process|protocol|algorithm|steps?)\b', 'process'),
    (r'(?im)^#{1,3}\s+(output\s+format|deliverables?|outputs?)\b', 'output_format'),
    (r'(?im)^#{1,3}\s+(guardrails?|constraints?|hard\s+limits?)\b', 'guardrails'),
]
ADVISORY_SECTIONS = [
    (r'(?im)^#{1,3}\s+(standalone|degraded)\s+mode\b', 'standalone_mode'),
]

for pat, name in REQUIRED_SECTIONS:
    if not re.search(pat, content):
        findings.append({'severity': 'HIGH', 'rule': f'section_missing:{name}',
                         'detail': f'Seven-section template requires a "{name}" section'})

for pat, name in ADVISORY_SECTIONS:
    if not re.search(pat, content):
        findings.append({'severity': 'ADVISORY', 'rule': f'section_missing:{name}',
                         'detail': f'Recommended section "{name}" not found'})

critical = [f for f in findings if f['severity'] == 'CRITICAL']
high     = [f for f in findings if f['severity'] == 'HIGH']
advisory = [f for f in findings if f['severity'] == 'ADVISORY']

result = {
    'status': 'FAIL' if (critical or high) else ('WARN' if advisory else 'PASS'),
    'findings': findings,
    'counts': {
        'critical': len(critical),
        'high': len(high),
        'advisory': len(advisory),
    },
}
print(json.dumps(result, indent=2))
sys.exit(0 if not (critical or high) else 2)
PYEOF
)
WS_EXIT=$?

echo "writing-skills validator output:"
echo "$WRITING_SKILLS_RESULT"
echo ""

if [[ $WS_EXIT -ne 0 ]]; then
    log "writing-skills validator FAILED — cannot promote."
    exit 2
fi

# ---------------------------------------------------------------------------
# Step 2: agentskills-validator.sh (E5)
# ---------------------------------------------------------------------------
log "Step 2: agentskills.io spec validator (E5)"
AGV_OUT=$(agentskills_validate "$DRAFT_MD")
AGV_EXIT=$?

echo "agentskills validator output:"
echo "$AGV_OUT" | python3 -m json.tool 2>/dev/null || echo "$AGV_OUT"
echo ""

if [[ $AGV_EXIT -eq 2 ]]; then
    log "agentskills validator FAILED — cannot promote."
    exit 2
fi
if [[ $AGV_EXIT -eq 3 ]]; then
    log "agentskills validator IO_ERROR (advisory) — proceeding."
fi

# ---------------------------------------------------------------------------
# Step 3: CISO-003 rendered preview
# ---------------------------------------------------------------------------
log "Step 3: CISO-003 rendered preview"
echo ""
PREVIEW=$(sm_render_skill_preview "$DRAFT_MD")
echo "$PREVIEW"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Sanitization of the draft content itself
# ---------------------------------------------------------------------------
log "Step 4: prompt-injection sanitization on draft text"
DRAFT_TEXT=$(cat "$DRAFT_MD")
if ! sm_sanitize_trajectory_payload "$DRAFT_TEXT" 2>/tmp/.skill-promote-sanit.$$; then
    SANIT_REASON=$(cat /tmp/.skill-promote-sanit.$$ 2>/dev/null || echo "unknown")
    rm -f /tmp/.skill-promote-sanit.$$
    log "DRAFT FAILED SANITIZATION: $SANIT_REASON"
    log "Draft will NOT be promoted. Move to _rejected/ manually if appropriate."
    exit 2
fi
rm -f /tmp/.skill-promote-sanit.$$
log "Sanitization passed."

# ---------------------------------------------------------------------------
# Step 5: Show diff against any existing skill of the same slug
# ---------------------------------------------------------------------------
EXISTING_SKILL="${USER_SKILLS_DIR}/${SLUG}/SKILL.md"
if [[ -f "$EXISTING_SKILL" ]]; then
    echo ""
    echo "===== DIFF vs existing ~/.claude/skills/${SLUG}/SKILL.md ====="
    diff -u "$EXISTING_SKILL" "$DRAFT_MD" || true
    echo "===== END DIFF ====="
    echo ""
    log "WARNING: skill '$SLUG' already exists — APPROVE will overwrite the existing skill."
else
    echo ""
    echo "===== NEW SKILL (no existing ~/.claude/skills/${SLUG}/) ====="
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 6: Display the full draft
# ---------------------------------------------------------------------------
echo "===== DRAFT CONTENTS ($DRAFT_MD) ====="
cat "$DRAFT_MD"
echo "===== END DRAFT ====="
echo ""

# ---------------------------------------------------------------------------
# Step 7: Operator approval gate (BLOCKING — no auto-promotion)
# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
echo "Type APPROVE to promote, REJECT to archive, or anything else to cancel."
echo "================================================================="
printf "Operator decision: "

# Read from stdin — refuse to proceed if stdin is closed (defensive: prevent
# accidental auto-promotion if the script is invoked from a non-interactive
# context).
if [[ -t 0 ]] || [[ -n "${SKILL_PROMOTE_NONINTERACTIVE_DECISION:-}" ]]; then
    if [[ -n "${SKILL_PROMOTE_NONINTERACTIVE_DECISION:-}" ]]; then
        # Test-only path; the env var is for fixture tests only.
        DECISION="$SKILL_PROMOTE_NONINTERACTIVE_DECISION"
        echo "(non-interactive: $DECISION)"
    else
        IFS= read -r DECISION || DECISION=""
    fi
else
    log "stdin is closed and SKILL_PROMOTE_NONINTERACTIVE_DECISION not set — refusing to auto-decide."
    log "Re-run interactively or set SKILL_PROMOTE_NONINTERACTIVE_DECISION (test fixtures only)."
    exit 1
fi

case "$DECISION" in
    APPROVE)
        log "Operator APPROVED — promoting draft."
        ;;
    REJECT)
        log "Operator REJECTED — archiving draft."
        printf "Reason (one line): "
        IFS= read -r REJECT_REASON || REJECT_REASON="(no reason given)"
        TS=$(date -u +%Y%m%dT%H%M%SZ)
        REJ_DIR="${REJECTED_DIR}/${SLUG}-${TS}"
        if ! mv "$DRAFT_DIR" "$REJ_DIR"; then
            die "filesystem error moving $DRAFT_DIR to $REJ_DIR" 4
        fi
        printf '%s\n\nRejected at: %s\n' "$REJECT_REASON" "$TS" > "${REJ_DIR}/REJECTION.txt"

        AUDIT_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'slug': '$SLUG',
    'rejected_path': '$REJ_DIR',
    'reason': '''$REJECT_REASON'''.replace(chr(10),' ')[:200],
}))")
        sm_audit_emit "skill_promotion_rejected" "$AUDIT_PAYLOAD" || true
        log "Rejected and archived: $REJ_DIR"
        exit 0
        ;;
    *)
        log "Operator did not approve — leaving draft in place."
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Step 8 (APPROVE path): Atomic move + registry append + audit
# ---------------------------------------------------------------------------
TARGET_DIR="${USER_SKILLS_DIR}/${SLUG}"
BACKUP_DIR=""
if [[ -d "$TARGET_DIR" ]]; then
    BACKUP_DIR="${USER_SKILLS_DIR}/.backup-${SLUG}-$(date -u +%Y%m%dT%H%M%SZ)"
    log "Backing up existing $TARGET_DIR → $BACKUP_DIR"
    if ! mv "$TARGET_DIR" "$BACKUP_DIR"; then
        die "filesystem error backing up $TARGET_DIR" 4
    fi
fi

if ! mv "$DRAFT_DIR" "$TARGET_DIR"; then
    # Rollback backup
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        mv "$BACKUP_DIR" "$TARGET_DIR" || true
    fi
    die "filesystem error promoting $DRAFT_DIR to $TARGET_DIR" 4
fi

log "Promoted: $TARGET_DIR"

# ---------------------------------------------------------------------------
# Step 9: Registry append (best-effort — rollback on failure)
# ---------------------------------------------------------------------------
REGISTRY_OK=true
if [[ -f "$REGISTRY_PATH" ]]; then
    if ! python3 - "$REGISTRY_PATH" "$TARGET_DIR/SKILL.md" "$SLUG" <<'PYEOF'
import sys, json, os, re
from datetime import datetime, timezone

registry_path = sys.argv[1]
skill_md      = sys.argv[2]
slug          = sys.argv[3]

try:
    with open(registry_path, 'r', encoding='utf-8') as f:
        reg = json.load(f)
except Exception as e:
    print(f"registry read failed: {e}", file=sys.stderr)
    sys.exit(1)

if 'skills' not in reg or not isinstance(reg['skills'], list):
    reg['skills'] = []

# Parse frontmatter
try:
    with open(skill_md, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
except Exception as e:
    print(f"skill read failed: {e}", file=sys.stderr)
    sys.exit(1)

lines = content.split('\n')
fm_lines = []
if lines and lines[0].strip() == '---':
    for line in lines[1:]:
        if line.strip() == '---':
            break
        fm_lines.append(line)

fm = {}
for ln in fm_lines:
    m = re.match(r'^([a-zA-Z_][\w-]*)\s*:\s*(.+)$', ln)
    if m:
        fm[m.group(1)] = m.group(2).strip().strip('"').strip("'")

# Compute flags
has_guardrails = 'guardrail' in content.lower()
has_standalone = 'standalone mode' in content.lower()

# Look for data-classification-gate in frontmatter
dcg = fm.get('data-classification-gate', '').lower() in ('true', 'yes', '1')
js = fm.get('jurisdiction-scope', '')

entry = {
    'name': fm.get('name', slug),
    'path': skill_md,
    'jurisdiction_scope': js or None,
    'last_updated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'template_compliant': True,
    'has_guardrails': has_guardrails,
    'has_standalone_mode': has_standalone,
    'data_classification_gate': dcg,
}

# Remove any prior entry with same name
reg['skills'] = [s for s in reg['skills'] if s.get('name') != entry['name']]
reg['skills'].append(entry)

tmp = registry_path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(reg, f, indent=2, ensure_ascii=False)
os.replace(tmp, registry_path)
print(f"registry: appended/updated entry for {entry['name']}")
PYEOF
    then
        REGISTRY_OK=false
        log "WARNING: registry append failed — rolling back promotion."
        # Rollback: move target back to _proposed and restore backup
        if mv "$TARGET_DIR" "$DRAFT_DIR" 2>/dev/null; then
            if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
                mv "$BACKUP_DIR" "$TARGET_DIR" || true
            fi
        fi
        sm_audit_emit "skill_promotion_rolled_back" "{\"slug\":\"$SLUG\",\"reason\":\"registry_write_failed\"}" || true
        die "registry write failed — promotion rolled back" 4
    fi
else
    log "NOTE: ~/.claude/skill-registry.json not found — skipping registry append."
fi

# ---------------------------------------------------------------------------
# Step 10: Emit skill_promoted audit event
# ---------------------------------------------------------------------------
TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TRAJECTORY_IDS_JSON="${SKILL_PROMOTE_TRAJECTORY_IDS:-[]}"
PROMOTED_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'slug': '$SLUG',
    'promoted_path': '$TARGET_DIR/SKILL.md',
    'trajectory_ids': json.loads('''$TRAJECTORY_IDS_JSON'''),
    'promoted_at': '$TS_NOW',
}))")
sm_audit_emit "skill_promoted" "$PROMOTED_PAYLOAD" || log "WARN: audit emit failed (non-blocking)"

# ---------------------------------------------------------------------------
# Step 11: Refresh skill-index.json
# ---------------------------------------------------------------------------
if [[ -x "$BUILD_INDEX_SCRIPT" ]]; then
    log "Refreshing skill-index via $BUILD_INDEX_SCRIPT"
    bash "$BUILD_INDEX_SCRIPT" >/dev/null 2>&1 || log "WARN: skill-index refresh failed (non-blocking)"
fi

log "Promotion complete: $TARGET_DIR"
exit 0
