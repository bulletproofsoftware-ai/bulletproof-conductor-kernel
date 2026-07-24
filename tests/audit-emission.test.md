# Test — Audit Emission (Phase 1 Exit Gate (c))

**Implements**: kernel-api.md §13.3 — REQ-KER-018 `kernel.audit_emit`.

## Goal

Verify that `kernel.audit_emit` writes audit rows correctly to `governance-plugin/state/audit.db` with the expected file mode and integrity guarantees.

## Procedure

### Step 1 — Mechanical pre-checks (automated)

```bash
bash scripts/verify-audit-emission.sh
```

Expected: exit 0 (PASS) with the following confirmed:

- `audit.db` present at `~/Code/governance-plugin/state/audit.db` (or `$AUDIT_DB_OVERRIDE`).
- File mode is `0600` per RC-5.
- File is a regular file and readable by the current user.

If exit 3: file mode could not be determined (non-POSIX `stat`); treat as advisory PASS.

### Step 2 — Synthetic `kernel.audit_emit` round-trip (manual, inside Claude Code)

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

Read the row back from `audit.db`:

```bash
sqlite3 ~/Code/governance-plugin/state/audit.db \
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

- Mechanical pre-checks pass (exit 0 from `scripts/verify-audit-emission.sh`).
- The synthetic `kernel.audit_emit` call returns a valid `event_id` and the row is present in `audit.db`.
- File-mode + append-only schema controls verified.
- Round-trip latency is within target.

## Failure modes

- `KER-AE-001 audit.db unreachable` — confirm governance-plugin install and SessionStart hook ran.
- `KER-AE-003 audit_hmac_token_missing` — governance-plugin HMAC service token not configured (Phase 3 work; v0.1.0 may not exercise this path).
- File mode != 0600 — `chmod 600 audit.db` and re-run.

## Reproducible local result (2026-05-13)

The automated portion (Step 1) was last exercised on 2026-05-13 with these results:

```
verify-audit-emission.sh — checking governance audit trail
  AUDIT_DB = ~/Code/governance-plugin/state/audit.db
  audit.db row count (table=audit_events): 36600
PASS: audit.db present, mode 0600, readable.
```

Step 2 (live `kernel.audit_emit`) requires the plugin to be loaded into an active Claude Code session — see `RELEASE-CHECKLIST.md` item 12.
