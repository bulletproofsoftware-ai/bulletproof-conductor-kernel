/* ## ACTIVE CONSTRAINTS (envelope hash: <<ENVELOPE_HASH>>)
 *
 * <<CONSTRAINT_ENVELOPE_BLOCK>>
 *
 * (Envelope hash: <<ENVELOPE_HASH>>)
 *
 * --- Hermes E3 (REQ-CDV-HERMES-012/013/014/015) ---
 * This JavaScript program is injected into a `mcp__MCP_DOCKER__code-mode` tool
 * sandbox by `code-mode-dispatch.sh`. Conductor substitutes the named
 * placeholders (ENVELOPE_HASH, CONSTRAINT_ENVELOPE_BLOCK, TRAJECTORY_ID,
 * AGENT_NAME, PER_TASK_TOOL_CALLS, OUTPUT_SCHEMA_SHAPE) at dispatch time —
 * each is wrapped in double angle brackets in the source template, and the
 * dispatch script replaces every occurrence. The leading /* ... * / block is
 * detected by `conductor-kernel:critic` via the regex
 * /^\s*\/\*\s*## ACTIVE CONSTRAINTS .*?\*\//s (multiline DOTALL). A missing or
 * hash-mismatched envelope is a BLOCKING finding.
 *
 * Hard limits inherited from the envelope are not repeated here; the comment
 * block above is the source of truth for them.
 */

(async () => {
  const startTs = Date.now();
  const trajectoryId = "<<TRAJECTORY_ID>>";
  const agent = "<<AGENT_NAME>>";
  const envelopeHash = "<<ENVELOPE_HASH>>";

  // ---- Bracketing event #1 (REQ-CDV-HERMES-014, mandatory) ----
  // First action of the program. Records the constraint envelope hash so the
  // critic can match it against state.intent.envelope_hash at the next
  // checkpoint.
  await conductor_audit_emit({
    event_type: "code_mode_start",
    payload: {
      agent,
      trajectory_id: trajectoryId,
      constraint_envelope_hash: envelopeHash,
      ts: new Date().toISOString(),
    },
  });

  let output;
  try {
    // ---- Per-task tool calls (substituted by code-mode-dispatch.sh) ----
    // Each tool call is one `await <mcp_server>__<tool_name>({...args});`
    // expression. The placeholder below is replaced with N lines of
    // `const step_<i> = await <tool>(...);` — collected into local variables
    // and then assembled into the `output` object below. Example pre-render:
    //   const siemHits = await siem__query({ q: "alert_id:1234" });
    //   const edrEvents = await edr__lookup({ host: "203.0.113.5" });
<<PER_TASK_TOOL_CALLS>>

    // ---- Output assembly (substituted by code-mode-dispatch.sh) ----
    // The placeholder below is replaced with `key: null,` lines (one per
    // top-level property in the output schema). Conductor's caller fills in
    // the actual values before returning.
    output = {
<<OUTPUT_SCHEMA_SHAPE>>
    };

    // ---- Bracketing event #2 — success path ----
    await conductor_audit_emit({
      event_type: "code_mode_complete",
      payload: {
        agent,
        exit_code: 0,
        duration_ms: Date.now() - startTs,
        output_size_bytes: JSON.stringify(output).length,
        ts: new Date().toISOString(),
      },
    });

    return output;
  } catch (err) {
    // ---- Bracketing event #2 — failure path ----
    // The complete event is REQUIRED even on error so the critic does not flag
    // the dispatch as missing bracketing. The exit_code communicates failure.
    await conductor_audit_emit({
      event_type: "code_mode_complete",
      payload: {
        agent,
        exit_code: 1,
        duration_ms: Date.now() - startTs,
        error: String(err),
        ts: new Date().toISOString(),
      },
    });
    throw err;
  }
})();
