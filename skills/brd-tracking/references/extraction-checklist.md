# BRD Extraction Checklist

## Step-by-Step Procedure

### 1. Read the Entire BRD
- Read every line of the BRD document
- Do NOT skim or skip sections
- Note section names and line numbers as you go

### 2. Extract Functional Requirements
For every feature, capability, or user story:
- Create a `REQ-XXX` entry with sequential numbering
- Copy the exact description
- Record source section and line/quote
- Categorize as `functional`
- Set priority based on context (critical/high/medium/low)
- Set status to `extracted`

### 3. Extract Integration Requirements
For every tool, service, or API mentioned:
- Create an `INT-XXX` entry
- Record tool name and description
- Note what the integration must do
- Set `is_placeholder: false` (default)
- Set status to `extracted`

### 4. Extract Security Requirements
For every security control, compliance need, or access requirement:
- Create a `REQ-XXX` entry
- Categorize as `security`
- Include STRIDE/OWASP references if applicable

### 5. Extract Performance Requirements
For every SLA, throughput, latency, or uptime requirement:
- Create a `REQ-XXX` entry
- Categorize as `performance`
- Include specific numbers (e.g., "< 200ms response time")

### 6. Extract UI/UX Requirements
For every page, component, or interaction:
- Create a `REQ-XXX` entry
- Categorize as `ui`
- Note responsive/accessibility requirements

### 7. Keyword Scan
Scan the entire BRD for these keywords and verify each has a corresponding entry:
- "must", "shall", "will", "should"
- "integrate", "connect", "API", "webhook"
- "secure", "encrypt", "authenticate", "authorize"
- "page", "screen", "view", "component"
- "performance", "latency", "throughput", "SLA"

### 8. Verify Completeness
- Count all numbered items in BRD
- Count all REQ-XXX + INT-XXX entries
- Verify counts match (or explain gaps)
- Set `verification_gates.extraction_complete = true`

### 9. Dependency Mapping
For each requirement:
- Identify which other requirements it depends on
- Populate `dependencies` array
- Flag circular dependencies

### 10. Priority Assignment
Review all extracted requirements and verify priority:
- Critical: Blocks other work, must have for MVP
- High: Important for launch
- Medium: Nice to have
- Low: Can defer

## Verification Checklist

- [ ] Every numbered item in BRD has a REQ-XXX entry
- [ ] Every tool/service mentioned has an INT-XXX entry
- [ ] Every "must/shall/will/should" statement captured
- [ ] Every acceptance criterion captured
- [ ] Every section of the BRD has been read
- [ ] `total_requirements` matches actual count
- [ ] `verification_gates.extraction_complete = true`
- [ ] Dependencies mapped between requirements
- [ ] Priorities assigned to all requirements
