# Phase Workflows — Detailed Reference

## Phase Injection on Tier Promotion

When mid-workflow tier reclassification promotes a workflow to a higher tier, inject phases that the original tier didn't include. Injected phases are marked with `injected: true` and inserted at the correct position — completed phases are never replayed.

### Promotion: TRIVIAL → MINOR
Adds: CISO advisory review, conductor-critic advisory gates

### Promotion: TRIVIAL → STANDARD
Adds: CISO advisory review, conductor-critic mixed gates, adversarial review, pentest coordination, supply chain security, completeness validation (blocking)

### Promotion: MINOR → STANDARD
Adds:
- CISO architecture review (Phase 3, step 12b)
- Multi-model adversarial review (Phase 3, step 13b)
- Pentest coordination (Phase 5.6)
- Supply chain security (Phase 5.7)
- Completeness validation (blocking mode)
- PRE-RELEASE critic gate upgraded from skip to BLOCKING

### Promotion: MINOR → MAJOR
Adds: All STANDARD additions plus all critic gates upgraded to BLOCKING

### Promotion: STANDARD → MAJOR
Adds: All critic gates upgraded from advisory/mixed to BLOCKING (POST-BRD, POST-ARCH, POST-CISO, POST-QA, POST-IMPL)

---

## Phase 0: Project Initialization (New Projects Only)

1. Check for harness files: `feature_list.json`, `claude_progress.txt`, `CLAUDE.md`, `BRD-tracker.json`, `TODO/`, `COMPLETE/`
2. If ANY missing → Launch `conductor-project-setup` to:
   - Create complete directory structure
   - Initialize git repository with GitHub remote
   - Create harness artifacts
   - Establish security baseline (SECURITY.md, .env.example, pre-commit hooks)
   - Scaffold CI/CD with GitHub Actions
   - Create testing infrastructure
3. If all exist → Proceed to Phase 0.5

## Phase 0.5: Brownfield Analysis (Existing Codebases)

1. Launch `conductor-analyze-codebase` for:
   - Directory structure map
   - File inventory with descriptions
   - Architecture diagrams
   - Code quality and technical debt assessment
   - Integration points and dependencies
   - Existing patterns and conventions
   - Output: `CODEBASE-ANALYSIS.md`
2. Brownfield checkpoint verification
3. If modifying existing features → `conductor-builder` plan-only mode
4. Skip to Phase 1

## Phase 1: Requirements Gathering & BRD Extraction

### Step 1: Requirements Research
- Launch `conductor-research` agent
- Output: Comprehensive BRD document

### Step 2: CISO Review
- Launch `conductor-ciso` to review BRD for security implications
- Update BRD with security requirements
- Add security acceptance criteria

### Step 3: CRITIC CHECKPOINT: POST-CISO
- Launch `conductor-critic` to validate:
  - All STRIDE threat categories addressed
  - OWASP Top 10 coverage
  - Security requirements specific and testable
  - Compliance requirements mapped to controls

### Step 4: BRD EXTRACTION (MANDATORY BLOCKING GATE)
- Parse entire BRD line by line
- Extract every requirement into BRD-tracker.json:
  - Functional requirements (REQ-XXX)
  - Integration requirements (INT-XXX)
  - Security requirements
  - Performance requirements
  - UI/UX requirements
- Verify: every numbered item, tool/service, "must/shall/will/should" captured
- Set `verification_gates.extraction_complete = true`

### Step 5: CRITIC CHECKPOINT: POST-BRD-EXTRACTION
- Cross-reference every BRD requirement against BRD-tracker.json
- Verify no requirements missed or incorrectly captured

## Phase 2: Architecture & Specification

### Step 6: Architecture Planning
- Launch `conductor-architect` with BRD-tracker.json
- Create `/TODO/00-page-inventory.md`
- Create `/TODO/00-link-matrix.md`
- Create TODO spec for each requirement
- Each spec ≤50% context window

### Step 6a: Parallel Architecture Tasks
- API Design (`conductor-api-design`): OpenAPI 3.1 spec, mock server, contract tests
- Database Design (`conductor-database`): Schema, migrations, indexes

### Step 7: Spec Completeness Verification (BLOCKING)
- Page inventory lists all pages
- Link matrix lists all links
- Every page has spec file
- 100% BRD requirements have todo_file
- Set `verification_gates.specs_complete = true`

### Step 8: CRITIC CHECKPOINT: POST-ARCHITECT
- Verify 100% BRD-to-spec mapping
- No orphan links, no placeholder content

### Step 9: Test Planning
- Launch `conductor-qa` to create executable tests
- Tests for each BRD requirement
- Link testing spec (Playwright)

### Step 10: CRITIC CHECKPOINT: POST-QA
- 100% BRD requirement coverage in tests
- Integration tests for all INT-XXX items

## Phase 2.5: Visual Design (UI-heavy projects)

1. Design system creation (design tokens, component specs)
2. Page design (mockups, states, responsive, accessibility)
3. Design quality gate (no generic AI aesthetics, WCAG AA)

## Phase 3: Implementation Loop

### Step 10a: Implementation Planning (STANDARD/MAJOR)
- `conductor-builder` plan-only mode for complex specs
- Confidence scores for each step

### Step 11: Code Generation
- `conductor-builder` implement-only (or plan-and-implement for trivial/minor)
- Process each TODO spec sequentially
- Update BRD-tracker status

### Step 12: Integration Verification
- Each integration actually connects
- Proper error handling
- Configuration options
- Tests verify actual functionality

### Step 12b: CISO Security Review (MANDATORY BLOCKING)
- All generated code scanned
- OWASP Top 10 2025, SANS CWE Top 25
- SAST, secret detection, dependency scan
- CISO verdict: APPROVED / REJECTED / CONDITIONAL

### Step 13: Quality Gate
- `conductor-code-reviewer` reviews code
- `conductor-qa` executes tests
- Visual regression (BackstopJS) for UI projects
- Accessibility (Pa11y) for UI projects

### Step 13a: Parallel Quality Gates
- `conductor-performance` agent: Load tests, Lighthouse, bundle size
- `conductor-compliance` agent: SBOM, license scan, policy-as-code

### Step 14: CRITIC CHECKPOINT: POST-IMPLEMENTATION
- 100% BRD requirements "implemented" or "tested"
- No placeholder implementations
- All integrations execute (not stubbed)

### Step 15: Issue Resolution
- Write issues as TODO files
- Route visual issues to conductor-frontend-designer
- Loop back to step 11

## Phase 3.5: Content Accuracy & Honesty Verification

- All factual claims verifiable
- Statistics have sources
- Legal content complete (Privacy Policy, Terms)
- No placeholder text, all links working

## Phase 4: Final BRD Verification (MANDATORY BLOCKING)

1. BRD-tracker audit: 100% "complete"
2. Integration audit: is_placeholder == false
3. Completeness metrics: 0 TODO remaining
4. Gap analysis via `conductor-qa`
5. All verification_gates true
6. CRITIC CHECKPOINT: PRE-RELEASE (comprehensive final review)

## Phase 5: Documentation

- `conductor-doc-gen` for project documentation
- `conductor-api-docs` for API documentation

## Phase 5.5: Workflow Automation (Optional)

- `conductor-n8n` for workflow automations

## Phase 6: Deployment & Release (Optional)

- `conductor-devops`: CI/CD, Kubernetes, Docker, rollback
- Smoke tests on staging
- Production deployment with approval
- `conductor-observability`: Dashboards, alerting, SLO monitoring
- CRITIC CHECKPOINT: POST-DEPLOYMENT
