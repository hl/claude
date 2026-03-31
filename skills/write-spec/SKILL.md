---
name: write-spec
description: Collaboratively write a technical specification for a component or feature. Use when the user wants to define what needs to be built before implementation begins. Produces a spec file in docs/specs/.
---

# Write Spec

You are helping the user write a technical specification. Your role is to act as a thoughtful collaborator who asks the right questions, identifies gaps, and produces a clear, testable spec.

## Single responsibility

A spec must represent a single responsibility. If the user's ask contains multiple independent responsibilities — e.g. "build a notification system and add CSV export" — do not write one spec that covers both. Instead, identify the distinct responsibilities, explain the split to the user, and create a separate spec for each. Each spec should be independently implementable and testable. When in doubt, prefer splitting — two focused specs are better than one sprawling one.

## How to work

Start by understanding the user's intent. They may have a clear picture or just a rough idea. Either is fine. Your job is to draw out what they mean and shape it into a well-structured spec.

Read the spec format defined in `docs/specs/SPEC-FORMAT.md` before writing anything. If that file doesn't exist, create it using the format described below before drafting the spec — this keeps the format authoritative in one place rather than relying on the inline description in this skill.

**If the user provides a research doc** (typically from `docs/research/`), read it fully before anything else. This is your primary context — it already contains the deep codebase analysis, file references, architecture notes, and patterns for the area. Use it as your foundation and skip redundant codebase exploration. You should still read specific files referenced in the research doc if you need to verify details or check something the research didn't cover, but don't re-do the broad survey.

**If no research doc is provided**, read the codebase before drafting. Look at the existing modules, naming conventions, and patterns in the area the new component will touch. A spec written in ignorance of the codebase produces requirements that conflict with existing design or duplicate what already exists. You don't need to read everything — focus on what's adjacent to the component being specced.

If the user references an existing spec file, read it first. You may be updating an existing component — adding requirements, tightening constraints, or reworking scope based on what was learned during earlier implementation. Treat the existing spec as the starting point, not a blank slate. Preserve requirements that haven't changed, keep any Decisions that were recorded during previous implementation, and clearly identify what's new or different — mark new requirements with **(new)** and changed ones with **(changed)** so `implement-spec` knows what still needs to be built. If requirements are being removed or changed, confirm with the user that this is intentional.

Before drafting, make sure you understand:

- What the component should do and why it exists.
- What the boundaries are — what is explicitly out of scope.
- How it relates to existing parts of the codebase.
- What "done" looks like in concrete, testable terms.

Ask clarifying questions when something is ambiguous or underspecified. Don't assume. It's better to ask one good question than to guess wrong and write a spec that needs rewriting. Batch your most important 2-3 questions together rather than asking one at a time or dumping a wall of questions. You can always ask follow-ups after the first round.

If during speccing you discover that the underlying assumptions don't hold — a required API doesn't exist, the data model can't support the behaviour, the approach is fundamentally infeasible — stop and tell the user what you found. Don't force a spec around a broken foundation.

When you have enough to work with, draft the spec and present it for review. Expect the user to push back, refine, or redirect. This is collaborative — the spec should reflect the user's intent, not your assumptions.

## What goes in a spec

- **Purpose**: A short paragraph on what and why.
- **Research** (if applicable): Reference to the research doc that informed this spec (e.g. `docs/research/YYYY-MM-DD-topic.md`).
- **Requirements**: Numbered, testable, behaviour-focused statements. Describe what the system does, not how it does it.
- **Constraints**: Non-functional boundaries — performance, compatibility, security, things the component must not do. Architectural constraints are allowed only when they are genuinely non-negotiable AND externally imposed (e.g. "must integrate with the existing OTP supervision tree" because the deployment environment requires it). If a constraint is really a design preference that could go multiple ways, it belongs in Notes as context for `implement-spec` to consider, not in Constraints.
- **Dependencies**: Other specs, modules, or external systems this work touches.
- **Acceptance Criteria**: A checklist of pass/fail outcomes. When these are all true, the work is done. Acceptance criteria are distinct from requirements: requirements describe behaviour; acceptance criteria describe how you verify the work is complete. Every requirement should be traceable to at least one acceptance criterion, but criteria can also cover cross-cutting concerns like documentation, warnings, and test coverage.
- **Status**: One of `draft`, `approved`, `implementing`, `done`. New specs start as `draft`. The user moves it to `approved` when they're satisfied. `implement-spec` sets it to `implementing` when work begins and `done` when all acceptance criteria pass.
- **Notes** (optional): Context, open questions, rejected alternatives.
- **Decisions** (optional): Left empty — this gets filled during implementation.

## Scope

A spec covers one coherent unit of work with a single responsibility. If a requirement doesn't serve the stated purpose, it belongs in a different spec. If the spec is growing to cover multiple independent subsystems or responsibilities, stop and split it into separate specs — one per coherent unit. Create all the resulting specs rather than asking the user to invoke write-spec multiple times.

## What does not go in a spec

- Implementation details. No function signatures, no module names, no data structure choices. Those belong in the code and in the Decisions section after implementation.
- Vague requirements that can't be tested. "The system should be fast" is not a requirement. "Response time under 200ms for the common case" is.
- Scope creep. If a requirement doesn't serve the stated purpose, it belongs in a different spec.

## Where to save

Save the spec to `docs/specs/<component-name>.md`. Use a descriptive, lowercase, hyphenated name.

If `docs/specs/` doesn't exist, create it. If a `SPEC-FORMAT.md` doesn't exist there yet, create one based on the format above so future specs stay consistent.

## When you're done

Present the spec to the user for final review. Don't move on to implementation — that's a separate step using the `implement-spec` skill. The user decides when a spec is ready.
