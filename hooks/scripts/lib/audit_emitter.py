#!/usr/bin/env python3
"""
audit_emitter.py — Emit conductor audit events to external SIEM (Wazuh, Splunk, syslog).

Triggered by PostToolUse hook after a successful conductor-state.json write.
Compares the new state against the cached prior state, identifies new audit
events, filters by audit_sink.events_to_emit[], and emits each as JSON over
the configured transport.

Configuration lives in conductor-state.json:

    "audit_sink": {
        "enabled": true,
        "transport": "syslog-udp",     # syslog-udp | syslog-tcp | syslog-tls | http | file
        "syslog_target": "wazuh.example.com:514",   # host:port for syslog; URL for http; path for file
        "syslog_facility": "local0",   # optional, default local0
        "syslog_app_name": "conductor", # optional, default conductor
        "events_to_emit": [
            "phase_transition",
            "gate_pass",
            "gate_block",
            "gate_decision",
            "kill_switch",
            "escalation",
            "nhi_spawn",
            "nhi_terminate",
            "handoff",
            "gemini_validation",
            "prohibited_behavior",
            "recovery_attempt",
            "recovery_success",
            "recovery_exhausted",
            "cost_threshold",
            "compliance_overview_generated",
            "workflow_complete"
        ],
        "auth": {
            "hmac_secret_env": "CONDUCTOR_AUDIT_HMAC_SECRET"  # for http transport
        },
        "emit_count": 0,
        "last_error": null
    }

Fail-open: emitter errors NEVER block the state write. Failures are recorded
in audit_sink.last_error but execution continues.

Exit codes:
    0 = success (or fail-open after error)
    Always 0 — emitter must never break the hook.

Usage:
    python3 audit_emitter.py <state-file-path>

The cache directory ($STATE_DIR/.conductor-cache/) holds:
    - prior_state.json: snapshot of state at previous emit (for diff)
"""

import hashlib
import hmac
import json
import logging
import logging.handlers
import os
import socket
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

# ---------- Severity mapping ----------
SEVERITY_BY_EVENT = {
    "prohibited_behavior":  "critical",
    "kill_switch":          "critical",
    "escalation":           "error",
    "gate_block":           "error",
    "recovery_exhausted":   "error",
    "cost_threshold":       "warning",
    "gemini_validation_fail": "warning",
    "gate_decision":        "info",
    "gate_pass":            "info",
    "phase_transition":     "info",
    "nhi_spawn":            "info",
    "nhi_terminate":        "info",
    "handoff":              "info",
    "gemini_validation":    "info",
    "recovery_attempt":     "notice",
    "recovery_success":     "notice",
    "compliance_overview_generated": "notice",
    "workflow_complete":    "notice",
}

SYSLOG_SEVERITY = {
    "critical": logging.CRITICAL,
    "error":    logging.ERROR,
    "warning":  logging.WARNING,
    "notice":   25,            # syslog NOTICE between WARNING(30) and INFO(20)
    "info":     logging.INFO,
}


# ---------- Helpers ----------
def safe_load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def safe_get(d, *keys, default=None):
    for k in keys:
        if not isinstance(d, dict):
            return default
        d = d.get(k)
        if d is None:
            return default
    return d


def list_diff(prior, current):
    """Return items in current that are not in prior (by full equality)."""
    prior = prior or []
    current = current or []
    prior_set = {json.dumps(p, sort_keys=True) for p in prior}
    return [c for c in current if json.dumps(c, sort_keys=True) not in prior_set]


