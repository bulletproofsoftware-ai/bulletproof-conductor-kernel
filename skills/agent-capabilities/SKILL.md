---
name: conductor-agent-capabilities
description: |
  Agent routing and capability matrix for conductor orchestration. Use when validating agent assignments, routing tasks to the correct agent, or checking what an agent can and cannot do.
---

# Agent Capabilities

## Routing Decision Table

When assigning a task to an agent, verify the task type matches the agent's `accepts` list and all `requires` are available.

### Bundled Agents (conductor- prefixed)

| Agent | Accepts | Produces | Requires |
|-------|---------|----------|----------|
| **conductor-project-setup** | Project init, harness setup | feature_list.json, claude_progress.txt, CLAUDE.md, BRD-tracker.json, git repo | - |
| **conductor-research** | Project description, domain research, requirements | BRD document, requirements, user stories, acceptance criteria | - |
| **conductor-ciso** | BRD security review, code review, threat model, compliance | Security requirements, threat model, STRIDE, OWASP coverage, vuln list | BRD document |
| **conductor-architect** | BRD requirements, design request, spec review | Specs, page inventory, link matrix, component list, diagrams | BRD-tracker.json, BRD document |
| **conductor-qa** | Test planning, code testing, gap analysis | Test plan, test files, results, coverage report, gap analysis | TODO spec files |
| **conductor-builder** | Spec, bug fix, feature request, implementation, planning | Code, tests, docs, updated BRD-tracker, plans, confidence scores | TODO spec, BRD-tracker.json |
| **conductor-critic** | Checkpoint validation, gap analysis, completeness check | Validation report, gap analysis, blocking decision, remediation items | Checkpoint artifacts, BRD-tracker.json |
| **conductor-code-reviewer** | Code review, security review, quality review | Review report, issue list, recommendations | Implementation files |
| **conductor-completeness-validator** | Completeness validation, artifact verification, health check | Completeness report, verdict, domain findings | - |
| **conductor-doc-gen** | Documentation request, README, architecture docs | README.md, ARCHITECTURE.md, SETUP.md, SBOM, CHANGELOG | Complete implementation |
| **conductor-checkpoint** | State checkpoint, recovery | Checkpoint record, state backup | conductor-state.json |
| **conductor-advisor** | Complex decisions, multi-perspective analysis | Advisory opinions, risk assessment | Decision context |

### External Agents (not prefixed, optional)

| Agent | Accepts | Produces |
|-------|---------|----------|
| **frontend-designer** | UI design, component design, design system | Design tokens, component specs, page mockups |
| **devops** | CI/CD, deployment, infrastructure | Pipelines, Dockerfile, K8s manifests, rollback |
| **performance** | Load testing, performance audit, profiling | K6 scripts, Lighthouse reports, bundle analysis |
| **database** | Schema design, migrations, query optimization | Migrations, rollback scripts, index recommendations |
| **api-design** | API design, OpenAPI creation, contract tests | OpenAPI spec, GraphQL schema, mock server |
| **api-docs** | API documentation | openapi.yaml, Swagger UI, endpoint reference |
| **compliance** | Compliance check, SBOM, audit prep | SBOM, license analysis, compliance report |
| **observability** | Monitoring, alerting, SLO definition | Prometheus config, Grafana dashboards, runbooks |
| **analyze-codebase** | Codebase analysis, brownfield analysis | Directory map, file inventory, architecture diagram |
| **bug-find** | Bug investigation, error analysis | Root cause analysis, fix recommendation |
| **refactor** | Refactoring, modernization, cleanup | Refactored code, migration guide |
| **pentest-coordinator** | Pentest scope, attack scenarios | Scope doc, attack plan, findings report |

## Key Constraints

- `conductor-project-setup`: Must be first agent in new project workflow
- `conductor-research`: BRD must have numbered requirements (REQ-XXX)
- `conductor-ciso`: Must review before implementation AND approve before release
- `conductor-architect`: Every BRD requirement must have todo_file; no placeholder content
- `conductor-qa`: Tests must cover 100% of BRD requirements
- `conductor-builder`: No stub implementations; mode selected by conductor
- `conductor-critic`: Must block on critical gaps; verify against BRD requirements

## Validation Rules

1. Source agent `produces` must match target agent `accepts`
2. All `requires` must be available before handoff
3. Agent can only produce what is in its `produces` list
4. Missing requirements block handoff initiation

For full capability definitions, see `references/capabilities.yaml`.
For routing decision logic, see `references/routing-rules.md`.
