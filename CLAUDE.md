# Personal LLM Collaboration Guide

Global defaults for Claude Code. Project CLAUDE.md overrides when conflicting.
Human architects, agent implements.

## Context

- Check for project `context.md` at session start
- Contents: recent decisions (not rules), open questions, immediate next steps
- Update at session end if changed
- For persistent rules, use project CLAUDE.md instead
- Keep it short; no secrets

## Spec-Driven Development

- Follow specs exactly for specified behavior
- Internal gaps (naming, structure, wiring): proceed with brief note
- Ask first: user-visible behavior, data model, security, perf, public API
- Don't expand into adjacent refactors "while here" without approval
- Spec gaps: ask if blocking, else `Assuming: [behavior]. Proceeding unless you object.`
- Respect project constraints; surface conflicts rather than silently violate
- Test-first when test infrastructure exists; don't add tests unless requested
- Flag design concerns: `Design concern: [issue]. Implementing as specified, but [risk].`

## Workflow

- Plan (EnterPlanMode) for multi-file changes; skip for well-specified single-file fixes
- Track (TaskCreate/TaskUpdate) for complex tasks; skip for simple requests
- Explore via Task/Explore agent instead of repeated Glob/Grep
- Commit one logical unit per commit: `type(scope): description`

## Large Tasks

- For multi-file or extended work: break into verifiable checkpoints (3-5 max)
- Each checkpoint: run verification, summarize, continue unless failure

## Error Handling

- Fail fast; log what failed with relevant identifiers
- Validate at boundaries; trust internal code unless investigating failures
- Diagnose before proceeding when tests/builds break

## Risk Boundaries

**Ask before:** destructive operations (data deletion, destructive git), external network calls not in codebase, secrets handling, paid APIs, production actions

**Safe to proceed:** dependency installs, tests, builds, dev servers, localhost/registry/docs network calls

## Reversibility

- Prefer easily-rolled-back changes
- Flag irreversible actions (migrations, deletions) with rollback plan

## Auditability

- End of non-trivial tasks: summarize assumptions, commands, files touched

## Improvement

- Note friction in session; human decides whether to update CLAUDE.md

## Task Completion

Use `say` to announce non-trivial task completion (1-2 sentences). Skip for quick lookups.
