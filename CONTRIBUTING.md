# Contributing to conductor-kernel

Thanks for considering a contribution. This document covers the PR process, scope guidance, code-style expectations, signing requirements, and security disclosure rules. Reading time: ~8 minutes. Apply the rules below before opening a PR; we will close any PR that ignores them with a pointer back here.

---

## Scope

The kernel is **domain-agnostic on purpose**. Contributions are welcomed in the following categories:

| Category | Welcome | Examples |
|---|---|---|
| New primitive in `API.md` | Yes, with discussion first | A new validator type, a new state primitive, a new gate kind |
| Bug fix to existing primitive | Yes | Off-by-one in budget tracking, schema validation error code typo |
| New domain-agnostic agent under `agents/` | Yes, with discussion first | A new validator agent applicable to multiple domains |
| New domain-agnostic skill under `skills/` | Yes, with discussion first | A new capability the kernel publishes for downstream consumers |
| Documentation improvements to `API.md`, `SECURITY.md`, `docs/` | Yes | Clarifications, additional examples, broken-link fixes |
| Tests or verification scripts | Yes | New test cases against existing primitives |
| Schema additions/extensions | Yes, additive only | New optional fields in workflow-state or stream-state schemas |
| Domain-specific code | **No** | Domain code belongs in a separate domain plugin (see `examples/example-domain/` for the contract) |
| Breaking changes to v0.1.0 surface | Not until v1.0.0 unless security-driven | Per API.md §11 deprecation rules |

If you are unsure whether a change is in scope, open a discussion issue before writing the PR.

---

## Before opening a PR

1. **Read [`API.md`](API.md) end-to-end**. The public surface is small enough to read in one sitting (~1 hour); every export here is a stability commitment.
2. **Read [`SECURITY.md`](SECURITY.md)**. Security-relevant changes have additional gates.
3. **Check open issues** to make sure your change isn't already underway or already declined.
4. **Open a discussion issue** for any change touching the public API surface or adding a new agent/skill. Implementation PRs without prior discussion are unlikely to land.

---

## PR process

1. Fork the repository and create a feature branch off `main`.
2. Make your change, with tests where applicable.
3. Run the verification scripts:
   ```
   scripts/verify-agent-tools.sh
   scripts/verify-cross-plugin-dispatch.sh
   scripts/verify-audit-emission.sh
   ```
4. Run gitleaks against the working tree:
   ```
   gitleaks detect --source . --config .gitleaks.toml --no-banner --no-git
   ```
   The working tree must produce zero findings.
5. Open the PR with:
   - A clear title (imperative mood: "Add X" / "Fix Y" / "Document Z").
   - A body that cites the discussion issue (if any), the affected API surface area, the threat-model finding addressed (if security-driven), and the test plan.
6. Sign your commits with a verified signature (DCO sign-off or GPG signed commit). PRs with unsigned commits will not be merged.

---

## Code style

The kernel ships **Markdown agent definitions, JSON Schema state contracts, and Bash verification scripts**. There is no compiled code at v0.1.0. Style rules per file type:

### Markdown (agents, skills, API.md, SECURITY.md, docs)

- ATX-style headers (`# Heading`).
- Sentence-case headers in body, Title-Case in TOCs.
- Code blocks fenced with triple backticks and a language tag (` ```bash`, ` ```python`, ` ```json`).
- Inline code in backticks; file paths in backticks; environment variables in backticks.
- No trailing whitespace.
- Newline at end of file.
- 100-character soft wrap (no hard limit).

### JSON / JSON Schema

- 2-space indent.
- One key per line in objects.
- Strict ordering: `"$schema"`, `"$id"`, `"title"`, `"description"`, then the rest alphabetically. (Existing files may not all comply; do not refactor pre-existing files solely to fix ordering.)
- Comments are NOT permitted in JSON (use `description` fields).
- Schemas declare `additionalProperties: false` at the top level (RC-13 / F-18); extension lives in `domain_extensions` only.

### Bash scripts

- `#!/usr/bin/env bash` shebang.
- `set -euo pipefail` near the top.
- Use `[[ ... ]]` for tests, not `[ ... ]`.
- Quote ALL variables: `"$var"`.
- Functions named in `snake_case`.
- Echo to stderr for diagnostics: `echo "..." >&2`.
- Exit codes documented in script header.

### YAML

- 2-space indent.
- No tabs.
- Use comments to explain non-obvious values.

---

## Commit messages

Format:

```
<type>(<scope>): <subject>

<body>

Co-Authored-By: <name> <email>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `security`.
Scope: optional (e.g., `dispatcher`, `audit`, `state`, `streams`, `recovery`).
Subject: imperative mood, no trailing period, ≤72 chars.
Body: explain WHY, not WHAT. Reference issue/PR numbers.

Example:

```
fix(audit): correctly reject prompt_ref without storage_uri (KER-AE-007)

Previously the audit emitter accepted prompt_ref objects missing the
storage_uri field, which made the F-04 mitigation incomplete. Reject
with KER-AE-007 instead of silently dropping the reference.

Co-Authored-By: Jane Doe <jane@example.org>
```

---

## Signing requirements

The kernel uses signed commits for all changes that touch the public API surface, security policy, or release infrastructure. Signing options:

- **GPG-signed commits**: `git commit -S` with a key registered in your GitHub account.
- **DCO sign-off**: `git commit -s` and we will check the DCO bot signature.

Pull requests without one of these will be blocked by CI.

The release manager additionally signs release tags with cosign per the supply-chain-security contract (see [`agents/supply-chain-security.md`](agents/supply-chain-security.md)).

---

## Security disclosure

**Do not** open a public issue or PR for a vulnerability. See [`SECURITY.md §17.2`](SECURITY.md) for the coordinated disclosure policy. We commit to a 24-hour auto-ack, 14-day triage, and 90-day public disclosure window for good-faith reports.

Researchers who follow the policy receive a non-prosecution commitment for good-faith research that does not exfiltrate user data, degrade availability, or violate the privacy of third parties.

---

## Releasing (maintainers only)

Refer to [`RELEASE-CHECKLIST.md`](RELEASE-CHECKLIST.md). The 12-item OSS-readiness checklist MUST be all green before any `git push --tags v<version>` to the public remote.

---

## Code of conduct

This project follows the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Report violations to the disclosure mailbox in `SECURITY.md §17.2`.

---

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License (the same license as the project itself).
