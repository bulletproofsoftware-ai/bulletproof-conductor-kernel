# Test — Audit Emission (Phase 1 Exit Gate (c))

**Implements**: kernel-api.md §13.3 — REQ-KER-018 `kernel.audit_emit`.

## Goal

Verify that `kernel.audit_emit` writes audit rows correctly to the governance-plugin audit database, with the expected file mode and integrity guarantees — or, if governance-plugin is not installed, confirm the check degrades cleanly to a SKIP rather than a false failure.

`governance-plugin` is an **optional** dependency. If it is not installed, this
whole test is expected to SKIP (exit 77) — that is a PASS-equivalent, supported
outcome, not a defect. Do not treat SKIP as something to "fix" by installing
governance-plugin unless you actually want the database-backed audit trail.

## Procedure

### Step 1 — Mechanical pre-checks (automated)

```bash
bash scripts/verify-audit-emission.sh
```

The database path is resolved by `scripts/lib/paths.sh` (`kernel_audit_db_path`):
`$AUDIT_DB_OVERRIDE`, else `$GOVERNANCE_PLUGIN_ROOT/state/audit.db`, else
`${XDG_STATE_HOME:-~/.local/state}/governance-plugin/state/audit.db`.

Expected outcomes:

- **Exit 0 (PASS)** — governance-plugin is installed and its audit.db is present,
  is a regular file, is readable, and is mode `0600` per RC-5.
- **Exit 3 (advisory PASS)** — audit.db present and readable, but file mode could
  not be determined (non-POSIX `stat`).
- **Exit 1 (FAIL)** — audit.db exists at the resolved path but is not a regular
  file, is unreadable, or has the wrong mode. This is a real defect — fix it
  (e.g. `chmod 600`) and re-run.
- **Exit 77 (SKIP)** — no audit database found at the resolved path, because
  governance-plugin is not installed. Treat this the same as a PASS for the
  purposes of this test; the kernel is using its local JSONL fallback instead.

### Step 2 — Synthetic `kernel.audit_emit` round-trip (manual, inside Claude Code)

Requires governance-plugin to be installed (skip this step if Step 1 exited 77).
Inside an active `/conduct` session (Phase 2+) or via a temporary debug command, invoke:

```
kernel.audit_emit("test.phase1_verification", {
  trace_id:  "p1-verify-<timestamp>",
  parent_id: null,
  timestamp: <ISO-8601 now>
})
```

Capture the returned `event_id`.

### Step 3 — Verify the row

Read the row back from `audit.db` at the path resolved in Step 1 (`$KERNEL/scripts/lib/paths.sh` → `kernel_audit_db_path`):

```bash
AUDIT_DB="$(. "$KERNEL/scripts/lib/paths.sh" && kernel_audit_db_path)"
sqlite3 "$AUDIT_DB" \
  "SELECT event_type, event_id, timestamp, agent_id, outcome FROM audit_events WHERE event_id = '<captured event_id>';"
```

Assert (v0.1.0 scope):
- `event_type = "test.phase1_verification"`.
- Row reachable only after the write path's HMAC service-token check (RC-5).
- `audit.db` file mode is `0600` and table is append-only by schema design (no `UPDATE`/`DELETE` from `AuditBus`).

Deferred to v0.2.0 (see SECURITY.md §17.6):
- Per-row Ed25519 signature presence + validity.
- `prev_row_hash` chain integrity check.

### Step 4 — Verify latency

Per PRD §10 KPIs, the p99 audit-emission latency target is ≤100ms. For a single synthetic call this is observable from the time between dispatch and `event_id` return.

## Pass criteria (v0.1.0)

**Without governance-plugin installed**: `scripts/verify-audit-emission.sh` exits 77 (SKIP). That alone satisfies this test — Steps 2-4 do not apply.

**With governance-plugin installed**:
- Mechanical pre-checks pass (exit 0, or advisory exit 3, from `scripts/verify-audit-emission.sh`).
- The synthetic `kernel.audit_emit` call returns a valid `event_id` and the row is present in `audit.db`.
- File-mode + append-only schema controls verified.
- Round-trip latency is within target.

## Failure modes

- `KER-AE-001 audit.db unreachable` — confirm governance-plugin install (if you intend to use it) and that its SessionStart hook ran. If you do not intend to use governance-plugin, this is not applicable — expect SKIP (77) instead.
- `KER-AE-003 audit_hmac_token_missing` — governance-plugin HMAC service token not configured (Phase 3 work; v0.1.0 may not exercise this path).
- File mode != 0600 — `chmod 600` the resolved `audit.db` path and re-run.

## Example output

With governance-plugin installed and correctly configured, Step 1 produces
output shaped like this (path and row count will differ per install):

```
verify-audit-emission.sh — checking governance audit trail
  AUDIT_DB = <resolved-path>/governance-plugin/state/audit.db
  audit.db row count (table=audit_events): <N>
PASS: audit.db present, mode 0600, readable.
```

Without governance-plugin installed, Step 1 instead produces:

```
verify-audit-emission.sh — checking governance audit trail
  AUDIT_DB = <resolved-path>/governance-plugin/state/audit.db

SKIP (77): no governance audit database at the resolved path.
...
```

Treat the SKIP output as a PASS for this test.

Step 2 (live `kernel.audit_emit`) requires the plugin to be loaded into an active Claude Code session and governance-plugin to be installed.
