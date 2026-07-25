#!/bin/bash
# scripts/lib/skill-index-helpers.sh
# Shared YAML frontmatter parsing helpers for build-skill-index.sh
#
# Source this file; do not execute directly.
# Usage: source "$(dirname "$0")/lib/skill-index-helpers.sh"

# ---------------------------------------------------------------------------
# parse_frontmatter SKILL_MD_PATH
#   Emits key=value pairs (newline-separated) parsed from the YAML frontmatter
#   block (text between the first two `---` fences) of SKILL_MD_PATH.
#   Uses python3 for YAML parsing — stdlib only, no external deps.
#   Prints to stdout; caller captures via:
#       eval "$(parse_frontmatter "$path")"
# ---------------------------------------------------------------------------
parse_frontmatter() {
    local path="$1"
    python3 - "$path" <<'PYTHON_EOF'
import sys, re, json

def sanitize_bash_var(v):
    """Escape single-quotes in a value for bash eval."""
    return str(v).replace("'", "'\\''")

def truncate(s, n):
    s = str(s).replace('\n', ' ').strip()
    return s[:n] + '...' if len(s) > n else s

path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
except Exception as e:
    print(f"FM_ERROR='{sanitize_bash_var(str(e))}'", flush=True)
    sys.exit(3)

# Extract YAML block between first two --- fences
lines = content.split('\n')
if not lines or lines[0].strip() != '---':
    # No frontmatter
    print("FM_NAME=''")
    print("FM_DESCRIPTION=''")
    print("FM_CATEGORY=''")
    print("FM_PLATFORMS=''")
    print("FM_TAGS=''")
    print("FM_VERSION=''")
    print("FM_AGENTSKILLS_COMPATIBLE=''")
    sys.exit(0)

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

# Parse with python3 yaml (stdlib pyyaml not guaranteed; use simple regex fallback)
data = {}
try:
    import yaml
    data = yaml.safe_load(yaml_text) or {}
except ImportError:
    # Fallback: extract simple key: value lines (handles most skill frontmatters)
    for line in yaml_lines:
        m = re.match(r'^(\w[\w_-]*)\s*:\s*(.+)$', line)
        if m:
            k, v = m.group(1), m.group(2).strip().strip('"').strip("'")
            data[k] = v
except Exception:
    data = {}

if not isinstance(data, dict):
    data = {}

name = data.get('name', '')
description = data.get('description', '')
if isinstance(description, dict):
    description = str(description)
description = truncate(description, 200)

# category: look in metadata.category, then top-level category, then 'uncategorized'
metadata = data.get('metadata', {}) or {}
if not isinstance(metadata, dict):
    metadata = {}
category = metadata.get('category', data.get('category', 'uncategorized')) or 'uncategorized'

# platforms
platforms = data.get('platforms', metadata.get('platforms', ['macos', 'linux']))
if isinstance(platforms, str):
    platforms = [platforms]
elif not isinstance(platforms, list):
    platforms = ['macos', 'linux']

# tags
tags = metadata.get('tags', data.get('tags', []))
if isinstance(tags, str):
    tags = [t.strip() for t in tags.split(',')]
elif not isinstance(tags, list):
    tags = []
tags = [str(t) for t in tags]

# version
version = str(data.get('version', '')) if data.get('version') is not None else ''

# agentskills_compatible
agentskills = metadata.get('agentskills_compatible', data.get('agentskills_compatible', False))
agentskills_str = 'true' if agentskills else 'false'

# Emit bash-eval-safe assignments
print(f"FM_NAME='{sanitize_bash_var(name)}'")
print(f"FM_DESCRIPTION='{sanitize_bash_var(description)}'")
print(f"FM_CATEGORY='{sanitize_bash_var(category)}'")
print(f"FM_PLATFORMS='{sanitize_bash_var(json.dumps(platforms))}'")
print(f"FM_TAGS='{sanitize_bash_var(json.dumps(tags))}'")
print(f"FM_VERSION='{sanitize_bash_var(version)}'")
print(f"FM_AGENTSKILLS_COMPATIBLE='{agentskills_str}'")
PYTHON_EOF
}

# ---------------------------------------------------------------------------
# json_escape STR
#   Minimal JSON string escaping (backslash, double-quote, control chars).
#   Avoids dependency on jq being available during the build loop.
# ---------------------------------------------------------------------------
json_escape() {
    python3 -c "import sys, json; print(json.dumps(sys.argv[1]))" "$1"
}

