# Security Scan Report — bulletproof-conductor-kernel

**Scanner:** Code Hardener (`standard` profile — 12 code-appropriate scanners)
**Scan ID:** `1bc3abeb-4cc0-4635-82ab-06674f4c3fd1`
**Branch:** `main`
**Date:** 2026-07-24
**Score:** **954 / 1000** (quality: excellent)
**Result:** **0 critical · 0 high** · 4 medium · 2 low · 14 info

Signed artifacts from this scan:

- [`bulletproof-conductor-kernel-scan-report.pdf`](bulletproof-conductor-kernel-scan-report.pdf) — full 10-page portal report; page 1 is the Ed25519 in-toto attestation certificate.
- [`attestation.json`](attestation.json) — in-toto attestation (Ed25519-signed).
- [`scan-report.sarif.json`](scan-report.sarif.json) — SARIF 2.1.0 findings.
- [`scan-report-full.md`](scan-report-full.md) — full backend Markdown report.

---

## Headline

| Severity | Count |
|---|---|
| Critical | **0** |
| High | **0** |
| Medium | 4 |
| Low | 2 |
| Info | 14 |

- **Secrets (gitleaks): PASS** — 0 findings across 148 files (150 rules).
- **SCA (grype): PASS** — 0 vulnerable dependencies (the kernel has none).
- **IaC (checkov): PASS**, **jscpd: PASS**, **oxlint: PASS**, **actionlint: PASS**.
- Scanners run: 12 (11 executed, 1 skipped as not-applicable).

---

## Findings fixed to reach 0 critical / 0 high

| # | Tool / Rule | Severity | File | Fix |
|---|---|---|---|---|
| 1 | `oxlint` (OXLINT-UNKNOWN — "Unexpected token") | **HIGH** | `scripts/lib/code-mode-template.js` | Added `.oxlintrc.json` `ignorePatterns` to exclude the file. It is a **dispatch-time template**, not runnable JavaScript — it contains `<<PLACEHOLDER>>` tokens that `scripts/code-mode-dispatch.sh` substitutes before execution. Linting it as standalone JS produced a spurious parse error. No behavior change. |
| 2 | `opengrep`/yaml `github-actions-mutable-action-tag` | MEDIUM | `.github/workflows/ci.yml` | Pinned `actions/checkout@v4` to commit SHA `11d5960a326750d5838078e36cf38b85af677262` (kept a `# v4` comment). Eliminates the mutable-tag supply-chain finding. |

After fix #1 the score rose 800 → 950 (0 high); after fix #2 the score rose to 954
and the mutable-action-tag medium cleared. Both fixes were committed and the scan
re-run against `main` to confirm the result — **this report reflects the final,
re-scanned state.**

---

## What remains (low-risk, documented — not fixed)

These residuals are cosmetic or benign heuristic hits. Per policy they are
documented rather than "fixed" (chasing them adds risk without adding safety):

| Tool / Rule | Severity | Location | Why it is safe to leave |
|---|---|---|---|
| `ruff` F401 (`pathlib.Path` unused) | MEDIUM | `hooks/scripts/lib/audit_emitter.py:70` | Unused import — purely cosmetic; no runtime or security effect. |
| `ruff` F401 (`time` unused) | MEDIUM | `hooks/scripts/lib/audit_emitter.py:66` | Same — cosmetic unused import. |
| `opengrep` `contains-bidirectional-characters` | MEDIUM | `scripts/lib/skill-mining-helpers.sh:538` | **False positive / security control.** The flagged line is a regex that *strips* zero-width and RTL/LTR override marks (input sanitization). The scanner flags the presence of bidi characters inside the sanitizing pattern itself. Removing it would remove a defense. |
| `opengrep` `dynamic-urllib-use-detected` | MEDIUM | `hooks/scripts/lib/audit_emitter.py:362` | `urllib` posts an HMAC-signed audit record to the **operator-configured** audit sink URL (`sink_config`), not to an attacker-controlled value. This is the intended, deliberate audit-egress path. |
| `syft`/SBOM `Unknown License: actions/checkout@…` | LOW | `.github/workflows/ci.yml` | The GitHub Action's own license isn't declarable in the repo SBOM; `actions/checkout` is MIT upstream. Not a kernel dependency. |
| `LICENSE-Apache-2.0 in LICENSE` | LOW | `LICENSE` | **Flagged for maintainer resolution — see below.** |

---

## ⚠️ Requires human/legal judgment — license inconsistency

The scan surfaced a genuine, unresolved **license contradiction** in the repository:

- `LICENSE` and `NOTICE` contain **Apache-2.0** text.
- `plugin.json`, `.claude-plugin/plugin.json`, `README.md`, `API.md`, `CHANGELOG.md`,
  `sbom.cdx.json`, and `examples/example-domain/` all declare **MIT**.

Choosing the correct license is a **legal/maintainer decision**, not a mechanical
edit, so it was **not changed** during this pass. A maintainer must decide whether
the project is MIT or Apache-2.0 and then make every artifact consistent (README,
manifests, SBOM, doc footers, `LICENSE`, `NOTICE`). Until then, consumers should
treat the license as unresolved.

---

MIT © 2026 bulletproofsoftware-ai. See [LICENSE](../../LICENSE) and [NOTICE](../../NOTICE).
