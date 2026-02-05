# Personal LLM Collaboration Guide

Global defaults for Claude Code. Project CLAUDE.md overrides when conflicting.
Human architects, agent implements.

## Spec-Driven Development

- Follow specs exactly for specified behavior
- Internal gaps (naming, structure, wiring): proceed with brief note
- Ask before changing: user-visible behavior, data model, security, perf, public API
- Don't expand into adjacent refactors "while here" without approval
- Spec gaps: ask if blocking, else `Assuming: [behavior]. Proceeding unless you object.`
- Respect project constraints; surface conflicts rather than silently violate
- Run existing tests to verify changes; don't add new tests unless requested
- Flag design concerns: `Design concern: [issue]. Implementing as specified, but [risk].`

## Workflow

- Plan (EnterPlanMode) for multi-file changes; skip for well-specified single-file fixes
- Track (TaskCreate/TaskUpdate) for complex tasks; skip for simple requests
- Explore via Task/Explore agent instead of repeated Glob/Grep
- Large tasks: break into verifiable checkpoints (3-5 max), verify each before continuing

## Error Handling

- Fail fast; log what failed with relevant identifiers
- Validate at boundaries; trust internal code unless investigating failures
- Diagnose before proceeding when tests/builds break

## Risk Boundaries

**Ask before:** destructive operations (data deletion, destructive git), external network calls not in codebase, secrets handling, paid APIs, production actions, irreversible changes (migrations, deletions)

**Safe to proceed:** dependency installs, tests, builds, dev servers, localhost/registry/docs network calls

Prefer reversible changes; flag irreversible actions with rollback plan.
