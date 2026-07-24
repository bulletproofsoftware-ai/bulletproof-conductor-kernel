# Security Scan Report: bulletproof-conductor-kernel

**Scan ID:** `1bc3abeb-4cc0-4635-82ab-06674f4c3fd1`
**Date:** 2026-07-24T20:21:50.617Z
**Score:** 1000/1000 (excellent)
**Branch:** main | **Commit:** `N/A`
**Profile:** standard

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 4 |
| Low | 2 |
| Info | 14 |
| **Total (open)** | **20** |

> **Note:** The counts above reflect _open_ findings only.
> 1 scanner(s) were skipped — see "Skipped Scanners" below.

## Scanners Executed

| Scanner | Status | Findings | Duration | Notes |
|---------|--------|----------|----------|-------|
| trivy | pass | 1 | 3.1s |  |
| gitleaks | pass | 0 | 0.5s |  |
| opengrep | pass | 5 | 6.6s |  |
| checkov | pass | 0 | 3.6s |  |
| grype | pass | 0 | 3.5s |  |
| syft | pass | 1 | 1.5s |  |
| package-validator | skipped | 0 | 0.0s |  |
| oxlint | pass | 0 | 0.0s |  |
| ruff | pass | 2 | 0.0s |  |
| actionlint | pass | 0 | 0.0s |  |
| jscpd | pass | 0 | 0.0s |  |
| typos | pass | 15 | 0.0s |  |
| _file_inventory | pass | 0 | 0.0s |  |

## Medium Findings (4)

### [MEDIUM] \`pathlib.Path\` imported but unused

- **File:** `hooks/scripts/lib/audit_emitter.py:70`
- **Scanner:** ruff
- **Rule:** `RUFF-F401`

**What's wrong:** `pathlib.Path` imported but unused

**How to fix:** Auto-fix available: Remove unused import: `pathlib.Path` (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] \`time\` imported but unused

- **File:** `hooks/scripts/lib/audit_emitter.py:66`
- **Scanner:** ruff
- **Rule:** `RUFF-F401`

**What's wrong:** `time` imported but unused

**How to fix:** Auto-fix available: Remove unused import: `time` (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] This code contains bidirectional (bidi) characters. While this is useful for support of right-to-left languages such as Arabic or Hebrew, it can also be used to trick language parsers into executing code in a manner that is different from how it is displayed in code editing and review tools. If this is not what you were expecting, please review this code in an editor that can reveal hidden Unicode characters.

- **File:** `scripts/lib/skill-mining-helpers.sh:538`
- **Scanner:** opengrep
- **Rule:** `generic.unicode.security.bidi.contains-bidirectional-characters`
- **CWE:** [CWE-94: Improper Control of Generation of Code ('Code Injection')](https://cwe.mitre.org/data/definitions/94.html)
- **OWASP:** A03:2021 - Injection

**What's wrong:** This code contains bidirectional (bidi) characters. While this is useful for support of right-to-left languages such as Arabic or Hebrew, it can also be used to trick language parsers into executing code in a manner that is different from how it is displayed in code editing and review tools. If this is not what you were expecting, please review this code in an editor that can reveal hidden Unicode characters.

**Code:**
```bash
requires login
```

**How to fix:** Review this finding and apply the appropriate fix based on the description: This code contains bidirectional (bidi) characters. While this is useful for support of right-to-left languages such as Arabic or Hebrew, it can also be used to trick language parsers into executing c

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Detected a dynamic value being used with urllib. urllib supports 'file://' schemes, so a dynamic value controlled by a malicious actor may allow them to read arbitrary files. Audit uses of urllib calls to ensure user data cannot control the URLs, or consider using the 'requests' library instead.

- **File:** `hooks/scripts/lib/audit_emitter.py:362`
- **Scanner:** opengrep
- **Rule:** `python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected`
- **CWE:** [CWE-939: Improper Authorization in Handler for Custom URL Scheme](https://cwe.mitre.org/data/definitions/939.html)
- **OWASP:** A

**What's wrong:** Detected a dynamic value being used with urllib. urllib supports 'file://' schemes, so a dynamic value controlled by a malicious actor may allow them to read arbitrary files. Audit uses of urllib calls to ensure user data cannot control the URLs, or consider using the 'requests' library instead.

**Code:**
```python
requires login
```

**How to fix:** Review this finding and apply the appropriate fix based on the description: Detected a dynamic value being used with urllib. urllib supports 'file://' schemes, so a dynamic value controlled by a malicious actor may allow them to read arbitrary files. Audit uses of urllib call

**Action:** Plan to fix this issue in your next sprint or release.

---

## Low Findings (2)

- **SBOM-LICENSE-UNKNOWN**: Unknown License: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 (`/.github/workflows/ci.yml`)
- **LICENSE-Apache-2.0**: License Compliance: Apache-2.0 in  (`LICENSE`)

## Skipped Scanners (1)

Scanners that did not run on this scan, with the reason why and how to enable them.

| Scanner | Reason | How to enable |
|---------|--------|---------------|
| `package-validator` | unknown | _(no hint)_ |

## Recommendations

1. Update 1 vulnerable dependency/dependencies -- run `npm audit fix` or equivalent

---
*Generated by Code Hardener v0.1.0 | 2026-07-24T20:23:44.956Z*