#!/usr/bin/env bash
# scripts/lib/skill-mining-helpers.sh
#
# Hermes E1 — REQ-CDV-HERMES-009 / 010 / 011
# Shared helpers used by both skill-promote.sh and the retrospective agent's
# skill-mining workflow.
#
# Source this file:
#   source "$(dirname "$0")/lib/skill-mining-helpers.sh"
#
# Public functions (bash-only — Python heavy lifting is inline):
#
#   sm_compute_pattern_hash <execution_trace_json>
#     SHA-256 over the normalized tool-call sequence; reads the JSON via stdin
#     OR as $1 (a file path), prints hex digest.
#
#   sm_check_novelty <description_text> [<skill_index_json>]
#     Cosine-similarity check against ~/.claude/skill-index.json descriptions
#     (or supplied path). Returns 0 (novel) or 1 (covered). Prints the matched
#     skill name + similarity to stderr on coverage.
#
#   sm_sanitize_trajectory_payload <payload_text>
#     CISO-003 prompt-injection sanitization. Returns 0 (safe) or 1 (rejected).
#     On rejection, prints the matched regex name + a 60-char excerpt to stderr.
#
#   sm_query_trajectories_by_pattern <pattern_hash> [<since_iso8601>]
#     Queries Qdrant for trajectories matching this pattern_hash in the rolling
#     window. Requires QDRANT_API_KEY in env or sourced from .env. Returns
#     a JSON array of trajectory_ids on stdout; non-zero on error.
#
#   sm_render_skill_preview <skill_md_path>
#     CISO-003 rendered preview. Returns a sanitized text rendering of the
#     skill's "When To Use" + "Process" sections as a downstream agent would
#     see them via the Skill tool. Strips zero-width chars, normalizes RTL.
#
#   sm_check_promotion_threshold <pattern_hash> [<since_iso8601>]
#     Combined check: ≥3 invocations AND all recent 3 are outcome.success.
#     Returns 0 (eligible) + prints success_count on stdout. Non-zero on
#     ineligibility.
#
#   sm_audit_emit <event_type> <payload_json>
#     Appends a JSON-lines audit event to the active workflow's audit sink.
#     Honors CONDUCTOR_STATE_PATH if set, else looks in CWD.

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SM_DEFAULT_SKILL_INDEX="${HOME}/.claude/skill-index.json"
SM_QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
SM_OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
SM_EMBEDDING_MODEL="${OLLAMA_EMBED_MODEL:-nomic-embed-text}"

