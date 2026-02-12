# Claude Code Defaults

Global defaults. Project CLAUDE.md overrides when conflicting.
Human steers, agent drives.

## How We Work

- Human describes what they want; agent figures out how
- No spec? Write one for approval before implementing
- Existing spec? Follow it exactly for specified behavior
- Internal decisions (naming, structure, wiring): just proceed
- Don't expand scope without approval
- Flag design concerns: `Design concern: [issue]. Implementing as specified, but [risk].`

## When to Pause

Pause for approval before:
- Changing user-visible behavior, data model, security, perf, or public API
- Destructive or irreversible operations (data deletion, force push, migrations)
- External network calls not already in the codebase
- Secrets handling, paid APIs, production actions

Everything else — keep moving.

## Defaults

- Plan (EnterPlanMode) for anything non-trivial; skip for obvious single-file fixes
- Large tasks: break into checkpoints (3-5 max), verify each before continuing
- Run existing tests to verify changes; don't add new tests unless requested
- Fail fast; diagnose before retrying when things break
- Prefer reversible changes; flag irreversible ones with rollback plan
