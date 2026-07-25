#!/usr/bin/env python3
"""
code-mode-audit-mcp.py — MCP server exposing `conductor_audit_emit` to code-mode JS sandboxes.

Hermes E3 (REQ-CDV-HERMES-014). This server is the EMITTER end of the audit pipeline
for events generated inside a `mcp__MCP_DOCKER__code-mode` JavaScript program. The JS
program calls `conductor_audit_emit({event_type, payload})` at code_mode_start and
code_mode_complete; this server appends those events to the governance audit.db
source-of-truth at:

    ~/.claude/plugins/cache/governance/governance/0.1.0/state/audit.db

Architecture (from spec §4):

    Component                                              Role          Direction
    ----------------------------------------------------- ------------- ---------------
    audit_emitter.py (canonical state-diff emitter)        WRITER        plugin → SIEM
    audit.db (sqlite source-of-truth)                      SOURCE        --
    conductor-audit-sink.py (SIEM exporter)                SINK          sqlite → Wazuh
    code-mode-audit-mcp.py (THIS FILE)                     EMITTER       JS → sqlite

This server is in the same architectural role as audit_emitter.py: it writes new
events. It is NOT the SIEM sink.

CISO-002 remediation (2026-05-19 — FAIL-CLOSED):
    Only two implementation paths are permitted:
      (a) import the canonical audit_emitter helper and call it directly
      (b) shell out to a subprocess that calls audit_emitter.py
    If BOTH (a) and (b) fail, raise McpToolError("audit_emit_unavailable") to the
    JS caller AND emit a `audit_emit_failure` sentinel to stderr (conductor session
    log). DO NOT write directly to audit.db with a sqlite client. Direct-write would
    let a sandbox JS forge audit events without going through the canonical authorization/
    signing path — that is the bypass risk CISO-002 prohibits.

Operator setup (one-time): register this server in MCP config. See
`_proposed-code-mode-audit-mcp-config.json` next to this file for the snippet.

Tool surface (exactly one tool):
    conductor_audit_emit(event_type: str, payload: dict) -> dict
        Returns {ok: True, event_id: <uuid>, ts: <ISO8601>} on success.
        Raises McpToolError("audit_emit_unavailable") on dual-fallback failure.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

# ---------- Constants ----------

# Canonical emitter location (Option b subprocess target).
#
# The emitter is provided by a sibling plugin, whose location this server does
# NOT assume. Operators point at it explicitly:
#
#     export CONDUCTOR_AUDIT_EMITTER=/path/to/hooks/scripts/lib/audit_emitter.py
#
# When unset, the subprocess fallback is simply unavailable and emission relies
# on the in-process import path (Option a). If neither is available the tool
# fails closed per CISO-002 rather than writing to the database directly.
def _canonical_emitter_path() -> Path | None:
    raw = os.environ.get("CONDUCTOR_AUDIT_EMITTER", "").strip()
    if not raw:
        return None
    return Path(os.path.expanduser(raw))


CANONICAL_EMITTER_PATH = _canonical_emitter_path()

# Governance source-of-truth (referenced only in error messages — this server
# MUST NOT open this file directly per CISO-002).
def _governance_audit_db() -> Path:
    override = os.environ.get("AUDIT_DB_OVERRIDE", "").strip()
    if override:
        return Path(os.path.expanduser(override))
    plugin_root = os.environ.get("GOVERNANCE_PLUGIN_ROOT", "").strip()
    if plugin_root:
        return Path(os.path.expanduser(plugin_root)) / "state" / "audit.db"
    state_home = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return Path(state_home) / "governance-plugin" / "state" / "audit.db"


GOVERNANCE_AUDIT_DB = _governance_audit_db()

# Identifier recorded as agent_id when conductor_audit_emit is invoked without
# a more specific agent in the payload.
DEFAULT_AGENT_ID = "code-mode-runner"

# Subprocess timeout (seconds) — keeps a hung emitter from holding the JS sandbox.
SUBPROCESS_TIMEOUT_SEC = 5


# ---------- MCP server bootstrap ----------

try:
    from mcp.server.fastmcp import FastMCP
    from mcp.server.fastmcp.exceptions import ToolError as McpToolError
except ImportError as exc:  # pragma: no cover - environment guard
    print(
        f"[code-mode-audit-mcp] FATAL: mcp package not importable: {exc}",
        file=sys.stderr,
    )
    sys.exit(1)


mcp = FastMCP("code-mode-audit")


# ---------- Emission paths (CISO-002: exactly two, no more) ----------


def _emit_via_import(event_type: str, payload: dict, agent_id: str) -> dict:
    """Path (a): import the canonical emitter helper and call it directly.

    Raises any exception on failure — caller catches and tries Path (b).
    """
    # Import is lazy so the MCP server can still start if the emitter module
    # is missing; the failure surfaces only when a JS sandbox actually calls
    # conductor_audit_emit. That keeps cold-start time low and lets fallback
    # path (b) work even if the importable interface drifts.
    if CANONICAL_EMITTER_PATH is None:
        raise FileNotFoundError(
            "CONDUCTOR_AUDIT_EMITTER is not set, so the canonical audit "
            "emitter cannot be located. Set it to the path of "
            "audit_emitter.py provided by your governance plugin."
        )

    sys.path.insert(0, str(CANONICAL_EMITTER_PATH.parent))
    try:
        import audit_emitter  # type: ignore[import-not-found]
    finally:
        # Restore sys.path to avoid leaking the import path to other tools.
        if str(CANONICAL_EMITTER_PATH.parent) in sys.path:
            sys.path.remove(str(CANONICAL_EMITTER_PATH.parent))

    # The canonical audit_emitter exposes `emit_event(record, sink_config)` for
    # SIEM export, NOT a direct sqlite append. The fail-closed contract here is
    # to surface the absence of a callable named `emit_event_to_audit_db` (the
    # name we expect the canonical emitter to add when this fallback path lands).
    # If the canonical emitter does not yet expose it, this path fails and we
    # try the subprocess fallback.
    if not hasattr(audit_emitter, "emit_event_to_audit_db"):
        raise AttributeError(
            "audit_emitter.emit_event_to_audit_db not exposed — import path "
            "unavailable; falling back to subprocess."
        )

    event_id = str(uuid.uuid4())
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    audit_emitter.emit_event_to_audit_db(
        event_id=event_id,
        timestamp=ts,
        event_type=event_type,
        agent_id=agent_id,
        detail=json.dumps(payload),
    )

    return {"ok": True, "event_id": event_id, "ts": ts, "path": "import"}


def _event_row_exists(event_id: str) -> bool:
    """Return True only if event_id is present in the audit chain.

    Read-only: this opens audit.db in immutable mode purely to confirm a write
    landed. It never inserts — direct writes to audit.db are forbidden by the
    contract documented at the top of this file.

    Fails closed. A missing database, a missing table, or any sqlite error
    returns False, so the caller raises rather than reporting a successful
    audit write it cannot substantiate.
    """
    db = GOVERNANCE_AUDIT_DB
    if not db.is_file():
        return False
    try:
        # immutable=1 guarantees we cannot mutate the chain while checking it.
        con = sqlite3.connect(f"file:{db}?immutable=1", uri=True, timeout=5)
        try:
            row = con.execute(
                "SELECT 1 FROM audit_events WHERE event_id = ? LIMIT 1",
                (event_id,),
            ).fetchone()
            return row is not None
        finally:
            con.close()
    except sqlite3.Error:
        return False


def _emit_via_subprocess(event_type: str, payload: dict, agent_id: str) -> dict:
    """Path (b): shell out to the canonical emitter as a subprocess.

    Raises subprocess.CalledProcessError or TimeoutExpired on failure —
    caller catches and surfaces audit_emit_unavailable.
    """
    if CANONICAL_EMITTER_PATH is None:
        raise FileNotFoundError(
            "CONDUCTOR_AUDIT_EMITTER is not set, so the canonical audit "
            "emitter cannot be located. Set it to the path of "
            "audit_emitter.py provided by your governance plugin."
        )

    if not CANONICAL_EMITTER_PATH.is_file():
        raise FileNotFoundError(
            f"Canonical emitter missing at {CANONICAL_EMITTER_PATH}"
        )

    event_id = str(uuid.uuid4())
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # The canonical emitter's --emit-direct mode (also added under the fallback-
    # path contract) accepts a JSON envelope on stdin and writes one row to
    # audit.db, returning 0 on success. If the canonical emitter does not yet
    # expose --emit-direct, the subprocess will exit non-zero and the dual-
    # fallback failure path triggers.
    envelope = {
        "event_id": event_id,
        "timestamp": ts,
        "event_type": event_type,
        "agent_id": agent_id,
        "detail": payload,
    }

    completed = subprocess.run(
        [sys.executable, str(CANONICAL_EMITTER_PATH), "--emit-direct"],
        input=json.dumps(envelope).encode("utf-8"),
        capture_output=True,
        timeout=SUBPROCESS_TIMEOUT_SEC,
        check=True,
    )

    # Exit 0 is NOT sufficient proof that the event was recorded.
    #
    # The canonical emitter's __main__ takes a state path as argv[1]; when it
    # is handed an unrecognised flag it falls through to `sys.exit(0)`
    # ("emitter must not break anything"). So an emitter without --emit-direct
    # support exits 0, writes nothing, and this path used to return ok=True —
    # an audit trail silently dropping the very events it exists to record.
    #
    # Confirm the row is actually in audit.db before claiming success, and
    # fail closed (CISO-002) when it is not.
    if not _event_row_exists(event_id):
        raise RuntimeError(
            "Canonical emitter exited 0 but no audit row was written for "
            f"event_id={event_id}. The emitter at {CANONICAL_EMITTER_PATH} "
            "most likely does not implement --emit-direct (its __main__ "
            "expects a state path and exits 0 on unrecognised arguments). "
            f"stdout={completed.stdout[:200]!r} stderr={completed.stderr[:200]!r}"
        )

    return {"ok": True, "event_id": event_id, "ts": ts, "path": "subprocess"}


# ---------- MCP tool ----------


@mcp.tool()
async def conductor_audit_emit(event_type: str, payload: dict) -> dict:
    """Append a single audit event to the conductor governance audit.db.

    Two implementation paths only (CISO-002 fail-closed):
      (a) import audit_emitter and call audit_emitter.emit_event_to_audit_db()
      (b) shell out to `python3 audit_emitter.py --emit-direct` with the envelope on stdin
    If BOTH fail, raise McpToolError("audit_emit_unavailable") and write a
    sentinel record `audit_emit_failure` to stderr (conductor session log).

    Direct sqlite writes from this server are PROHIBITED — they would bypass
    the canonical emitter's authorization/signing path.

    Returns:
        {"ok": True, "event_id": "<uuid>", "ts": "<ISO8601>", "path": "import"|"subprocess"}

    Raises:
        McpToolError("audit_emit_unavailable") when both paths fail.
    """
    if not isinstance(event_type, str) or not event_type:
        raise McpToolError("event_type must be a non-empty string")
    if not isinstance(payload, dict):
        raise McpToolError("payload must be an object")

    # Allow the caller to override agent_id via payload.agent, falling back to
    # the conventional DEFAULT_AGENT_ID. This keeps the audit row's agent_id
    # column populated even when the JS template forgets to pass it.
    agent_id = str(payload.get("agent") or DEFAULT_AGENT_ID)

    # --- Path (a): import ---
    import_error: Exception | None = None
    try:
        return _emit_via_import(event_type, payload, agent_id)
    except Exception as exc:  # noqa: BLE001 — fail-closed requires catching all
        import_error = exc
        print(
            f"[code-mode-audit-mcp] import-path failed: {exc!r}",
            file=sys.stderr,
        )

    # --- Path (b): subprocess ---
    subprocess_error: Exception | None = None
    try:
        return _emit_via_subprocess(event_type, payload, agent_id)
    except Exception as exc:  # noqa: BLE001 — fail-closed requires catching all
        subprocess_error = exc
        print(
            f"[code-mode-audit-mcp] subprocess-path failed: {exc!r}",
            file=sys.stderr,
        )

    # --- Both paths failed: fail-closed. NO direct sqlite write. ---
    sentinel = {
        "sentinel": "audit_emit_failure",
        "event_type": event_type,
        "payload_preview": str(payload)[:200],
        "import_error": repr(import_error),
        "subprocess_error": repr(subprocess_error),
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "governance_db": str(GOVERNANCE_AUDIT_DB),
    }
    print(
        f"[code-mode-audit-mcp] AUDIT_EMIT_FAILURE {json.dumps(sentinel)}",
        file=sys.stderr,
    )
    raise McpToolError("audit_emit_unavailable")


# ---------- Entrypoint ----------


def main() -> None:
    """Run the MCP server over stdio (the standard MCP transport)."""
    mcp.run()


if __name__ == "__main__":
    main()
