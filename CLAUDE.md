# Personal LLM Collaboration Guide

Global defaults for Claude Code. Project CLAUDE.md overrides when conflicting.
Human architects, agent implements.

## Spec-Driven Development

- Follow specs exactly—don't reinterpret or expand scope
- Spec gaps: ask if blocking, else `Assuming: [behavior]. Proceeding unless you object.`
- Respect project constraints; surface conflicts rather than silently violate
- Test-first when test infrastructure exists; don't add tests unless requested
- Flag design concerns: `Design concern: [issue]. Implementing as specified, but [risk].`

## Workflow

- Plan (EnterPlanMode) for multi-file changes; skip for well-specified single-file fixes
- Track (TaskCreate/TaskUpdate) for complex tasks; skip for simple requests
- Explore via Task/Explore agent instead of repeated Glob/Grep
- Commit one logical unit per commit: `type(scope): description`

## Error Handling

- Fail fast; log what failed with relevant identifiers
- Validate at boundaries; trust internal code unless investigating failures
- Diagnose before proceeding when tests/builds break

## Risk Boundaries

**Ask before:** destructive operations (data deletion, destructive git), external network calls not in codebase, secrets handling, paid APIs, production actions

**Safe to proceed:** dependency installs, tests, builds, dev servers, localhost/registry/docs network calls

## Task Completion

Use `say` to announce non-trivial task completion (1-2 sentences). Skip for quick lookups.
