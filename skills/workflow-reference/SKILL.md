---
name: conductor-workflow-reference
description: |
  Complete tier-specific workflow templates, phase sequences, and verification gate definitions for the conductor orchestrator. Use when determining phase sequences for a tier, looking up which agents run in which order, or checking gate modes.
---

# Conductor Workflow Reference

## Tier-Specific Workflow Templates

### TRIVIAL tier (score 1.0-1.5)

```
analyze-codebase → conductor-builder(plan-and-implement) → verify
```

Minimal workflow. No critic gates. Single agent handles planning and implementation.

### MINOR tier (score 1.6-2.3)

```
analyze-codebase → conductor-builder(plan) → conductor-builder(implement) → conductor-ciso(advisory) → conductor-critic(advisory) → verify → conductor-completeness-validator(advisory)
```

Split planning and implementation. Advisory-only reviews.

### STANDARD tier (score 2.4-3.2) — New project

```
conductor-project-setup → conductor-research → conductor-ciso(requirements) → CRITIC(post-ciso, advisory) → BRD-EXTRACTION → CRITIC(post-extraction, advisory) → [conductor-architect + api-design + database] → conductor-builder(plan, complex-specs) → CRITIC(post-architect, advisory) → conductor-qa → CRITIC(post-qa, advisory) → conductor-builder(implement) → conductor-ciso(code-review) → [conductor-code-reviewer + conductor-qa + performance + compliance] → CRITIC(post-implementation, advisory) → [bug-find if failures] → [refactor if debt] → [loop if issues] → FINAL-BRD-VERIFICATION → pentest-coordinator → CRITIC(post-pentest, BLOCKING) → CRITIC(pre-release, BLOCKING) → conductor-doc-gen → conductor-ciso(doc-review) → api-docs → [n8n if automation] → devops → observability → CRITIC(post-deployment) → conductor-completeness-validator(BLOCKING)
```

### MAJOR tier (score 3.3-4.0) — Full treatment

```
conductor-project-setup → conductor-research → conductor-ciso(requirements) → CRITIC(post-ciso, BLOCKING) → BRD-EXTRACTION → CRITIC(post-extraction, BLOCKING) → [conductor-architect + api-design + database] → conductor-builder(plan, complex-specs) → CRITIC(post-architect, BLOCKING) → conductor-qa → CRITIC(post-qa, BLOCKING) → frontend-designer(if UI) → conductor-builder(implement) → conductor-ciso(code-review) → [conductor-code-reviewer + conductor-qa + performance + compliance] → CRITIC(post-implementation, BLOCKING) → [bug-find if failures] → [refactor if debt] → [loop if issues] → FINAL-BRD-VERIFICATION → pentest-coordinator → CRITIC(post-pentest, BLOCKING) → CRITIC(pre-release, BLOCKING) → conductor-doc-gen → conductor-ciso(doc-review) → api-docs → [n8n if automation] → devops → observability → CRITIC(post-deployment) → conductor-completeness-validator(BLOCKING)
```

### Existing project workflow (brownfield — STANDARD+ tier)

```
analyze-codebase → conductor-builder(plan, change-scope) → conductor-research → conductor-ciso(requirements) → CRITIC(post-ciso) → BRD-EXTRACTION → CRITIC(post-extraction) → [conductor-architect + api-design + database] → CRITIC(post-architect) → conductor-qa → CRITIC(post-qa) → conductor-builder(implement) → conductor-ciso(code-review) → [conductor-code-reviewer + conductor-qa + performance] → CRITIC(post-implementation) → FINAL-BRD-VERIFICATION → CRITIC(pre-release) → conductor-doc-gen → api-docs → conductor-completeness-validator(BLOCKING)
```

### Quick fix/bug workflow (TRIVIAL/MINOR tier)

```
analyze-codebase → bug-find → conductor-builder(plan-and-implement) → conductor-ciso(code-review) → [conductor-code-reviewer + conductor-qa] → CRITIC(post-fix, advisory) → verify
```

### Refactoring workflow

```
analyze-codebase → conductor-builder(plan, refactor-plan) → refactor → conductor-ciso(code-review) → [conductor-code-reviewer + conductor-qa] → CRITIC(post-refactor, advisory) → verify
```

## Phase Summary

| Phase | Name | Key Activities |
|-------|------|----------------|
| 0 | Project Initialization | Harness files, git, directory structure |
| 0.5 | Brownfield Analysis | Existing codebase mapping |
| 1 | Requirements & BRD | Research, CISO review, BRD extraction |
| 2 | Architecture & Specs | Specs, API design, DB design, test planning |
| 2.5 | Visual Design | Design tokens, component specs (UI projects) |
| 3 | Implementation | Code generation, security review, quality gates |
| 3.5 | Content Verification | Accuracy, legal, honesty checks |
| 4 | Final BRD Verification | Gap analysis, pre-release review |
| 5 | Documentation | Project docs, API docs |
| 5.5 | Workflow Automation | n8n workflows (optional) |
| 6 | Deployment & Release | CI/CD, monitoring (optional) |
| 7 | Completeness Validation | Exhaustive artifact verification, completeness report |

For detailed phase descriptions, see `references/phase-workflows.md`.
For verification gate details, see `references/verification-gates.md`.
For forbidden patterns, see `references/anti-patterns.md`.
