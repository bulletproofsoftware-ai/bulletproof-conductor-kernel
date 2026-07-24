---
name: process-knowledge
description: >
  Structured process knowledge base storing business rules, decision trees, SOPs, and edge
  case catalogs for agent consumption at decision points. Organized by domain with versioning,
  provenance, and semantic search. Agents query this at decision points to get domain-specific
  rules rather than relying on model training data.
---

# Process Knowledge Base Skill

Provides structured, queryable domain knowledge for agents operating within specific business domains. Four knowledge types organized by domain with full provenance tracking.

## When To Use

- When an agent needs domain-specific rules at a decision point
- When building systems in insurance, security, infrastructure, or compliance domains
- When codifying operational procedures (SOPs) for repeatable execution
- When checking for known edge cases before implementing business logic
- When adding new domain knowledge from operator corrections

## Knowledge Types

| Type | Purpose | Example |
|------|---------|---------|
| **Rules** | Deterministic conditions with defined outcomes | "Dual approval above $5M TIV" |
| **Decision Trees** | Multi-step branching logic | "Cat event claim routing" |
| **SOPs** | Ordered step sequences with verification | "Deploy to h2 procedure" |
| **Edge Cases** | Known exceptions and special handling | "Aggregate deductible calculation" |

## Reference Files

| File | Purpose |
|------|---------|
| `references/knowledge-schema.yaml` | Structure definitions for all 4 knowledge types |
| `references/domains/insurance.yaml` | Insurance domain rules, trees, SOPs, edge cases |
| `references/domains/security.yaml` | Security domain knowledge |
| `references/domains/infrastructure.yaml` | Infrastructure operations knowledge |
| `references/domains/development.yaml` | Development standards and conventions |
| `references/domains/governance.yaml` | Governance and compliance knowledge |
| `references/domains/operations.yaml` | Operations and automation knowledge |

## Query Interface

This skill provides knowledge through two interfaces — the v1 YAML-direct interface (current, fully functional) and the v2 MCP semantic interface (roadmapped).

### v1: YAML-Direct (current, fully functional)

Agents query domain knowledge by reading the YAML files in `references/domains/` directly via the `Read` tool, then filtering in-memory by domain, status, and applicability conditions. This is the **authoritative query interface today**. Every rule, SOP, and edge case is queryable, version-controlled, and provenance-traceable. No external dependencies.

**Pattern for agents:**
1. Read `references/domains/{domain}.yaml` via Read tool
2. Parse the YAML
3. Filter rules where status==active AND condition matches input context
4. Filter SOPs where domain.procedure matches the requested procedure name
5. Filter edge_cases where scenario_keywords intersect with input keywords
6. Return matching entries with their provenance metadata

The agent is responsible for evaluating `condition` expressions; YAML conditions use a simple subset (numeric comparisons, AND/OR, regex match).

### v2: Qdrant Semantic (active)

Agents query domain knowledge via `memory_recall` with `project="process_knowledge"`. Returns semantically relevant rules, SOPs, and edge cases ranked by relevance.

**Qdrant collection**: `process_knowledge` (separate from session memory)
**Sync**: on-demand via `scripts/ingest-process-knowledge.sh` or daily via n8n workflow
**Ingestion**: `scripts/ingest-process-knowledge.sh [--dry-run]` parses domain YAMLs, extracts individual entries, stores each as a Qdrant point with domain/type/status/tags metadata

**Pattern for agents (v2 — preferred when Qdrant is available):**
1. Construct a natural language query describing the decision context
2. Call `memory_recall` with `project="process_knowledge"` and the query
3. If relevant rules/SOPs are returned, apply them to the decision
4. If no relevant knowledge found, fall back to v1 YAML-direct or proceed without

**Which agents query process knowledge:**

| Agent | Query Trigger |
|-------|--------------|
| `conductor-architect` | Before architecture decisions |
| `conductor-builder` | Before implementation decisions involving business logic |
| `conductor-ciso` | Before security assessments (security domain) |
| `conductor-compliance` | Before compliance checks (governance domain) |
| `conductor-devops` | Before infrastructure decisions (infrastructure domain) |
| `conductor-database` | Before schema design (development domain) |

Agents that do NOT query: `conductor-critic` (validates, doesn't decide), `conductor-gemini-validator` (independent — must not be influenced), `conductor-doc-gen` (documents decisions, doesn't make them).

**Knowledge feedback loop**: When an operator corrects an agent's decision and the correction represents a domain rule, conductor stores the new rule via `memory_store` to the `process_knowledge` collection with `source: "operator_correction"`, `status: "active"`. The rule is also added to the appropriate domain YAML for version control. Next sync propagates the addition.

### MCP Tools (roadmap — not yet registered)

The PRD specifies a future MCP server interface for typed queries:

| Tool | Function | Status |
|------|----------|--------|
| `process_query` | Semantic search across knowledge with domain/type filters; returns matches with provenance | NOT YET IMPLEMENTED |
| `process_lookup` | Exact retrieval by ID or path; returns full metadata + version history | NOT YET IMPLEMENTED |
| `process_validate` | Check proposed actions against applicable rules; report violations + corrections | NOT YET IMPLEMENTED |

When MCP tools ship, they will provide a structured API over the existing Qdrant collection. The v2 `memory_recall` interface is fully functional today.

### Audit Trail (both interfaces)

Every knowledge query — v1 Read or v2 MCP — is logged to the governance audit bus with rule/SOP/edge_case ID, requesting agent, timestamp, and decision context. Audit emission is the agent's responsibility under v1 (use the audit_sink hook); under v2 it is automatic.

### Storage Backend

YAML files in `references/domains/` are the source of truth. They are version-controlled in this repo, code-reviewed, and auditable via git. The v2 Qdrant collection (when built) will be a query index, never the authority — knowledge can be rebuilt from YAML if Qdrant is lost.

## Key Rules

1. **YAML is source of truth** — Qdrant is the query layer, not the authority
2. **Provenance is mandatory** — every entry has source, verified_by, effective_date
3. **Auto-extracted rules are candidates** — human verification required before activation
4. **Rule consumption is audited** — agent use of rules logged to governance audit bus
5. **Versioned** — rule changes create new versions; old versions queryable by date
6. **Domain inheritance** — `insurance.claims` inherits from `insurance` (PLANNED — inheritance semantics not yet implemented in knowledge-schema.yaml)