# ---------- Event detection ----------
def detect_events(prior, current):
    """Compare prior and current state, return list of new audit events."""
    events = []
    project = current.get("project_name", "unknown")

    # Phase transition
    prior_phase = safe_get(prior, "current_phase", "number")
    curr_phase = safe_get(current, "current_phase", "number")
    if prior_phase != curr_phase and curr_phase is not None:
        events.append({
            "event_type": "phase_transition",
            "payload": {
                "project": project,
                "from_phase": prior_phase,
                "to_phase": curr_phase,
                "phase_name": safe_get(current, "current_phase", "name"),
            }
        })

    # Verification gate transitions
    prior_vs = safe_get(prior, "verification_status", default={}) or {}
    curr_vs = safe_get(current, "verification_status", default={}) or {}
    if isinstance(prior_vs, dict) and isinstance(curr_vs, dict):
        for gate, new_status in curr_vs.items():
            if gate == "advisory_findings" or gate == "completeness_report_path":
                continue
            old_status = prior_vs.get(gate)
            if old_status != new_status and new_status is not None:
                if new_status == "pass":
                    events.append({
                        "event_type": "gate_pass",
                        "payload": {"project": project, "gate": gate, "status": new_status},
                    })
                elif new_status == "fail":
                    events.append({
                        "event_type": "gate_block",
                        "payload": {"project": project, "gate": gate, "status": new_status},
                    })
                events.append({
                    "event_type": "gate_decision",
                    "payload": {"project": project, "gate": gate, "from": old_status, "to": new_status},
                })

    # NHI lifecycle (new instances or status transitions)
    prior_nhi = {n.get("nhi_id"): n for n in (prior.get("agent_instances") or [])}
    curr_nhi = {n.get("nhi_id"): n for n in (current.get("agent_instances") or [])}
    for nhi_id, n in curr_nhi.items():
        if nhi_id not in prior_nhi:
            events.append({
                "event_type": "nhi_spawn",
                "payload": {"project": project, "nhi_id": nhi_id, "agent": n.get("agent"),
                            "parent_nhi_id": n.get("parent_nhi_id")},
            })
        elif prior_nhi[nhi_id].get("status") != n.get("status") and n.get("status") in ("completed", "failed", "killed"):
            events.append({
                "event_type": "nhi_terminate",
                "payload": {"project": project, "nhi_id": nhi_id, "agent": n.get("agent"),
                            "status": n.get("status"),
                            "tools_used_count": len(n.get("tools_used") or [])},
            })
            if n.get("status") == "killed":
                events.append({
                    "event_type": "kill_switch",
                    "payload": {"project": project, "nhi_id": nhi_id, "agent": n.get("agent")},
                })

    # Handoffs
    new_handoffs = list_diff(prior.get("handoff_history"), current.get("handoff_history"))
    for h in new_handoffs:
        events.append({
            "event_type": "handoff",
            "payload": {"project": project,
                        "handoff_id": h.get("handoff_id"),
                        "source": h.get("source_agent"),
                        "target": h.get("target_agent"),
                        "status": h.get("status")},
        })

    # Gemini validations
    new_validations = list_diff(prior.get("gemini_validations"), current.get("gemini_validations"))
    for v in new_validations:
        verdict = v.get("verdict")
        events.append({
            "event_type": "gemini_validation_fail" if verdict in ("FAIL", "PARTIAL") else "gemini_validation",
            "payload": {"project": project,
                        "validation_id": v.get("validation_id"),
                        "agent_validated": v.get("agent_validated"),
                        "verdict": verdict,
                        "completion_pct": v.get("completion_pct"),
                        "issues_count": len(v.get("issues") or [])},
        })

    # Failed tasks (any new failed task is an escalation event)
    new_failures = list_diff(prior.get("failed_tasks"), current.get("failed_tasks"))
    for f in new_failures:
        events.append({
            "event_type": "escalation",
            "payload": {"project": project,
                        "step": f.get("step"),
                        "name": f.get("name"),
                        "agent": f.get("agent"),
                        "failure_type": f.get("failure_type"),
                        "retry_count": f.get("retry_count")},
        })

    # Cost threshold breach
    prior_exceeded = safe_get(prior, "cost_tracking", "budget_exceeded", default=False)
    curr_exceeded = safe_get(current, "cost_tracking", "budget_exceeded", default=False)
    if not prior_exceeded and curr_exceeded:
        events.append({
            "event_type": "cost_threshold",
            "payload": {"project": project,
                        "budget_limit_usd": safe_get(current, "cost_tracking", "budget_limit_usd"),
                        "estimated_cost_usd": safe_get(current, "cost_tracking", "estimated_cost_usd")},
        })

    # Recovery events
    new_recoveries = list_diff(safe_get(prior, "recovery", "recovery_history") or [],
                                safe_get(current, "recovery", "recovery_history") or [])
    for r in new_recoveries:
        et = r.get("event_type", "recovery_attempt").replace("recovery.", "recovery_")
        events.append({
            "event_type": et,
            "payload": {"project": project,
                        "step": r.get("step"),
                        "failure_category": r.get("failure_category"),
                        "strategy": r.get("strategy"),
                        "outcome": r.get("outcome")},
        })

    # Workflow completion
    prior_step_status = safe_get(prior, "current_step", "status")
    curr_step_status = safe_get(current, "current_step", "status")
    curr_phase_num = safe_get(current, "current_phase", "number")
    if (prior_step_status != "completed" and curr_step_status == "completed"
            and (curr_phase_num == 7 or curr_phase_num == "7")):
        events.append({
            "event_type": "workflow_complete",
            "payload": {"project": project,
                        "tier": current.get("tier"),
                        "completed_tasks": len(current.get("completed_tasks") or [])},
        })

    return events


