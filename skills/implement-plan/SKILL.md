---
name: implement-plan
description: Implement a phased plan from docs/plans/. Executes phase-by-phase, running verification after each phase and pausing for manual confirmation before proceeding. Use when you have a plan file produced by the plan skill.
---

# Implement Plan

You are implementing an approved implementation plan from `docs/plans/`. Plans contain phases with specific changes and verification steps.

## Before you start

1. Read the plan file completely. Check for any already-completed checkboxes (`- [x]`).
2. Read every file mentioned in the plan — fully, no partial reads.
3. If a research doc is referenced, read that too.
4. Think about how the pieces fit together before writing any code.

If no plan path is provided, ask for one. If the plan has unresolved questions or ambiguity, stop and ask the user before proceeding.

## How to work

### Follow the phases

Implement each phase fully before moving to the next. Within a phase:

1. Make the changes described.
2. Run the automated verification steps listed in the plan.
3. Fix any failures before proceeding.
4. Check off completed items in the plan file using the Edit tool.
5. Pause and inform the user the phase is ready for manual verification:

```
Phase N complete — ready for manual verification.

Automated checks passed:
- [List what passed]

Please verify the manual items from the plan:
- [List manual verification items]

Let me know when manual testing is done so I can proceed to Phase N+1.
```

Do not check off manual verification items until the user confirms them.

If instructed to execute multiple phases without pausing, skip the pause until the last phase.

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

### Track progress

- Use the Edit tool to check off items in the plan file as you complete them.
- This makes it easy to resume if the session is interrupted.

## Resuming interrupted work

If the plan has existing checkmarks:
- Trust that completed work is done.
- Pick up from the first unchecked item.
- Verify previous work only if something seems off.

## What to prioritise

- **Correctness over speed.** Get it right, verify it's right, then move on.
- **Consistency with the codebase.** Follow existing patterns and conventions.
- **Simplicity.** Prefer the straightforward approach.
- **The plan's intent.** When adapting to reality, stay true to what the plan is trying to accomplish, even if specific file paths or code snippets need adjusting.

## When you're done

After the final phase:
- Confirm all automated verification passes.
- Confirm all manual verification items are checked off.
- Give the user a brief summary of what was built and any deviations from the plan.
