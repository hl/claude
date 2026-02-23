---
name: implement-spec
description: Implement a technical specification from docs/specs/. Use when the user wants to build a component that has an existing spec file. Works autonomously — writes tests first, implements incrementally, verifies continuously.
---

# Implement Spec

You are implementing a technical specification. The spec defines what needs to be built. Your job is to figure out the best way to build it, working autonomously while keeping the user informed of meaningful progress.

## Before you start

Read the spec file thoroughly. Make sure you understand every requirement and acceptance criterion. If anything is ambiguous or contradictory, stop and ask the user before proceeding. Don't guess at intent.

Familiarise yourself with the parts of the codebase that the spec touches. Understand existing patterns, conventions, and architecture before writing any code. The implementation should feel like it belongs in this codebase, not like it was dropped in from outside.

## Handling instructions that go beyond the spec

The user may invoke this skill with extra instructions alongside the spec (e.g. "use start_supervised!/1 in tests", "expose this through the top-level module"). Before acting, classify the instruction:

- **Implementation style** — the observable behaviour of the component doesn't change; only *how* it's built does. Treat this as an architectural decision: implement it and record it in the spec's Decisions section.
- **Behavioural change** — the instruction adds, removes, or changes something a caller or user of the component would observe. Stop and tell the user this goes beyond the current spec. Propose updating the spec with `write-spec` first, then returning to implement.

When in doubt, ask. Silently expanding or contracting the spec's scope is worse than a brief clarification.

## How to work

**Tests first.** For each requirement, write the test before writing the implementation. The test should fail initially and pass once the implementation is correct. This isn't dogma — if a requirement genuinely can't be tested in isolation, note why in the spec's Decisions section and move on. But the default is always test first.

**Refactoring tasks.** If the task is to change *how* something is implemented without changing its observable behaviour (restructuring modules, swapping a data structure, changing test helpers), tests-first doesn't apply in the same way — the existing tests already cover the behaviour. In that case: make the change, run the existing tests after each step, and treat the task as done when all tests still pass and no new warnings are introduced.

**Work incrementally.** Break the spec into small, independently verifiable pieces of work. Implement one piece at a time. Verify it works before moving to the next. If something breaks, you want to know exactly which change caused it.

**Verify continuously.** After each piece of work, run the relevant tests. After all pieces are done, run the full test suite. Don't wait until the end to discover that an early change broke something unrelated.

**Commit atomically.** Each commit should represent one coherent, verified change. The commit message should reference the spec and describe what was done. The codebase should be in a working state after every commit. If the project has no git repository, skip commits but keep the same incremental discipline — verify each piece before moving to the next.

**Record decisions.** When you make an architectural or design choice during implementation, add it to the Decisions section of the spec file. Future readers should understand not just what was built, but why it was built that way.

## What to prioritise

- **Correctness over speed.** Get it right. Verify it's right. Then move on.
- **Consistency with the codebase.** Follow existing patterns and conventions. Don't introduce new paradigms unless the spec explicitly calls for it.
- **Simplicity.** Prefer the straightforward approach. Complexity should be justified by a requirement, not by cleverness.
- **Existing tools and libraries.** Use what's already in the project. Don't add dependencies unless the spec requires capabilities that don't exist in the current stack.

## When you're done

Before wrapping up, work through this checklist:

- All acceptance criteria in the spec are met.
- The full test suite passes with no new compiler warnings introduced.
- The spec's acceptance criteria checkboxes are ticked.
- Every architectural or design choice made during implementation is recorded in the spec's Decisions section. If there is no Decisions section yet, add one. If no non-trivial decisions were made, note that explicitly so the omission is deliberate.

Then let the user know the implementation is complete, with a brief summary of what was built and any decisions that were made along the way. Keep it concise — the spec and the code tell the full story.

## If something goes wrong

If you hit a problem that the spec doesn't account for, or if a requirement turns out to be impossible or impractical given the codebase, stop and tell the user. Explain what you found and what the options are. Don't silently deviate from the spec. The spec is the contract — changes to it should be deliberate.
