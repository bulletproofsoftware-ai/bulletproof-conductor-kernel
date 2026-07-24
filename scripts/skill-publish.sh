#!/bin/bash
# scripts/skill-publish.sh
# /conduct skill publish <slug> — runner
#
# Hermes E5 — REQ-CDV-HERMES-008
# Version: 1.0.0
#
# Usage:
#   bash skill-publish.sh <slug> [--output DIR] [--skills-dir DIR] [--spec PATH]
#
# Defaults:
#   <slug>          required — resolves to <skills_dir>/<slug>/SKILL.md
#   --skills-dir    ~/.claude/skills
#   --output        <skills_dir>/<slug>/.publish
#   --spec          conductor-kernel/scripts/references/agentskills-spec-v1.json
#
# Process:
#   1. Verify ~/.claude/skills/<slug>/SKILL.md exists; exit 1 if not.
#   2. Validate frontmatter via agentskills-validator.sh.
#   3. Emit NDJSON compliance report to stdout.
#   4. If FAIL: exit 2, do NOT write bundle.
#   5. If PASS/WARN: bundle SKILL.md + references/ + scripts/ + assets/ to
#      <output>/, write manifest.json + README.md.
#
# Exit codes:
#   0  bundle written (PASS or WARN status)
#   1  filesystem / argument error
#   2  compliance FAIL — bundle not written
#   3  IO error during bundle write
#
# Notes:
# - Per CLAUDE.md §3.6 Hard Limit: writes only to <output> (default
#   <skill_dir>/.publish/). Never writes to MEMORY.md / CLAUDE.md.
# - Per CLAUDE.md §9 Surgical: does NOT modify the source SKILL.md. The
#   bundle is a copy with a manifest, ready for upload to agentskills.io.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/lib/agentskills-validator.sh"
DEFAULT_SPEC="${SCRIPT_DIR}/references/agentskills-spec-v1.json"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    cat <<USAGE >&2
usage: $(basename "$0") <slug> [--output DIR] [--skills-dir DIR] [--spec PATH]

Generate an agentskills.io-compliant portable bundle for a skill.

Reads:  <skills-dir>/<slug>/SKILL.md            (default skills-dir: ~/.claude/skills)
Writes: <output>/SKILL.md + manifest.json + README.md + references/ + scripts/ + assets/
        (default output: <skill_dir>/.publish/)

Exit:   0 bundle written (PASS/WARN), 1 arg/fs error, 2 compliance FAIL, 3 IO error
USAGE
    exit 1
fi

SLUG="$1"; shift
SKILLS_DIR="${HOME}/.claude/skills"
OUTPUT_DIR=""
SPEC_PATH="$DEFAULT_SPEC"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)      OUTPUT_DIR="$2"; shift 2 ;;
        --skills-dir)  SKILLS_DIR="$2"; shift 2 ;;
        --spec)        SPEC_PATH="$2"; shift 2 ;;
        *)             echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Validate slug shape (defensive — must match agentskills.io name regex)
if [[ ! "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "ERROR: slug '$SLUG' is not lowercase alphanumeric + hyphens (agentskills.io spec)" >&2
    exit 1
fi

SKILL_DIR="${SKILLS_DIR}/${SLUG}"
SKILL_MD="${SKILL_DIR}/SKILL.md"

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="${SKILL_DIR}/.publish"
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -d "$SKILL_DIR" ]]; then
    echo "ERROR: skill directory not found: $SKILL_DIR" >&2
    exit 1
fi
if [[ ! -f "$SKILL_MD" ]]; then
    echo "ERROR: SKILL.md not found: $SKILL_MD" >&2
    exit 1
fi
if [[ ! -f "$VALIDATOR" ]]; then
    echo "ERROR: validator missing: $VALIDATOR" >&2
    exit 1
fi
if [[ ! -f "$SPEC_PATH" ]]; then
    echo "ERROR: spec snapshot missing: $SPEC_PATH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Run compliance check
# ---------------------------------------------------------------------------
REPORT="$(bash "$VALIDATOR" "$SKILL_MD" --spec "$SPEC_PATH")"
RC=$?

# Emit the NDJSON report on stdout (caller / /conduct displays this)
echo "$REPORT"

case $RC in
    0)
        STATUS="PASS"
        ;;
    1)
        STATUS="WARN"
        ;;
    2)
        STATUS="FAIL"
        echo "" >&2
        echo "Compliance FAILED — bundle NOT written. Address required_missing / required_invalid / forbidden_present and re-run." >&2
        exit 2
        ;;
    3)
        echo "" >&2
        echo "Validator IO error — bundle NOT written." >&2
        exit 1
        ;;
    *)
        echo "" >&2
        echo "Validator returned unexpected exit code: $RC" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Build bundle (PASS or WARN)
# ---------------------------------------------------------------------------
# Clean prior .publish/ if present (don't merge stale files)
if [[ -d "$OUTPUT_DIR" ]]; then
    rm -rf "$OUTPUT_DIR"
fi

if ! mkdir -p "$OUTPUT_DIR"; then
    echo "ERROR: cannot create output dir: $OUTPUT_DIR" >&2
    exit 3
fi

# Copy SKILL.md (always)
if ! cp "$SKILL_MD" "${OUTPUT_DIR}/SKILL.md"; then
    echo "ERROR: failed to copy SKILL.md to bundle" >&2
    exit 3
fi

# Copy optional directories if present
for subdir in references resources scripts assets; do
    src="${SKILL_DIR}/${subdir}"
    if [[ -d "$src" ]]; then
        if ! cp -R "$src" "${OUTPUT_DIR}/${subdir}"; then
            echo "ERROR: failed to copy ${subdir}/ to bundle" >&2
            exit 3
        fi
    fi
