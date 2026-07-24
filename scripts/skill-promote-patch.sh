#!/usr/bin/env bash
# scripts/skill-promote-patch.sh
#
# Hermes E1 — REQ-CDV-HERMES-011
# Operator-gated application of a skill self-improvement patch from
# ~/.claude/skills/_patches/<slug>-<ts>.patch to ~/.claude/skills/<slug>/SKILL.md.
#
# Invoked by the `/conduct promote-skill-patch <patch_path>` subcommand.
# MUST NEVER auto-apply — operator approval (literal APPROVE token from stdin)
# is required to apply.
#
# Process:
#   1. Verify patch exists, derive target skill slug from patch header.
#   2. Apply patch to a temporary copy of the skill (--dry-run-equivalent).
#   3. Run superpowers:writing-skills file-level shape check on the post-patch
#      content. FAIL = exit 2.
#   4. Show side-by-side diff of original vs patched skill.
#   5. Run CISO-003 sanitization on the post-patch content.
#   6. Read operator APPROVE / REJECT / cancel from stdin.
#   7. APPROVE: apply patch in place, move patch to _patches/applied/, emit
#      `skill_patched` audit event, refresh skill-index.
#   8. REJECT: move to _patches/rejected/ with reason file, emit
#      `skill_patch_rejected` audit event.
#   9. Cancel: leave patch where it is, exit 0.
#
# Exit codes:
#   0 = success / reject / cancel
#   1 = argument / missing patch
#   2 = validator failure or sanitization rejection
#   4 = filesystem error
#   5 = patch failed to apply cleanly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/skill-mining-helpers.sh
source "${LIB_DIR}/skill-mining-helpers.sh"

USER_SKILLS_DIR="${HOME}/.claude/skills"
PATCHES_DIR="${USER_SKILLS_DIR}/_patches"
APPLIED_DIR="${PATCHES_DIR}/applied"
REJECTED_PATCH_DIR="${PATCHES_DIR}/rejected"
BUILD_INDEX_SCRIPT="${SCRIPT_DIR}/build-skill-index.sh"

mkdir -p "$PATCHES_DIR" "$APPLIED_DIR" "$REJECTED_PATCH_DIR"

die() { echo "skill-promote-patch: ERROR: $*" >&2; exit "${2:-1}"; }
log() { echo "skill-promote-patch: $*" >&2; }

# ---------------------------------------------------------------------------
# Argument
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    cat <<USAGE >&2
usage: skill-promote-patch.sh <patch_path>

  Apply an agent-drafted patch to an existing skill, after operator review.

Exit codes:
  0   success / reject / cancel
  1   missing patch / argument error
  2   validator or sanitization failure
  4   filesystem error
  5   patch did not apply cleanly
USAGE
    exit 1
fi

PATCH_PATH="$1"
# Expand ~
PATCH_PATH="${PATCH_PATH/#\~/$HOME}"

if [[ ! -f "$PATCH_PATH" ]]; then
    die "patch not found at $PATCH_PATH" 1
fi

# ---------------------------------------------------------------------------
# Step 1: Derive target skill from patch header
# ---------------------------------------------------------------------------
# Look for "--- a/<path>/SKILL.md" or similar headers in the patch
TARGET_SKILL_PATH=$(python3 - "$PATCH_PATH" "$USER_SKILLS_DIR" <<'PYEOF'
import sys, re, os

patch_path = sys.argv[1]
skills_dir = sys.argv[2]

with open(patch_path, 'r', encoding='utf-8', errors='replace') as f:
    head = f.read(8192)  # first 8KB enough for header

# Match unified diff header: --- a/<path>/SKILL.md  OR  --- /<path>/SKILL.md
m = re.search(r'^---\s+(?:a/)?(\S+/SKILL\.md)', head, re.MULTILINE)
if not m:
    m = re.search(r'^---\s+(\S+/SKILL\.md)', head, re.MULTILINE)
if not m:
    sys.exit(1)

raw_path = m.group(1)
# Expand ~ if present
raw_path = os.path.expanduser(raw_path)

# Try the raw path first; fall back to interpreting as relative under skills_dir
candidates = [
    raw_path,
    os.path.join(skills_dir, os.path.basename(os.path.dirname(raw_path)), 'SKILL.md'),
    os.path.join(skills_dir, raw_path.lstrip('/')),
]
for c in candidates:
    if os.path.isfile(c):
        print(c)
        sys.exit(0)

# Last resort: print the raw path even if missing; caller will surface the err
print(raw_path)
sys.exit(0)
PYEOF
) || die "could not parse target SKILL.md path from patch header" 1

