---
name: implement-plan
description: Implement a phased plan from docs/plans/. Executes phase-by-phase, running verification after each phase and pausing for manual confirmation before proceeding. Use when you have a plan file produced by the plan skill.
---

# Implement Plan

You are implementing an approved implementation plan from `docs/plans/`. Plans contain phases with specific changes and verification steps.

## Before you start

1. Read the plan file completely. Check for any already-completed checkboxes (`- [x]`).
2. If a research doc is referenced, read that too.
3. Read the files mentioned in the first uncompleted phase — you'll read subsequent phases' files when you reach them.
4. Note the Out of Scope section. Do not drift into work that the plan explicitly excludes.
5. Think about how the pieces fit together before writing any code.

If no plan path is provided, ask for one. If the plan has unresolved questions or ambiguity, stop and ask the user before proceeding.

## How to work

### Follow the phases

Implement each phase fully before moving to the next. Within a phase:

1. Read all files mentioned in this phase fully, if you haven't already.
2. Make the changes described.
3. Run the automated verification steps listed in the plan.
4. Fix any failures before proceeding.
5. Commit the phase's changes with the format: `Phase N: <description> (ref docs/plans/<plan-name>.md)`.
6. Check off completed items in the plan file using the Edit tool.
7. Pause and inform the user the phase is ready for manual verification:

```
Phase N complete — ready for manual verification.

Automated checks passed:
- [List what passed]

Please verify the manual items from the plan:
- [List manual verification items]

Let me know when manual testing is done so I can proceed to Phase N+1.
```

Do not check off manual verification items until the user confirms them.

If instructed to execute multiple phases without pausing, skip the pause between phases but still run automated verification for each phase. Defer manual verification items to the final pause — list all accumulated manual items together so nothing is silently dropped.

### Adapt when reality diverges from the plan

Plans are carefully designed, but the codebase may have changed since the plan was written. When something doesn't match:

- Stop and think about why.
- Present the issue clearly:

```
Issue in Phase N:
Expected: [what the plan says]
Found: [actual situation]
Why this matters: [explanation]

How should I proceed?
```

Don't silently deviate from the plan. The plan is the contract — changes should be deliberate.

If a fix in one phase affects a later phase's plan, flag this immediately:

```
Note: the fix for this issue in Phase N means Phase M will need adjustment:
- [What changes in the later phase]
```

### Track progress

- Use the Edit tool to check off items in the plan file as you complete them.
- This makes it easy to resume if the session is interrupted.

## Resuming interrupted work

If the plan has existing checkmarks:
- Run the full test suite once to verify previous work is sound before building on top of it.
- Pick up from the first unchecked item.
- If the test suite fails on previously-completed work, investigate before proceeding.

## What to prioritise

- **Correctness over speed.** Get it right, verify it's right, then move on.
- **Consistency with the codebase.** Follow existing patterns and conventions.
- **Simplicity.** Prefer the straightforward approach.
- **The plan's intent.** When adapting to reality, stay true to what the plan is trying to accomplish, even if specific file paths or code snippets need adjusting.
- **Stay in scope.** If you notice an opportunity to improve something outside the plan's scope, note it for the user but don't act on it.

## When you're done

After the final phase:
- Confirm all automated verification passes.
- Confirm all manual verification items are checked off.
- Give the user a brief summary of what was built and any deviations from the plan.