done

# Build manifest.json + README.md via python3 (controlled JSON, controlled SHA256)
python3 - "$SLUG" "$SKILL_DIR" "$OUTPUT_DIR" "$SPEC_PATH" "$STATUS" "$REPORT" <<'PYEOF'
import sys, os, json, hashlib
from datetime import datetime, timezone

slug, skill_dir, output_dir, spec_path, status, report_json = sys.argv[1:7]

# Re-parse the NDJSON report
try:
    report = json.loads(report_json)
except json.JSONDecodeError:
    report = {'status': status, 'parse_error': 'could_not_parse_report'}

# Load spec for version info
spec_version = 'unknown'
try:
    with open(spec_path, 'r', encoding='utf-8') as f:
        spec = json.load(f)
    spec_version = spec.get('spec_version', 'unknown')
except Exception:
    pass

# Parse SKILL.md frontmatter for name + description + metadata
skill_md_path = os.path.join(output_dir, 'SKILL.md')
fm_name = slug
fm_description = ''
fm_version = ''
fm_metadata = {}
try:
    with open(skill_md_path, 'r', encoding='utf-8') as f:
        content = f.read()
    lines = content.split('\n')
    if lines and lines[0].strip() == '---':
        yaml_lines = []
        for i, line in enumerate(lines[1:], start=1):
            if line.strip() == '---':
                break
            yaml_lines.append(line)
        yaml_text = '\n'.join(yaml_lines)
        try:
            import yaml as _yaml
            data = _yaml.safe_load(yaml_text) or {}
            fm_name = str(data.get('name', slug))
            fm_description = str(data.get('description', '')).replace('\n', ' ').strip()[:512]
            fm_version = str(data.get('version', ''))
            md = data.get('metadata', {})
            if isinstance(md, dict):
                fm_metadata = md
                if not fm_version:
                    fm_version = str(md.get('version', ''))
        except ImportError:
            pass
except Exception:
    pass

# Walk bundle dir, compute sha256 per file
def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

files_entries = []
total_bytes = 0
for root, _dirs, files in os.walk(output_dir):
    for fname in sorted(files):
        # Skip the manifest itself (will be written last)
        if fname == 'manifest.json' and root == output_dir:
            continue
        if fname == 'README.md' and root == output_dir:
            continue
        fpath = os.path.join(root, fname)
        rel = os.path.relpath(fpath, output_dir)
        try:
            size = os.path.getsize(fpath)
            digest = sha256(fpath)
        except OSError:
            continue
        files_entries.append({
            'path': rel,
            'size_bytes': size,
            'sha256': digest,
        })
        total_bytes += size

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

manifest = {
    'name': fm_name,
    'slug': slug,
    'description': fm_description,
    'version': fm_version or None,
    'metadata': fm_metadata,
    'compliance_status': status,
    'compliance_report': report,
    'spec_version': spec_version,
    'bundled_at': now,
    'bundle_size_bytes': total_bytes,
    'files': files_entries,
    'generator': 'conductor-kernel/scripts/skill-publish.sh@1.0.0',
}

manifest_path = os.path.join(output_dir, 'manifest.json')
with open(manifest_path, 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')

# Short README inside the bundle pointing operators at the right targets
readme_path = os.path.join(output_dir, 'README.md')
warn_block = ''
if status == 'WARN':
    rec_missing = ', '.join(report.get('recommended_missing', [])) or 'none'
    warn_block = f"""
> **Compliance status: WARN.**
> The bundle is publishable but the following recommended metadata fields are missing: `{rec_missing}`.
> Add them to the source `SKILL.md` (under `metadata:`) to upgrade to PASS.
"""

readme = f"""# {fm_name} — agentskills.io bundle

This directory is a self-contained portable bundle of the `{slug}` skill,
generated by `conductor-kernel/scripts/skill-publish.sh` at {now}.

**Source**: `{skill_dir}/SKILL.md`
**agentskills.io spec snapshot**: `{spec_version}`
**Compliance status**: **{status}**
{warn_block}
## Contents

The canonical entry point is `SKILL.md`. Optional companion directories
(`references/`, `scripts/`, `assets/`) are copied verbatim from the source
skill when present.

## Manifest

`manifest.json` records every file in the bundle with its sha256 digest and
the full compliance report from the validator. This is the integrity
manifest — a hub-side upload pipeline can verify each file against the
digest before accepting the bundle.

## Upload

This bundle is suitable for upload to any agentskills.io-compatible skills
hub. The bundle is read-only with respect to the source skill — re-run
`skill-publish.sh` from the source after any edit to regenerate.

## Re-generating

```bash
bash {os.path.dirname(os.path.dirname(spec_path))}/skill-publish.sh {slug}
```
"""
with open(readme_path, 'w', encoding='utf-8') as f:
    f.write(readme)

# Print a summary line for the calling shell
summary = {
    'bundle_path': output_dir,
    'bundle_files': len(files_entries),
    'bundle_size_bytes': total_bytes,
    'compliance_status': status,
    'spec_version': spec_version,
    'name': fm_name,
    'version': fm_version or None,
}
print(json.dumps({'bundle_summary': summary}, ensure_ascii=False))
PYEOF
RC2=$?

if [[ $RC2 -ne 0 ]]; then
    echo "ERROR: bundle manifest/README generation failed (rc=$RC2)" >&2
    exit 3
fi

echo ""
echo "Bundle written to: $OUTPUT_DIR"
echo "  Compliance status : $STATUS"
echo "  Spec version      : $(python3 -c "import json; print(json.load(open('$SPEC_PATH'))['spec_version'])" 2>/dev/null)"
ls -la "$OUTPUT_DIR" 2>/dev/null | tail -n +2

exit 0