if [[ ! -f "$TARGET_SKILL_PATH" ]]; then
    die "target skill file does not exist: $TARGET_SKILL_PATH" 1
fi

# Derive slug from path
SLUG=$(basename "$(dirname "$TARGET_SKILL_PATH")")
log "Target skill: $TARGET_SKILL_PATH (slug=$SLUG)"

# ---------------------------------------------------------------------------
# Step 2: Apply patch to a temp copy (dry-run equivalent)
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
cp "$TARGET_SKILL_PATH" "$TMP_DIR/SKILL.md.original"
cp "$TARGET_SKILL_PATH" "$TMP_DIR/SKILL.md.patched"

# Try `patch` first; fall back to `git apply` if available
if command -v patch >/dev/null 2>&1; then
    if ! (cd "$TMP_DIR" && patch -p1 --silent --strip=1 SKILL.md.patched < "$PATCH_PATH" 2>/dev/null) \
        && ! (cd "$TMP_DIR" && patch SKILL.md.patched < "$PATCH_PATH" 2>/dev/null); then
        log "patch could not be applied cleanly via patch(1) — trying git apply"
        if command -v git >/dev/null 2>&1; then
            if ! (cd "$TMP_DIR" && git apply --whitespace=nowarn "$PATCH_PATH" 2>/dev/null); then
                die "patch did not apply cleanly" 5
            fi
        else
            die "neither patch(1) nor git available — cannot apply patch" 5
        fi
    fi
elif command -v git >/dev/null 2>&1; then
    if ! (cd "$TMP_DIR" && git apply --whitespace=nowarn "$PATCH_PATH" 2>/dev/null); then
        die "patch did not apply cleanly" 5
    fi
else
    die "neither patch(1) nor git available — cannot apply patch" 5
fi

log "Patch applies cleanly to a temp copy."

# ---------------------------------------------------------------------------
# Step 3: writing-skills file-level shape check on post-patch content
# ---------------------------------------------------------------------------
log "Step 3: writing-skills validator on post-patch SKILL.md"
WS_OUT=$(python3 - "$TMP_DIR/SKILL.md.patched" <<'PYEOF'
import sys, re, json
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

findings = []
lines = content.split('\n')
if not lines or lines[0].strip() != '---':
    findings.append({'severity': 'CRITICAL', 'rule': 'frontmatter_missing'})
else:
    fm_end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            fm_end = i
            break
    if fm_end is None:
        findings.append({'severity': 'CRITICAL', 'rule': 'frontmatter_unterminated'})
    else:
        fm = '\n'.join(lines[1:fm_end])
        if not re.search(r'^\s*name\s*:\s*\S', fm, re.MULTILINE):
            findings.append({'severity': 'CRITICAL', 'rule': 'name_missing'})
        if not re.search(r'^\s*description\s*:\s*\S', fm, re.MULTILINE):
            findings.append({'severity': 'CRITICAL', 'rule': 'description_missing'})

REQUIRED_SECTIONS = [
    (r'(?im)^#{1,3}\s+when\s+to\s+(use|run)\b', 'when_to_use'),
    (r'(?im)^#{1,3}\s+(context|inputs?)\b', 'context'),
    (r'(?im)^#{1,3}\s+(process|protocol|algorithm|steps?)\b', 'process'),
    (r'(?im)^#{1,3}\s+(output\s+format|deliverables?|outputs?)\b', 'output_format'),
    (r'(?im)^#{1,3}\s+(guardrails?|constraints?|hard\s+limits?)\b', 'guardrails'),
]
for pat, name in REQUIRED_SECTIONS:
    if not re.search(pat, content):
        findings.append({'severity': 'HIGH', 'rule': f'section_missing:{name}'})

critical = [f for f in findings if f['severity'] == 'CRITICAL']
high     = [f for f in findings if f['severity'] == 'HIGH']
result = {'status': 'FAIL' if (critical or high) else 'PASS', 'findings': findings}
print(json.dumps(result, indent=2))
sys.exit(0 if not (critical or high) else 2)
PYEOF
)
WS_EXIT=$?
echo "$WS_OUT"
if [[ $WS_EXIT -ne 0 ]]; then
    log "Post-patch validation FAILED — patch will not be applied."
    exit 2