# ---------- Emission transports ----------
def build_event_record(event, audit_session_id, source_host):
    """Wrap a detected event with envelope metadata for SIEM ingestion."""
    severity = SEVERITY_BY_EVENT.get(event["event_type"], "info")
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event_type": event["event_type"],
        "severity": severity,
        "source": "conductor-kernel",
        "source_host": source_host,
        "audit_session_id": audit_session_id,
        "schema_version": "1.0",
        "payload": event["payload"],
    }


def emit_syslog(record, sink_config):
    """Emit a single record via syslog (UDP/TCP/TLS)."""
    target = sink_config.get("syslog_target", "")
    if ":" in target:
        host, port_s = target.rsplit(":", 1)
        try:
            port = int(port_s)
        except ValueError:
            port = 514
    else:
        host, port = target, 514

    transport = sink_config.get("transport", "syslog-udp")
    facility_name = sink_config.get("syslog_facility", "local0")
    app_name = sink_config.get("syslog_app_name", "conductor")

    facility = getattr(logging.handlers.SysLogHandler, f"LOG_{facility_name.upper()}", logging.handlers.SysLogHandler.LOG_LOCAL0)
    severity = SYSLOG_SEVERITY.get(record["severity"], logging.INFO)

    if transport == "syslog-udp":
        sock_type = socket.SOCK_DGRAM
    else:
        sock_type = socket.SOCK_STREAM

    handler = logging.handlers.SysLogHandler(
        address=(host, port),
        facility=facility,
        socktype=sock_type,
    )
    if transport == "syslog-tls":
        # Wrap socket with TLS
        import ssl
        try:
            ctx = ssl.create_default_context()
            # create_default_context() still permits TLS 1.0/1.1 on some builds.
            # Both are deprecated (RFC 8996) and this socket carries audit
            # records (CodeQL py/insecure-protocol).
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.check_hostname = True
            ctx.verify_mode = ssl.CERT_REQUIRED
            handler.socket = ctx.wrap_socket(handler.socket, server_hostname=host)
        except (ssl.SSLError, OSError) as e:
            handler.close()
            raise RuntimeError(f"TLS wrap failed: {e}")

    logger = logging.getLogger("conductor.audit")
    logger.handlers.clear()
    logger.addHandler(handler)
    logger.setLevel(logging.DEBUG)

    # RFC 5424-ish: APP-NAME PROCID JSON-payload
    msg = f"{app_name} {os.getpid()} {json.dumps(record, separators=(',', ':'))}"
    logger.log(severity, msg)
    handler.close()


def emit_http(record, sink_config):
    """Emit via HTTP POST (e.g., Wazuh API, generic webhook)."""
    target = sink_config.get("syslog_target")
    if not target:
        raise ValueError("http transport requires syslog_target as URL")

    payload = json.dumps(record).encode("utf-8")
    headers = {"Content-Type": "application/json", "User-Agent": "conductor-audit/1.0"}

    # Optional HMAC signature
    auth_cfg = sink_config.get("auth") or {}
    secret_env = auth_cfg.get("hmac_secret_env")
    if secret_env:
        secret = os.environ.get(secret_env)
        if secret:
            sig = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()
            headers["X-Conductor-Signature"] = f"sha256={sig}"

    req = urllib.request.Request(target, data=payload, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=5) as resp:
        if resp.status >= 400:
            raise RuntimeError(f"HTTP {resp.status}: {resp.read()[:200]}")


def emit_file(record, sink_config):
    """Emit by appending JSON-line to a file (for Wazuh agent file monitor)."""
    target = sink_config.get("syslog_target")
    if not target:
        raise ValueError("file transport requires syslog_target as path")

    target = os.path.expanduser(target)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "a") as f:
        f.write(json.dumps(record) + "\n")


def emit_substrate(record, sink_config):
    """Emit by recording the event as a hash-chained row on the substrate-orchestrator audit chain.

    Shells out to the substrate's `conduct_audit` CLI (the conductor->substrate adapter), which appends
    one HMAC-anchored, hash-linked row to the immutable audit_events chain — the same chain
    audit.verify_chain() checks. This makes a conductor state-transition independently tamper-evident,
    not just recorded in the on-disk conductor-state.json.

    Config (audit_sink):
        "transport": "substrate",
        "substrate_python": "/path/to/.venv/bin/python",   # optional; defaults to the env's python3
        "substrate_cwd": "/path/to/substrate-orchestrator", # optional; cwd so the CLI finds .env

    The event_type/severity/payload come from the record this emitter already built; the conductor's
    audit_session_id rides as the chain's pipeline_run_id so all of a workflow's events are queryable by
    one id. Raises on a non-zero CLI exit so the caller records it in audit_sink.last_error (fail-open —
    a substrate that is down NEVER blocks the conductor state write)."""
    import shlex
    import subprocess

    python_bin = sink_config.get("substrate_python") or sys.executable or "python3"
    cwd = sink_config.get("substrate_cwd") or None

    payload = dict(record.get("payload") or {})
    # Fold the SIEM envelope's severity/source into the chained payload so the row is self-describing.
    payload.setdefault("severity", record.get("severity"))
    payload.setdefault("source", record.get("source"))

    cmd = [
        python_bin, "-m", "substrate_orchestrator.conduct_audit",
        "--event", record["event_type"],
        "--run-id", str(record.get("audit_session_id") or ""),
        "--stage-id", str(payload.get("phase_name") or payload.get("gate") or record["event_type"]),
        "--payload", json.dumps(payload),
        "--principal", "conductor",
    ]
    proc = subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, timeout=15,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"substrate conduct_audit exited {proc.returncode}: "
            f"{(proc.stderr or proc.stdout or '').strip()[:200]} (cmd: {shlex.join(cmd)})"
        )


