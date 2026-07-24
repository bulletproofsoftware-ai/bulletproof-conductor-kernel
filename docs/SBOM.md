# Software Bill of Materials (SBOM)

## Summary

`conductor-kernel` v0.1.0 ships **zero direct runtime dependencies**. It is composed
entirely of:

- **Markdown** — 19 agent definitions (`agents/`), 14 skill definitions (`skills/`),
  and canonical orchestration prose (`lib/dispatcher-core.md`).
- **JSON Schema** — 2 state schemas (`schemas/`) and 3 event-envelope schemas
  (`schemas/events/`).
- **Bash** — verification scripts, hook scripts, and stream-mode reference scripts.
- **YAML / JSON** — configuration and template files (`lib/budget-defaults.yaml`,
  `lib/recovery-playbook.yaml`, `templates/n8n-audit-emitter.json`, `plugin.json`).

There is no compiled artifact, no `package.json`, no `requirements.txt`, and no
`pyproject.toml` to resolve — so there are no transitive package dependencies to
enumerate.

## Machine-readable SBOM

The authoritative machine-readable SBOM is [`../sbom.cdx.json`](../sbom.cdx.json)
(CycloneDX 1.5). It declares the kernel as a single root component with an empty
`components[]` array and an empty `dependencies[].dependsOn`, and a `compositions`
entry of `aggregate: "complete"` — asserting the composition is fully known and
dependency-free.

| CycloneDX field | Value |
|---|---|
| Format / spec | CycloneDX 1.5 |
| Root component | `pkg:generic/conductor-kernel@0.1.0` |
| Component type | library |
| Direct dependencies | 0 |
| Transitive dependencies | 0 |
| Composition aggregate | complete |
| Declared license (manifest) | MIT — see the license note below |

## Operator-provided (environment) dependencies

The following tools are **not bundled** with the kernel — they are environment
dependencies an operator provides, and only some workflows need them:

| Tool | Used by | Required? |
|---|---|---|
| Claude Code `>= 1.0.0` | The plugin runtime | Yes |
| `governance-plugin >= 0.1.0` | Audit trail + human gates | Yes (for audit/gates) |
| `bash` | Scripts and hooks | Yes |
| `gemini` CLI | `gemini-validator` agent | Only if used |
| `claude-memory-mcp` (Qdrant) | `memory_*` primitives, stream-mode state | Only if used |
| `n8n` + `n8n-mcp` | Stream-mode subscriptions | Only if used |
| `gitleaks` / `trufflehog` | `secrets-lifecycle` agent | Only if used |
| `syft` | SBOM regeneration (future) | Only for SBOM re-gen |
| `jq`, `sqlite3` | Script/audit convenience | Optional |

## Base images

None. The kernel ships no Dockerfile and no container image. It runs inside the
Claude Code process; there is no separate runtime image to attest.

## Regeneration

This SBOM was hand-authored (Syft was unavailable at authoring time) and accurately
reflects a dependency-free composition. When SDK bindings land at v0.2.0, the SBOM
**must** be regenerated with Syft per the CISA minimum-elements guidance:

```bash
brew install syft   # or: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh
syft dir:. -o cyclonedx-json > sbom.cdx.json
```

## License note

The machine-readable SBOM and the plugin manifests (`plugin.json`,
`.claude-plugin/plugin.json`), README, and this documentation set declare **MIT**.
The repository's `LICENSE` and `NOTICE` files, however, currently contain the
**Apache-2.0** text. This is a known inconsistency flagged for maintainer/legal
resolution — see [`scan/scan-report.md`](scan/scan-report.md). Consumers should
treat the license as **unresolved pending that decision** and check the repository
for the corrected declaration before relying on it.

---

MIT © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
