# BRD-tracker.json Full Schema

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `brd_source` | string | Yes | Path to source BRD document |
| `extraction_date` | date-time | Yes | When extraction was performed |
| `total_requirements` | integer | Yes | Count of all REQ-XXX entries |
| `requirements` | array | Yes | All functional/security/UI/performance requirements |
| `integrations` | array | Yes | All third-party integrations |
| `verification_gates` | object | Yes | Gate pass/fail status |

## Requirement Object

```json
{
  "id": "REQ-001",
  "description": "User must be able to log in with email and password",
  "source_section": "3.1 Authentication",
  "source_line": "Line 45: 'The system shall provide email/password authentication'",
  "category": "functional",
  "priority": "critical",
  "todo_file": "TODO/user-authentication.md",
  "status": "spec_created",
  "implementation_files": ["src/auth/login.ts", "src/auth/session.ts"],
  "test_files": ["tests/auth/login.test.ts"],
  "dependencies": [],
  "notes": "Must support MFA in future phase"
}
```

### Status Values

| Status | Meaning | Who Sets It |
|--------|---------|-------------|
| `extracted` | Requirement identified from BRD | Conductor (during extraction) |
| `spec_created` | TODO spec file exists | Conductor (after architect) |
| `implementing` | Builder working on it | Builder agent |
| `implemented` | Code written, not yet tested | Builder agent |
| `tested` | Tests pass | QA agent |
| `complete` | Verified end-to-end | Conductor (after verification) |

### Category Values

| Category | Description |
|----------|-------------|
| `functional` | Core features and capabilities |
| `security` | Authentication, authorization, encryption, compliance |
| `integration` | Third-party service connections |
| `performance` | Speed, throughput, latency requirements |
| `ui` | Visual design, interaction, responsive behavior |

### Priority Values

| Priority | Description |
|----------|-------------|
| `critical` | Must have for MVP, blocks other requirements |
| `high` | Important for launch, strong user impact |
| `medium` | Nice to have for launch, moderate impact |
| `low` | Can defer, minimal impact |

## Integration Object

```json
{
  "id": "INT-001",
  "tool_name": "Stripe",
  "description": "Payment processing for subscription billing",
  "source_section": "4.2 Billing",
  "todo_file": "TODO/stripe-integration.md",
  "status": "implementing",
  "implementation_files": ["src/billing/stripe.ts"],
  "is_placeholder": false
}
```

**CRITICAL**: `is_placeholder` must be `false` for project completion. Any integration returning static/mock data must have `is_placeholder: true`.

## Verification Gates

```json
{
  "extraction_complete": true,
  "specs_complete": true,
  "implementation_complete": false,
  "testing_complete": false,
  "final_verification": false
}
```

Each gate is set to `true` only when the corresponding phase passes verification.
