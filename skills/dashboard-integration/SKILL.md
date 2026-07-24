---
name: conductor-dashboard-integration
description: |
  Dashboard setup, SSE event types, and file-watching integration for the conductor dashboard. Use when connecting to the conductor dashboard, configuring real-time updates, or setting up the monitoring UI.
---

# Dashboard Integration

## Overview

The conductor dashboard is a companion Next.js application that provides real-time visibility into workflow orchestration. It watches `conductor-state.json` via filesystem events (chokidar) and displays:

- Current phase and step
- Task queue and completion progress
- Verification gate status
- Agent activity timeline
- BRD requirement tracking
- Error and remediation history

## Architecture

```
conductor-state.json ←→ chokidar watcher → SSE endpoint → Dashboard UI
```

The dashboard is **file-based** — no MCP coupling needed. It reads conductor-state.json from the project directory and pushes updates via Server-Sent Events.

## Integration Points

1. **File watching**: Dashboard watches `conductor-state.json` for changes
2. **SSE streaming**: Real-time updates pushed to browser
3. **Type contract**: Dashboard TypeScript types must match conductor-state.schema.json

## Setup

The dashboard is a separate project (not bundled with the plugin). To connect:

1. Install the conductor dashboard
2. Point it at your project directory
3. Dashboard auto-detects `conductor-state.json`

For detailed setup instructions, see `references/setup-guide.md`.
For SSE event types and payloads, see `references/sse-events.md`.
