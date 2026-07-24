# Verification Gates Reference

## Gate Types

### Blocking Gates
Stop workflow progression until passed. Used in MAJOR tier for all checkpoints, and in STANDARD tier for PRE-RELEASE and POST-PENTEST.

### Advisory Gates
Log findings but allow workflow to continue. Findings are accumulated in `conductor-state.json.verification_status.advisory_findings[]`.

### Skip Gates
Gate not executed at all. Used for TRIVIAL tier.

## Gate Mode Matrix (per Tier)

| Tier | POST-BRD | POST-ARCH | POST-CISO | POST-QA | POST-IMPL | PRE-RELEASE | POST-PENTEST | COMPLETENESS |
|----------|----------|-----------|-----------|---------|-----------|-------------|--------------|--------------|
| TRIVIAL | skip | skip | skip | skip | skip | skip | skip | skip |
| MINOR | advisory | advisory | advisory | skip | advisory | skip | skip | advisory |
| STANDARD | advisory | advisory | advisory | advisory | advisory | BLOCKING | BLOCKING | BLOCKING |
| MAJOR | BLOCKING | BLOCKING | BLOCKING | BLOCKING | BLOCKING | BLOCKING | BLOCKING | BLOCKING |

## Gate Definitions

### POST-CISO (Phase 1, Step 3)
**Validates:** Security review completeness
- All STRIDE threat categories addressed
- OWASP Top 10 coverage for web applications
- Security requirements are specific and testable
- Compliance requirements mapped to controls
- No critical security gaps remain

### POST-BRD-EXTRACTION (Phase 1, Step 5)
**Validates:** BRD extraction completeness
- Every BRD requirement has corresponding BRD-tracker.json entry
- All integrations identified
- No requirements missed or incorrectly captured

### POST-ARCHITECT (Phase 2, Step 8)
**Validates:** Architecture decomposition
- 100% BRD-to-spec mapping
- Every spec has correct BRD-REQ reference
- No orphan links (links to undefined pages)
- No placeholder content in any spec
- All integrations have detailed implementation specs

### POST-QA (Phase 2, Step 10)
**Validates:** Test planning completeness
- 100% BRD requirement coverage in test plan
- Each acceptance criterion has corresponding test case
- Integration tests for all INT-XXX items
- Security tests cover CISO requirements

### POST-IMPLEMENTATION (Phase 3, Step 14)
**Validates:** Implementation completeness
- 100% BRD requirements status "implemented" or "tested"
- No placeholder implementations (TODO comments, mock returns)
- All integrations actually execute (not stubbed)
- All tests pass with real data
- Security scans pass

### PRE-RELEASE (Phase 4, Step 6)
**Validates:** Release readiness (ALWAYS BLOCKING when activated)
- BRD completeness: 100% requirements complete
- Code quality: No TODO/FIXME/HACK comments
- Security: Final scans pass, auth on all protected routes
- Integrations: Live connections tested
- UI/UX: Visual regression, accessibility, responsive
- Content: No placeholder text, all links work, legal content present
- Generates comprehensive Release Readiness Report

### POST-PENTEST (Phase 4)
**Validates:** Penetration test findings resolved (ALWAYS BLOCKING when activated)
- All critical/high findings remediated
- Remediation verified by re-test

### POST-DEPLOYMENT (Phase 6, Step 22)
**Validates:** Deployment success
- Service healthy in production
- No error rate spike
- Response times within SLO
- Monitoring capturing metrics

### COMPLETENESS (Phase 7)
**Validates:** Exhaustive artifact completeness — the "does it actually work" gate
- Every dependency resolves (no missing imports)
- No dead code or orphan files
- All env vars defined
- All internal links resolve, external links reachable
- All referenced images/assets exist
- Build succeeds with zero errors
- Full test suite passes
- Every route returns valid response (not 500)
- Every API endpoint responds correctly
- UI pages load without console errors (if applicable)
- Container health checks pass (if applicable)
- Produces `completeness-report-<timestamp>.json`

## CISO Review Types

| Review Type | Trigger | Validates |
|-------------|---------|-----------|
| `requirements` | After research, before BRD | Security requirements, threat model, STRIDE |
| `code-review` | After auto-code | OWASP Top 10, SANS CWE 25, secrets, vulnerabilities |
| `doc-review` | After doc-gen | No sensitive data, security accuracy, compliance docs |

## Conductor Inline Discipline Checkpoints

These are NOT critic gates — they are inline checks the conductor performs at every transition:

| Checkpoint | Trigger | Validates |
|------------|---------|-----------|
| SEQUENCE | Every gate | current_step == expected_step |
| DRIFT | Every gate | Agent on assigned task |
| SCOPE | Every gate | No tasks outside BRD-tracker |
| LOOP | Every gate | remediation_loops < 3 |
| SCHEDULE | Every gate | Forward progress being made |