# ---------------------------------------------------------------------------
# enumerate_references SKILL_DIR
#   Prints JSON array of {path, size_tokens} objects for Level-2 reference
#   files associated with a skill.  Scans (in order):
#     1. SKILL_DIR/references/*.{md,yaml,yml,json}
#     2. SKILL_DIR/resources/*.{md,yaml,yml,json}
#     3. Sibling *.{md,json} files in SKILL_DIR itself (excluding SKILL.md,
#        SOURCES.json, and any uppercase-only names that are operational
#        metadata rather than reference content — e.g. README.md kept).
#   This covers skills like n8n-tools-and-validation whose companion docs
#   live as siblings rather than in a references/ subdirectory.
# ---------------------------------------------------------------------------
enumerate_references() {
    local skill_dir="$1"
    python3 - "$skill_dir" <<'PYTHON_EOF'
import sys, os, json

skill_dir = sys.argv[1]
refs = []
seen_rel = set()

REFERENCE_EXTS = ('.md', '.yaml', '.yml', '.json')
# Files to exclude from sibling enumeration
SIBLING_EXCLUDE = {'SKILL.md', 'SOURCES.json'}

def add_ref(fpath, rel):
    if rel in seen_rel:
        return
    seen_rel.add(rel)
    try:
        size_bytes = os.path.getsize(fpath)
    except OSError:
        size_bytes = 0
    size_tokens = max(1, size_bytes // 4)
    refs.append({"path": rel, "size_tokens": size_tokens})

# 1 & 2: references/ and resources/ subdirectories
for subdir in ('references', 'resources'):
    ref_dir = os.path.join(skill_dir, subdir)
    if not os.path.isdir(ref_dir):
        continue
    for fname in sorted(os.listdir(ref_dir)):
        if not fname.endswith(REFERENCE_EXTS):
            continue
        fpath = os.path.join(ref_dir, fname)
        if not os.path.isfile(fpath):
            continue
        rel = os.path.relpath(fpath, skill_dir)
        add_ref(fpath, rel)

# 3: sibling files in skill_dir (companion docs like SEARCH_GUIDE.md etc.)
try:
    for fname in sorted(os.listdir(skill_dir)):
        if fname in SIBLING_EXCLUDE:
            continue
        if not fname.endswith(REFERENCE_EXTS):
            continue
        fpath = os.path.join(skill_dir, fname)
        if not os.path.isfile(fpath):
            continue
        rel = fname  # relative to skill_dir is just the filename
        add_ref(fpath, rel)
except OSError:
    pass

print(json.dumps(refs))
PYTHON_EOF
}

# ---------------------------------------------------------------------------
# skill_source_label SKILL_MD_PATH USER_SKILLS_DIR KERNEL_SKILLS_DIR
#   Returns the source label: user | kernel | plugin:<name> | external:<dir> | unknown
# ---------------------------------------------------------------------------
skill_source_label() {
    local path="$1"
    local user_dir="$2"
    local kernel_dir="$3"

    case "$path" in
        "${user_dir}/"*)
            echo "user" ;;
        "${kernel_dir}/"*)
            echo "kernel" ;;
        */marketplaces/anthropic-agent-skills/*)
            echo "plugin:anthropic-agent-skills" ;;
        */marketplaces/claude-code-plugins/plugins/*/*)
            # Extract plugin name from path
            local plugin_name
            plugin_name=$(echo "$path" | sed 's|.*/claude-code-plugins/plugins/\([^/]*\)/.*|\1|')
            echo "plugin:${plugin_name}" ;;
        */marketplaces/claude-plugins-official/plugins/*/*)
            local plugin_name
            plugin_name=$(echo "$path" | sed 's|.*/claude-plugins-official/plugins/\([^/]*\)/.*|\1|')
            echo "plugin:${plugin_name}" ;;
        */plugins/local/*/*)
            local plugin_name
            plugin_name=$(echo "$path" | sed 's|.*/plugins/local/\([^/]*\)/.*|\1|')
            echo "plugin:${plugin_name}" ;;
        */skills/*)
            # An operator-declared directory (see $CONDUCTOR_SKILL_DIRS).
            # Label it with the project directory that contains skills/.
            local project_name
            project_name=$(echo "$path" | sed 's|/skills/.*||; s|.*/||')
            if [ -n "$project_name" ]; then
                echo "external:${project_name}"
            else
                echo "external"
            fi ;;
        *)
            echo "unknown" ;;
    esac
}
