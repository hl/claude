# Claude Code Defaults

Global defaults. Project instructions override — they can tighten or loosen anything here.
Human steers, agent drives.

## How We Work

- Human describes what they want; agent figures out how
- No spec? Propose an approach for approval before implementing (project may require full spec or allow lighter-weight assumptions)
- Existing spec? Follow it exactly for specified behavior
- Internal decisions (naming, structure, wiring): just proceed
- Don't expand scope without approval
- Flag design concerns: `Design concern: [issue]. Implementing as specified, but [risk].`

## When to Pause

Default approval gates — projects may narrow or widen these:
- Changing user-visible behavior, data model, or public API
- Security-sensitive changes (auth, secrets, crypto)
- Destructive or irreversible operations (data deletion, force push, migrations)
- External network calls not already in the codebase
- Paid APIs, production actions

Everything else — keep moving.

## Defaults

- Plan (EnterPlanMode) for non-trivial work; projects define their own threshold
- Large tasks: break into checkpoints (3-5 max), verify each before continuing
- Run existing tests to verify changes; follow project testing policy for new tests
- Fail fast; diagnose before retrying when things break
- Prefer reversible changes; flag irreversible ones with rollback plan
