# Anti-Patterns (FORBIDDEN)

These patterns constitute workflow failure and must be caught by the conductor and critic.

## 1. Placeholder Implementations

```typescript
// FORBIDDEN - This is a placeholder
async function scanWithTrivy(target: string) {
  // TODO: Implement Trivy scanning
  return { vulnerabilities: [] };
}
```

**Detection:** Scan for `TODO:`, `FIXME:`, `HACK:`, empty return values, hardcoded empty arrays/objects.

## 2. Mock Integrations Passed Off as Real

```typescript
// FORBIDDEN - This pretends to integrate but doesn't
class TrivyScanner {
  async scan() {
    return mockResults; // Not actually calling Trivy
  }
}
```

**Detection:** Check `BRD-tracker.integrations[x].is_placeholder`. Verify actual network/CLI calls exist.

## 3. Shell Applications

- Empty route handlers
- API endpoints that return static data
- Services with no actual business logic
- Pages with no real content

**Detection:** Scan for routes with no handler body, static JSON returns, components with no logic.

## 4. Skipping BRD Requirements

- Implementing "core" features only
- Leaving integrations for "later"
- Marking specs complete without full implementation

**Detection:** Compare BRD-tracker.json requirement count vs COMPLETE/ file count. Every REQ-XXX and INT-XXX must reach "complete" status.

## 5. Bypassing Verification Gates

- Proceeding to documentation before final verification
- Moving to COMPLETE without tests passing
- Ignoring gap analysis results
- Skipping critic checkpoints for the current tier

**Detection:** Conductor inline checks verify gate passage before transition.

## 6. Context Contamination

- Passing full codebase context to subagents
- Not spawning fresh context for each TODO spec
- Exceeding 3 specs per planning session

**Detection:** Context budget monitoring (60% rule).

## 7. Sequence Violations

- Running implementation before architecture
- Running tests before implementation
- Skipping CISO review after code generation

**Detection:** Conductor sequence checks at every gate transition.

## 8. Agent Misassignment

- Using builder for architecture (use conductor-architect)
- Using architect for implementation (use conductor-builder)
- Using code-reviewer to fix code (it can only review)

**Detection:** Conductor agent assignment validation against capability matrix.
