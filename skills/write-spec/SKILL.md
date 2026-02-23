---
name: write-spec
description: Collaboratively write a technical specification for a component or feature. Use when the user wants to define what needs to be built before implementation begins. Produces a spec file in docs/specs/.
---

# Write Spec

You are helping the user write a technical specification. Your role is to act as a thoughtful collaborator who asks the right questions, identifies gaps, and produces a clear, testable spec.

## How to work

Start by understanding the user's intent. They may have a clear picture or just a rough idea. Either is fine. Your job is to draw out what they mean and shape it into a well-structured spec.

Read the spec format defined in `docs/specs/SPEC-FORMAT.md` before writing anything. If that file doesn't exist, follow the format described below.

**Read the codebase before drafting.** Look at the existing modules, naming conventions, and patterns in the area the new component will touch. A spec written in ignorance of the codebase produces requirements that conflict with existing design or duplicate what already exists. You don't need to read everything — focus on what's adjacent to the component being specced.

If the user references an existing spec file, read it first. You may be updating an existing component — adding requirements, tightening constraints, or reworking scope based on what was learned during earlier implementation. Treat the existing spec as the starting point, not a blank slate. Preserve requirements that haven't changed, keep any Decisions that were recorded during previous implementation, and clearly identify what's new or different — mark new requirements with **(new)** and changed ones with **(changed)** so `implement-spec` knows what still needs to be built. If requirements are being removed or changed, confirm with the user that this is intentional.

Before drafting, make sure you understand:

- What the component should do and why it exists.
- What the boundaries are — what is explicitly out of scope.
- How it relates to existing parts of the codebase.
- What "done" looks like in concrete, testable terms.

Ask clarifying questions when something is ambiguous or underspecified. Don't assume. It's better to ask one good question than to guess wrong and write a spec that needs rewriting.

When you have enough to work with, draft the spec and present it for review. Expect the user to push back, refine, or redirect. This is collaborative — the spec should reflect the user's intent, not your assumptions.

## What goes in a spec

- **Purpose**: A short paragraph on what and why.
- **Requirements**: Numbered, testable, behaviour-focused statements. Describe what the system does, not how it does it.
- **Constraints**: Non-functional boundaries — performance, compatibility, security, things the component must not do. Constraints may include architectural boundaries where they are genuinely non-negotiable (e.g. "must be a supervised OTP process", "must not introduce new dependencies"). Don't use Constraints to prescribe implementation choices that could legitimately go multiple ways — those belong in Decisions after implementation.
- **Dependencies**: Other specs, modules, or external systems this work touches.
- **Acceptance Criteria**: A checklist of pass/fail outcomes. When these are all true, the work is done. Acceptance criteria are distinct from requirements: requirements describe behaviour; acceptance criteria describe how you verify the work is complete. Every requirement should be traceable to at least one acceptance criterion, but criteria can also cover cross-cutting concerns like documentation, warnings, and test coverage.
- **Notes** (optional): Context, open questions, rejected alternatives.
- **Decisions** (optional): Left empty — this gets filled during implementation.

## What does not go in a spec

- Implementation details. No function signatures, no module names, no data structure choices. Those belong in the code and in the Decisions section after implementation.
- Vague requirements that can't be tested. "The system should be fast" is not a requirement. "Response time under 200ms for the common case" is.
- Scope creep. If a requirement doesn't serve the stated purpose, it belongs in a different spec.

## Where to save

Save the spec to `docs/specs/<component-name>.md`. Use a descriptive, lowercase, hyphenated name.

If `docs/specs/` doesn't exist, create it. If a `SPEC-FORMAT.md` doesn't exist there yet, create one based on the format above so future specs stay consistent.

## When you're done

Present the spec to the user for final review. Don't move on to implementation — that's a separate step using the `implement-spec` skill. The user decides when a spec is ready.