# ---------------------------------------------------------------------------
# Resolve QDRANT_API_KEY. Prefer the already-exported env var; fall back to the
# .env files used by your local Qdrant + claude-memory-mcp setups.
# Per CLAUDE.md: never echo or store the key — set it in a subshell var only.
# ---------------------------------------------------------------------------
sm__resolve_qdrant_key() {
    if [[ -n "${QDRANT_API_KEY:-}" ]]; then
        printf '%s' "$QDRANT_API_KEY"
        return 0
    fi
    local f
    for f in "${QDRANT_ENV_FILE:-~/.bulletproof-memory/.env}" "${HOME}/Code/claude-memory-mcp/.env"; do
        if [[ -f "$f" ]]; then
            local v
            v=$(grep -h '^QDRANT_API_KEY=' "$f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true)
            if [[ -n "$v" ]]; then
                printf '%s' "$v"
                return 0
            fi
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# sm_compute_pattern_hash
#
# Pattern hash is a SHA-256 of the pipe-joined tool sequence extracted from a
# trajectory's execution_trace[]. The script normalizes case + strips whitespace
# so that semantically-equivalent traces hash identically.
#
# Per the P0.2 schema verification (2026-05-20): Qdrant `trajectories` collection
# does NOT carry a pattern_hash field. We derive it client-side from the
# execution_trace[].tool sequence. The Qdrant payload contains:
#   - task_type
#   - task_description
#   - execution_trace[]: [{step, action, tool, decision?, output_summary?}, ...]
#   - outcome: {success: bool, metrics: {...}}
#   - created_at: ISO8601
#   - project
# No collection schema extension required.
# ---------------------------------------------------------------------------
sm_compute_pattern_hash() {
    local input_path="$1"
    python3 - "$input_path" <<'PYEOF'
import sys, json, hashlib
path = sys.argv[1]
try:
    if path == '-':
        data = json.load(sys.stdin)
    else:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
except Exception as e:
    print(f"ERROR: cannot read trajectory JSON: {e}", file=sys.stderr)
    sys.exit(2)

if isinstance(data, dict):
    payload = data.get('payload', data)
else:
    payload = {}

trace = payload.get('execution_trace') or []
if not isinstance(trace, list):
    print("ERROR: execution_trace is not a list", file=sys.stderr)
    sys.exit(2)

tools = []
for step in trace:
    if not isinstance(step, dict):
        continue
    t = step.get('tool')
    if t:
        tools.append(str(t).strip().lower())

if not tools:
    print("ERROR: no tool calls in execution_trace", file=sys.stderr)
    sys.exit(2)

joined = '|'.join(tools)
print(hashlib.sha256(joined.encode('utf-8')).hexdigest())
sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# sm_sanitize_trajectory_payload
#
# CISO-003 (BLOCKING) — prompt-injection sanitization. Scans task_description,
# decisions, and tool-output summaries for known injection signatures.
#
# Regex set:
#   - (?i)ignore (previous|prior|all) (instructions|prompts)
#   - (?i)system\s*[:>]\s*you are
#   - (?i)assistant\s*[:>]
#   - </?(system|assistant|tool)>
#   - <\|im_(start|end)\|>
#   - lines beginning with `### Override` / `### New Instructions`
#   - base64-looking blobs >200 chars
#
# Returns: 0 safe / 1 rejected (matched pattern name + 60-char excerpt on stderr)
#          2 sanitization-error (regex failed to execute — fail closed)
# ---------------------------------------------------------------------------
sm_sanitize_trajectory_payload() {
    local input="$1"
    python3 - "$input" <<'PYEOF'
import sys, re, json, base64

text = sys.argv[1]
# Allow reading from file path if it looks like one
import os
if len(text) < 2048 and os.path.isfile(text):
    try:
        with open(text, 'r', encoding='utf-8', errors='replace') as f:
            text = f.read()
    except Exception:
        pass

try:
    INJECTION_PATTERNS = [
        ('ignore_previous',  re.compile(r'(?i)ignore\s+(previous|prior|all)\s+(instructions|prompts)')),
        ('system_role',      re.compile(r'(?i)system\s*[:>]\s*you\s+are')),
        ('assistant_role',   re.compile(r'(?i)assistant\s*[:>]')),
        ('role_tag',         re.compile(r'</?(system|assistant|tool)>', re.IGNORECASE)),
        ('im_token',         re.compile(r'<\|im_(start|end)\|>')),
        ('override_heading', re.compile(r'(?m)^\s*###\s+(Override|New\s+Instructions)\b', re.IGNORECASE)),
    ]
    # Base64 blob detector: token of >=200 base64-alphabet chars
    B64_PAT = re.compile(r'[A-Za-z0-9+/=]{200,}')
except re.error as e:
    print(f"SANITIZATION_ERROR: regex compile failed: {e}", file=sys.stderr)
    sys.exit(2)

try:
    for name, pat in INJECTION_PATTERNS:
        m = pat.search(text)
        if m:
            excerpt = m.group(0).replace('\n', ' ')[:60]
            print(f"REJECTED: pattern={name} excerpt={excerpt!r}", file=sys.stderr)
            sys.exit(1)
    # Base64 blob detection — only flag if it actually decodes to readable bytes
    for m in B64_PAT.finditer(text):
        blob = m.group(0)
        try:
            decoded = base64.b64decode(blob, validate=True)
            # Heuristic: if >50% of decoded bytes are printable, treat as suspicious
            printable = sum(1 for b in decoded if 32 <= b < 127 or b in (9,10,13))
            if printable > len(decoded) * 0.5:
                excerpt = blob[:60]
                print(f"REJECTED: pattern=base64_blob length={len(blob)} excerpt={excerpt!r}", file=sys.stderr)
                sys.exit(1)
        except Exception:
            # Not valid base64 — ignore
            continue
except re.error as e:
    print(f"SANITIZATION_ERROR: regex execution failed: {e}", file=sys.stderr)
    sys.exit(2)
except Exception as e:
    # Fail closed on any unexpected error
    print(f"SANITIZATION_ERROR: unexpected: {e}", file=sys.stderr)
    sys.exit(2)

sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# sm_check_novelty
#
# Returns 0 if the description is novel (no skill in the index has cosine
# similarity >= 0.85), 1 if covered. On coverage, prints best-match name +
# similarity to stderr.
#
# Implementation: text-based Jaccard over normalized lowercase tokens as a
# zero-dependency proxy for cosine similarity. Real cosine-similarity would
# require Ollama embedding calls; for the gating threshold (0.85) Jaccard on
# 3-grams is a conservative-enough approximation. If the operator wants
# embedding-based similarity, set SM_USE_OLLAMA_SIM=1 to enable the live path.
# ---------------------------------------------------------------------------
sm_check_novelty() {
    local description="$1"
    local index_path="${2:-$SM_DEFAULT_SKILL_INDEX}"

    if [[ ! -f "$index_path" ]]; then
        # No index → treat everything as novel
        return 0
    fi

    python3 - "$description" "$index_path" "${SM_USE_OLLAMA_SIM:-0}" "$SM_OLLAMA_URL" "$SM_EMBEDDING_MODEL" <<'PYEOF'
import sys, json, re, urllib.request, urllib.error

description = sys.argv[1]
index_path = sys.argv[2]
use_ollama = sys.argv[3] == '1'
ollama_url = sys.argv[4]
embed_model = sys.argv[5]

try:
    with open(index_path, 'r', encoding='utf-8') as f:
        idx = json.load(f)
except Exception as e:
    # Index unreadable → treat as novel (don't block on tooling failure)
    print(f"NOTE: skill-index unreadable: {e}", file=sys.stderr)
    sys.exit(0)

skills = idx.get('skills', [])
if not isinstance(skills, list) or not skills:
    sys.exit(0)

THRESHOLD = 0.85

def normalize(s):
    s = (s or '').lower()
    s = re.sub(r'[^a-z0-9\s]', ' ', s)
    return re.sub(r'\s+', ' ', s).strip()

def ngrams(s, n=3):
    s = normalize(s)
    toks = s.split()
    if len(toks) < n:
        return set(toks)
    return {' '.join(toks[i:i+n]) for i in range(len(toks)-n+1)}

def jaccard(a, b):
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0

def embed(text):
    body = json.dumps({'model': embed_model, 'prompt': text}).encode()
    req = urllib.request.Request(f"{ollama_url}/api/embeddings", data=body,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())['embedding']

def cosine(a, b):
    if len(a) != len(b):
        return 0.0
    dot = sum(x*y for x, y in zip(a, b))
    na = sum(x*x for x in a) ** 0.5
    nb = sum(x*x for x in b) ** 0.5
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)

best_name, best_sim = None, 0.0

if use_ollama:
    try:
        target = embed(description)
        for s in skills:
            desc = s.get('description') or ''
            if not desc.strip():
                continue
            try:
                v = embed(desc)
                sim = cosine(target, v)
            except Exception:
                continue
            if sim > best_sim:
                best_sim = sim
                best_name = s.get('name')
    except Exception as e:
        # Fall back to Jaccard on embedding failure
        print(f"NOTE: Ollama embed failed, falling back to Jaccard: {e}", file=sys.stderr)
        use_ollama = False

if not use_ollama:
    target_grams = ngrams(description)
    for s in skills:
        desc = s.get('description') or ''
        if not desc.strip():
            continue
        sim = jaccard(target_grams, ngrams(desc))
        if sim > best_sim:
            best_sim = sim
            best_name = s.get('name')

if best_sim >= THRESHOLD and best_name:
    print(f"COVERED: best_match={best_name} similarity={best_sim:.3f}", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# sm_query_trajectories_by_pattern
#
# Returns a JSON array of {id, created_at, success} triples for trajectories
# whose derived pattern_hash matches the supplied hash, optionally filtered to
# `since` ISO8601 timestamp.
#
# Since Qdrant doesn't store pattern_hash, we scroll all matching trajectories
# in the window and compute the hash client-side. This is O(window-size) — fine
# for typical 90-day windows of <10k trajectories per project.
# ---------------------------------------------------------------------------
sm_query_trajectories_by_pattern() {
    local target_hash="$1"
    local since_iso="${2:-}"
    local key
    if ! key=$(sm__resolve_qdrant_key); then
        echo "ERROR: QDRANT_API_KEY not found in env or .env files" >&2
        return 2
    fi

    python3 - "$SM_QDRANT_URL" "$target_hash" "$since_iso" "$key" <<'PYEOF'
import sys, json, hashlib, urllib.request, urllib.error

qdrant_url = sys.argv[1]
target_hash = sys.argv[2]
since_iso = sys.argv[3]
api_key = sys.argv[4]

def pattern_hash_of(payload):
    trace = payload.get('execution_trace') or []
    tools = []
    for step in trace:
        if isinstance(step, dict):
            t = step.get('tool')
            if t:
                tools.append(str(t).strip().lower())
    if not tools:
        return None
    return hashlib.sha256('|'.join(tools).encode()).hexdigest()

results = []
offset = None
seen = 0
MAX_SCROLL = 10000  # safety cap

while seen < MAX_SCROLL:
    body = {"limit": 256, "with_payload": True, "with_vector": False}
    if offset is not None:
        body["offset"] = offset
    req = urllib.request.Request(
        f"{qdrant_url}/collections/trajectories/points/scroll",
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json', 'api-key': api_key},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            # Collection doesn't exist yet — empty result
            print('[]')
            sys.exit(0)
        print(f"ERROR: Qdrant HTTP {e.code}: {e.read()[:200].decode(errors='replace')}", file=sys.stderr)
        sys.exit(3)
    except Exception as e:
        print(f"ERROR: Qdrant request failed: {e}", file=sys.stderr)
        sys.exit(3)

    points = (data.get('result') or {}).get('points') or []
    if not points:
        break

    for p in points:
        seen += 1
        payload = p.get('payload') or {}
        ph = pattern_hash_of(payload)
        if ph != target_hash:
            continue
        created_at = payload.get('created_at') or ''
        if since_iso and created_at and created_at < since_iso:
            continue
        outcome = payload.get('outcome') or {}
        success = bool(outcome.get('success')) if isinstance(outcome, dict) else False
        results.append({
            'id': p.get('id'),
            'created_at': created_at,
            'success': success,
        })

    offset = (data.get('result') or {}).get('next_page_offset')
    if not offset:
        break

# Sort by created_at descending (most recent first)
results.sort(key=lambda r: r.get('created_at') or '', reverse=True)
print(json.dumps(results))
sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# sm_check_promotion_threshold
#
# Enforces the §3.6 hard limit: NO promotion without ≥3 successful invocations
# of the same pattern. Returns 0 + prints {success_count, trajectory_ids[]} on
# eligibility; non-zero otherwise.
# ---------------------------------------------------------------------------
sm_check_promotion_threshold() {
    local target_hash="$1"
    local since_iso="${2:-}"

    local matches
    matches=$(sm_query_trajectories_by_pattern "$target_hash" "$since_iso") || return $?

    python3 - <<PYEOF
import sys, json
matches = json.loads('''$matches''' or '[]')
if not isinstance(matches, list):
    sys.exit(2)

# Take the most-recent 3 (already sorted descending by created_at).
top3 = matches[:3]
if len(top3) < 3:
    print(f"INELIGIBLE: only {len(top3)} matching trajectories (need >=3)", file=sys.stderr)
    sys.exit(1)

all_success = all(m.get('success') is True for m in top3)
if not all_success:
    print(f"INELIGIBLE: most-recent 3 not all outcome.success", file=sys.stderr)
    sys.exit(1)

success_count = sum(1 for m in matches if m.get('success') is True)
out = {
    'success_count': success_count,
    'trajectory_ids': [m['id'] for m in top3],
}
print(json.dumps(out))
sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# sm_render_skill_preview
#
# Renders the "When To Use" + "Process" sections of a SKILL.md so the operator
# sees what a downstream agent would see when the Skill tool loads it.
#
# Sanitization applied on render:
#   - Strip zero-width characters (U+200B, U+200C, U+200D, U+2060, U+FEFF)
#   - Normalize RTL/LTR override marks (U+202A..U+202E, U+2066..U+2069)
#   - Collapse runs of whitespace
#   - Truncate to 4000 chars
# ---------------------------------------------------------------------------
sm_render_skill_preview() {
    local skill_md="$1"
    if [[ ! -f "$skill_md" ]]; then
        echo "ERROR: SKILL.md not found: $skill_md" >&2
        return 1
    fi

    python3 - "$skill_md" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

# Strip frontmatter
lines = content.split('\n')
body_start = 0
if lines and lines[0].strip() == '---':
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            body_start = i + 1
            break
body = '\n'.join(lines[body_start:])

# Extract "When To Use" and "Process" sections
def extract_section(text, heading_patterns):
    # heading_patterns: list of regex strings to match the heading
    pat = '|'.join(heading_patterns)
    sections = re.split(r'(?m)^#{1,3}\s+', text)
    # First element is pre-heading content; subsequent ones start with the heading text
    for s in sections[1:]:
        first_line = s.split('\n', 1)[0].strip().lower()
        for hp in heading_patterns:
            if re.search(hp, first_line, re.IGNORECASE):
                return '## ' + s.rstrip()
    return None

when_section = extract_section(body, [r'when\s+to\s+use', r'when\s+to\s+run'])
process_section = extract_section(body, [r'process', r'protocol', r'algorithm', r'steps?'])

# Sanitize: strip zero-width + RTL/LTR override marks
ZW_PAT = re.compile(r'[​-‍⁠﻿‪-‮⁦-⁩]')

preview_parts = []
preview_parts.append("=" * 70)
preview_parts.append("RENDERED SKILL PREVIEW (CISO-003 — what a downstream agent sees)")
preview_parts.append("=" * 70)
preview_parts.append("")

if when_section:
    cleaned = ZW_PAT.sub('', when_section)
    if len(cleaned) > 2000:
        cleaned = cleaned[:2000] + "\n[...truncated]"
    preview_parts.append(cleaned)
    preview_parts.append("")
else:
    preview_parts.append("(no 'When To Use' section found)")
    preview_parts.append("")

if process_section:
    cleaned = ZW_PAT.sub('', process_section)
    if len(cleaned) > 2000:
        cleaned = cleaned[:2000] + "\n[...truncated]"
    preview_parts.append(cleaned)
    preview_parts.append("")
else:
    preview_parts.append("(no 'Process' section found)")
    preview_parts.append("")

preview_parts.append("=" * 70)
out = '\n'.join(preview_parts)
print(out)
PYEOF
}

# ---------------------------------------------------------------------------
# sm_audit_emit
#
# Emits a JSON-lines audit event to <state-dir>/.conductor-cache/audit-events.jsonl.
# The audit_emitter.py hook will pick it up on next state write.
# Honors CONDUCTOR_STATE_PATH (env) or auto-discovers conductor-state.json in CWD.
# ---------------------------------------------------------------------------
sm_audit_emit() {
    local event_type="$1"
    local payload_json="$2"
    local state_path="${CONDUCTOR_STATE_PATH:-$(pwd)/conductor-state.json}"
    local audit_dir
    audit_dir="$(dirname "$state_path")/.conductor-cache"
    mkdir -p "$audit_dir"
    local audit_file="${audit_dir}/audit-events.jsonl"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Build record via python so payload_json is properly nested (not stringified)
    python3 - "$event_type" "$ts" "$payload_json" "$audit_file" <<'PYEOF'
import sys, json, os
event_type, ts, payload_raw, audit_file = sys.argv[1:5]
try:
    payload = json.loads(payload_raw)
except json.JSONDecodeError:
    payload = {"raw": payload_raw}
record = {
    "ts": ts,
    "event_type": event_type,
    "source": "conductor-kernel:skill-mining",
    "payload": payload,
}
os.makedirs(os.path.dirname(audit_file), exist_ok=True)
with open(audit_file, 'a', encoding='utf-8') as f:
    f.write(json.dumps(record) + '\n')
PYEOF
}

# ---------------------------------------------------------------------------
# sm_slug_from_pattern
#
# Generates a kebab-case skill slug from a trajectory's task_description.
# Heuristic: extract the dominant verb + first salient noun (excluding stopwords).
# ---------------------------------------------------------------------------
sm_slug_from_pattern() {
    local task_description="$1"
    python3 - "$task_description" <<'PYEOF'
import sys, re
text = sys.argv[1].lower()
# Strip non-alphanumeric to spaces
text = re.sub(r'[^a-z0-9\s]', ' ', text)
toks = [t for t in text.split() if t]
STOPS = {
    'a','an','the','to','of','in','for','on','at','by','with','from','and',
    'or','but','this','that','these','those','is','are','was','were','be',
    'been','being','have','has','had','do','does','did','will','would',
    'should','could','can','may','might','must','shall','via','use','using',
}
salient = [t for t in toks if t not in STOPS]
if not salient:
    print('untitled-skill')
    sys.exit(0)
slug = '-'.join(salient[:4])
slug = re.sub(r'-+', '-', slug).strip('-')
if not slug:
    slug = 'untitled-skill'
print(slug[:64])
PYEOF
}

# ---------------------------------------------------------------------------
# Direct execution: bash skill-mining-helpers.sh <subcommand> ...
# Provided primarily for CLI testing.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    sub="${1:-}"
    shift || true
    case "$sub" in
        pattern-hash)       sm_compute_pattern_hash "${1:--}" ;;
        sanitize)           sm_sanitize_trajectory_payload "${1:-}" ;;
        novelty)            sm_check_novelty "${1:-}" "${2:-$SM_DEFAULT_SKILL_INDEX}" ;;
        query-pattern)      sm_query_trajectories_by_pattern "${1:-}" "${2:-}" ;;
        check-threshold)    sm_check_promotion_threshold "${1:-}" "${2:-}" ;;
        render-preview)     sm_render_skill_preview "${1:-}" ;;
        slug)               sm_slug_from_pattern "${1:-}" ;;
        audit)              sm_audit_emit "${1:-}" "${2:-{}}" ;;
        *)
            cat <<USAGE >&2
usage: $(basename "$0") <subcommand> [args]

  pattern-hash    <trajectory_json_path|->     SHA-256 of normalized tool sequence
  sanitize        <text_or_file>                CISO-003 prompt-injection check
  novelty         <description> [<index_json>] Jaccard/cosine vs skill-index
  query-pattern   <hash> [<since_iso>]          Qdrant scroll, filter by pattern
  check-threshold <hash> [<since_iso>]          ≥3 successful invocations check
  render-preview  <SKILL.md path>               Sanitized When-To-Use+Process preview
  slug            <task_description>            Kebab-case slug
  audit           <event_type> <payload_json>   Append audit event
USAGE
            exit 2
            ;;
    esac
fi
