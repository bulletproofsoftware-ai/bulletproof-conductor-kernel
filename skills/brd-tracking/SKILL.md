---
name: conductor-brd-tracking
description: |
  BRD extraction methodology, tracker schema, and requirement lifecycle management. Use when extracting requirements from BRDs, managing BRD-tracker.json, or verifying requirement completion status.
---

# BRD Tracking

## BRD-tracker.json Purpose

Tracks EVERY requirement from the Business Requirements Document through its full lifecycle: extraction → specification → implementation → testing → completion.

## Requirement Lifecycle

```
extracted → spec_created → implementing → implemented → tested → complete
```

### Blocking Gates
- **Before Architecture**: 100% of requirements must be `extracted` with IDs
- **Before Implementation**: 100% must have `spec_created` with `todo_file` populated
- **Before Final Verification**: 100% must be `complete`
- **Project Complete**: 100% requirements `complete` AND 100% integrations `is_placeholder == false`

## Schema Quick Reference

```json
{
  "brd_source": "path/to/BRD.md",
  "extraction_date": "ISO-8601",
  "total_requirements": 0,
  "requirements": [
    {
      "id": "REQ-001",
      "description": "Full requirement description",
      "source_section": "Section name from BRD",
      "source_line": "Line number or quote",
      "category": "functional|security|integration|performance|ui",
      "priority": "critical|high|medium|low",
      "todo_file": "TODO/requirement-name.md",
      "status": "extracted|spec_created|implementing|implemented|tested|complete",
      "implementation_files": [],
      "test_files": [],
      "dependencies": ["REQ-XXX"],
      "notes": ""
    }
  ],
  "integrations": [
    {
      "id": "INT-001",
      "tool_name": "Tool/Service Name",
      "description": "Integration description",
      "source_section": "Section from BRD",
      "todo_file": "TODO/integration-name.md",
      "status": "extracted|spec_created|implementing|implemented|tested|complete",
      "implementation_files": [],
      "is_placeholder": false
    }
  ],
  "verification_gates": {
    "extraction_complete": false,
    "specs_complete": false,
    "implementation_complete": false,
    "testing_complete": false,
    "final_verification": false
  }
}
```

## Extraction Procedure

See `references/extraction-checklist.md` for the step-by-step procedure.

## Category Definitions

| Category | Examples |
|----------|----------|
| **functional** | Features, capabilities, user stories |
| **security** | Auth, encryption, access control, compliance |
| **integration** | Third-party APIs, services, tools |
| **performance** | SLAs, throughput, latency, uptime |
| **ui** | Pages, components, interactions, responsive behavior |