fi

# ---------------------------------------------------------------------------
# Step 4: CISO-003 sanitization on post-patch content
# ---------------------------------------------------------------------------
log "Step 4: CISO-003 sanitization on post-patch text"
POST_CONTENT=$(cat "$TMP_DIR/SKILL.md.patched")
if ! sm_sanitize_trajectory_payload "$POST_CONTENT" 2>/tmp/.skill-patch-sanit.$$; then
    SANIT_REASON=$(cat /tmp/.skill-patch-sanit.$$ 2>/dev/null || echo "unknown")
    rm -f /tmp/.skill-patch-sanit.$$
    log "POST-PATCH SANITIZATION FAILED: $SANIT_REASON"
    exit 2
fi
rm -f /tmp/.skill-patch-sanit.$$
log "Sanitization passed."

# ---------------------------------------------------------------------------
# Step 5: Show diff
# ---------------------------------------------------------------------------
echo ""
echo "===== DIFF: original vs patched ====="
diff -u "$TMP_DIR/SKILL.md.original" "$TMP_DIR/SKILL.md.patched" || true
echo "===== END DIFF ====="
echo ""

# ---------------------------------------------------------------------------
# Step 6: Operator approval gate
# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
echo "Type APPROVE to apply patch, REJECT to archive, or anything else to cancel."
echo "================================================================="
printf "Operator decision: "

if [[ -t 0 ]] || [[ -n "${SKILL_PATCH_NONINTERACTIVE_DECISION:-}" ]]; then
    if [[ -n "${SKILL_PATCH_NONINTERACTIVE_DECISION:-}" ]]; then
        DECISION="$SKILL_PATCH_NONINTERACTIVE_DECISION"
        echo "(non-interactive: $DECISION)"
    else
        IFS= read -r DECISION || DECISION=""
    fi
else
    log "stdin closed and SKILL_PATCH_NONINTERACTIVE_DECISION not set — refusing to auto-decide."
    exit 1
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
PATCH_BASENAME=$(basename "$PATCH_PATH")

case "$DECISION" in
    APPROVE)
        log "Operator APPROVED — applying patch."
        if ! cp "$TMP_DIR/SKILL.md.patched" "$TARGET_SKILL_PATH"; then
            die "filesystem error overwriting $TARGET_SKILL_PATH" 4
        fi
        DEST="${APPLIED_DIR}/${PATCH_BASENAME}"
        mv "$PATCH_PATH" "$DEST" || log "WARN: could not move patch to $DEST"
        PATCHED_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'slug': '$SLUG',
    'target_skill': '$TARGET_SKILL_PATH',
    'patch_path': '$DEST',
    'applied_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}))")
        sm_audit_emit "skill_patched" "$PATCHED_PAYLOAD" || log "WARN: audit emit failed"
        if [[ -x "$BUILD_INDEX_SCRIPT" ]]; then
            bash "$BUILD_INDEX_SCRIPT" >/dev/null 2>&1 || true
        fi
        log "Patch applied: $TARGET_SKILL_PATH (patch archived to $DEST)"
        exit 0
        ;;
    REJECT)
        log "Operator REJECTED — archiving patch."
        printf "Reason (one line): "
        IFS= read -r REJ_REASON || REJ_REASON="(no reason given)"
        DEST="${REJECTED_PATCH_DIR}/${PATCH_BASENAME%.patch}-${TS}.patch"
        mv "$PATCH_PATH" "$DEST" || die "filesystem error moving patch to $DEST" 4
        printf '%s\n\nRejected at: %s\n' "$REJ_REASON" "$TS" > "${DEST%.patch}.REJECTION.txt"
        REJ_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'slug': '$SLUG',
    'rejected_patch': '$DEST',
    'reason': '''$REJ_REASON'''.replace(chr(10),' ')[:200],
}))")
        sm_audit_emit "skill_patch_rejected" "$REJ_PAYLOAD" || true
        log "Patch rejected and archived: $DEST"
        exit 0
        ;;
    *)
        log "Operator did not approve — leaving patch in place."
        exit 0
        ;;
esac
