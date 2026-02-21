---
name: implement-spec
description: Implement a technical specification from docs/specs/. Use when the user wants to build a component that has an existing spec file. Works autonomously — writes tests first, implements incrementally, verifies continuously.
---

# Implement Spec

You are implementing a technical specification. The spec defines what needs to be built. Your job is to figure out the best way to build it, working autonomously while keeping the user informed of meaningful progress.

## Before you start

Read the spec file thoroughly. Make sure you understand every requirement and acceptance criterion. If anything is ambiguous or contradictory, stop and ask the user before proceeding. Don't guess at intent.

Familiarise yourself with the parts of the codebase that the spec touches. Understand existing patterns, conventions, and architecture before writing any code. The implementation should feel like it belongs in this codebase, not like it was dropped in from outside.

## How to work

**Tests first.** For each requirement, write the test before writing the implementation. The test should fail initially and pass once the implementation is correct. This isn't dogma — if a requirement genuinely can't be tested in isolation, note why in the spec's Decisions section and move on. But the default is always test first.

**Work incrementally.** Break the spec into small, independently verifiable pieces of work. Implement one piece at a time. Verify it works before moving to the next. Commit after each verified piece. If something breaks, you want to know exactly which change caused it.

**Verify continuously.** After each piece of work, run the relevant tests. After all pieces are done, run the full test suite. Don't wait until the end to discover that an early change broke something unrelated.

**Commit atomically.** Each commit should represent one coherent, verified change. The commit message should reference the spec and describe what was done. The codebase should be in a working state after every commit.

**Record decisions.** When you make an architectural or design choice during implementation, add it to the Decisions section of the spec file. Future readers should understand not just what was built, but why it was built that way.

## What to prioritise

- **Correctness over speed.** Get it right. Verify it's right. Then move on.
- **Consistency with the codebase.** Follow existing patterns and conventions. Don't introduce new paradigms unless the spec explicitly calls for it.
- **Simplicity.** Prefer the straightforward approach. Complexity should be justified by a requirement, not by cleverness.
- **Existing tools and libraries.** Use what's already in the project. Don't add dependencies unless the spec requires capabilities that don't exist in the current stack.

## When you're done

Verify all acceptance criteria in the spec are met. Run the full test suite. Make sure no compiler warnings were introduced. Update the spec's acceptance criteria checkboxes to reflect the current state.

Then let the user know the implementation is complete, with a brief summary of what was built and any decisions that were made along the way. Keep it concise — the spec and the code tell the full story.

## If something goes wrong

If you hit a problem that the spec doesn't account for, or if a requirement turns out to be impossible or impractical given the codebase, stop and tell the user. Explain what you found and what the options are. Don't silently deviate from the spec. The spec is the contract — changes to it should be deliberate.