def emit_event(record, sink_config):
    """Dispatch to the configured transport."""
    transport = sink_config.get("transport", "syslog-udp")
    if transport in ("syslog-udp", "syslog-tcp", "syslog-tls"):
        emit_syslog(record, sink_config)
    elif transport == "http":
        emit_http(record, sink_config)
    elif transport == "file":
        emit_file(record, sink_config)
    elif transport == "substrate":
        emit_substrate(record, sink_config)
    else:
        raise ValueError(f"unknown transport: {transport}")


# ---------- Cache management ----------
def cache_dir(state_path):
    return os.path.join(os.path.dirname(state_path), ".conductor-cache")


def load_prior_state(state_path):
    cache = cache_dir(state_path)
    p = os.path.join(cache, "prior_state.json")
    return safe_load_json(p) or {}


def save_prior_state(state_path, current):
    cache = cache_dir(state_path)
    os.makedirs(cache, mode=0o700, exist_ok=True)
    p = os.path.join(cache, "prior_state.json")
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(current, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


# ---------- State writeback ----------
def update_emit_count(state_path, count, last_error=None):
    """Atomically update emit_count and optionally last_error in the state file."""
    state = safe_load_json(state_path)
    if not state:
        return
    sink = state.setdefault("audit_sink", {})
    sink["emit_count"] = sink.get("emit_count", 0) + count
    if last_error:
        sink["last_error"] = {
            "message": str(last_error)[:200],
            "at": datetime.now(timezone.utc).isoformat(),
        }
    elif "last_error" in sink:
        # Clear on successful run
        sink["last_error"] = None
    tmp = state_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, state_path)


# ---------- Main ----------
def main():
    if len(sys.argv) != 2:
        # Silent — emitter must not break anything
        sys.exit(0)

    state_path = sys.argv[1]
    if not os.path.isfile(state_path):
        sys.exit(0)

    current = safe_load_json(state_path)
    if not current:
        sys.exit(0)

    sink = current.get("audit_sink") or {}
    if not sink.get("enabled"):
        # Silent — operator hasn't opted in
        sys.exit(0)

    # syslog/http/file transports route to `syslog_target`; the `substrate` transport records on the
    # local audit chain via the conduct_audit CLI and needs no target. Only require a target for the
    # target-bearing transports.
    if sink.get("transport") != "substrate" and not sink.get("syslog_target"):
        # Silent — incomplete config
        sys.exit(0)

    allowed = set(sink.get("events_to_emit") or [])
    if not allowed:
        # Operator opted in but selected zero events
        sys.exit(0)

    prior = load_prior_state(state_path)
    events = detect_events(prior, current)
    events = [e for e in events if e["event_type"] in allowed
              # Treat gemini_validation_fail as gemini_validation for filter purposes too
              or (e["event_type"] == "gemini_validation_fail" and "gemini_validation" in allowed)]

    if not events:
        save_prior_state(state_path, current)
        sys.exit(0)

    # Audit session ID lives in governance block; fall back to a stable hash of project_name
    audit_session_id = (safe_get(current, "governance", "audit_session_id")
                        or hashlib.sha256(
                            (current.get("project_name", "") + str(current.get("initiated_at", ""))).encode()
                        ).hexdigest()[:16])
    source_host = socket.gethostname()

    emitted = 0
    last_error = None
    for event in events:
        record = build_event_record(event, audit_session_id, source_host)
        try:
            emit_event(record, sink)
            emitted += 1
        except Exception as e:
            last_error = e
            # Continue trying remaining events; don't bail on first failure
            continue

    # Save prior state regardless — we don't want to re-emit on every retry
    try:
        save_prior_state(state_path, current)
    except Exception:
        pass

    # Update emit_count and last_error in state file
    try:
        update_emit_count(state_path, emitted, last_error)
    except Exception:
        pass

    # Always exit 0 — fail-open
    sys.exit(0)


if __name__ == "__main__":
    main()
