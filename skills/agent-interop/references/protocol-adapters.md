# Protocol Adapters — REST, MCP Bridge, and A2A Specifications

## REST API Adapter

For scripts, bots (Telegram), and n8n workflows.

### Request Format

```http
POST /agents/conductor.ciso/invoke
Host: localhost:8102
X-API-Key: {api_key}
Content-Type: application/json

{
  "input": {
    "target": "/path/to/project",
    "scope": "full",
    "frameworks": ["NIST", "OWASP"]
  },
  "callback_url": "https://example.com/webhook/result",
  "context_envelope": { ... }
}
```

### Response (Accepted)

```json
{
  "job_id": "job_abc123",
  "agent_id": "conductor.ciso",
  "status": "pending",
  "estimated_duration_seconds": 180,
  "poll_url": "/agents/conductor.ciso/status/job_abc123",
  "result_url": "/agents/conductor.ciso/result/job_abc123"
}
```

### Status Polling

```http
GET /agents/conductor.ciso/status/job_abc123
```

```json
{
  "job_id": "job_abc123",
  "status": "working",
  "progress_pct": 45,
  "started_at": "2026-04-16T14:30:00Z"
}
```

### Result Retrieval

```json
{
  "job_id": "job_abc123",
  "status": "completed",
  "result": {
    "findings": [...],
    "risk_score": 6.5,
    "recommendations": [...]
  },
  "execution_mode": "conductor",
  "duration_seconds": 165,
  "completed_at": "2026-04-16T14:32:45Z"
}
```

---

## MCP Bridge Adapter

For other Claude Code instances (c2, remote sessions).

Each externally callable agent becomes an MCP tool:

```json
{
  "name": "conductor_ciso",
  "description": "Reviews code, infrastructure, and architecture for security vulnerabilities",
  "inputSchema": {
    "type": "object",
    "required": ["target"],
    "properties": {
      "target": { "type": "string" },
      "scope": { "type": "string", "enum": ["code", "infrastructure", "architecture", "full"] },
      "frameworks": { "type": "array", "items": { "type": "string" } }
    }
  }
}
```

MCP bridge translates:
- MCP tool call → REST POST /agents/{id}/invoke
- Polls for completion (hidden from caller)
- Returns MCP tool response when done

---

## A2A Protocol Adapter

Implements A2A Protocol v1.0 (April 2026). Optional features supported: task lifecycle, context transfer, capability discovery.

Implements Google's Agent-to-Agent protocol.

### Agent Card (Discovery)

```
GET /.well-known/agent-cards
```

```json
{
  "agents": [
    {
      "id": "conductor.ciso",
      "name": "CISO Security Reviewer",
      "description": "Reviews for security vulnerabilities and compliance",
      "capabilities": ["security_review", "compliance_assessment"],
      "input_schema": { ... },
      "output_schema": { ... },
      "protocol_version": "1.0",
      "auth_required": true,
      "avg_response_time_seconds": 180
    }
  ]
}
```

### Task Lifecycle

```
SUBMIT → PENDING → WORKING → COMPLETED | FAILED
```

1. External agent submits task via A2A message format
2. Gateway creates job, returns task ID
3. Agent executes, status updates available
4. Result returned as A2A artifact
5. Context envelope carries governance metadata throughout

### A2A Message Format

```json
{
  "jsonrpc": "2.0",
  "method": "tasks/send",
  "params": {
    "id": "task_xyz",
    "message": {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "text": "Review this codebase for NIST compliance"
        },
        {
          "type": "data",
          "data": { "target": "/path/to/project", "frameworks": ["NIST"] }
        }
      ]
    }
  }
}
```
