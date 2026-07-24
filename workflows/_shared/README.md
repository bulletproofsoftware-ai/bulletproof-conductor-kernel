# Shared n8n Workflows (`workflows/_shared/`)

Per REQ-XCT-009, this directory holds the **generic shared subset** of n8n workflow templates that move out of `claude-memory-mcp/workflows/` and into the kernel.

## v0.1.0 status

**Empty.** The triage decision per extraction-plan.md §1.7 is that only the *generic shared* subset moves to the kernel; the 30+ memory-maintenance workflows stay in `claude-memory-mcp/workflows/`. Phase 6 (n8n workflow library) populates this directory with the workflows that domain plugins consume cross-cutting.

## Convention

When workflows ship here, follow the per-file convention:

```
<workflow-name>.json          # n8n workflow export
<workflow-name>.README.md     # purpose, required credentials, audit emissions
```

Workflows MUST use the `n8n-audit-emitter` Code-node template (`templates/n8n-audit-emitter.json`) for any audit emission, per REQ-XCT-002.

## Phase mapping

- Phase 1 (this release): empty directory + README.
- Phase 3: stream-mode primitives implementation → first shared workflows land here.
- Phase 6: full n8n workflow library populates `workflows/_shared/` and per-domain `workflows/` paths in consuming plugins.
