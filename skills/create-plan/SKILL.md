---
name: create-plan
description: Create detailed, phased implementation plans through interactive research and iteration. Use when the task involves changing existing code across multiple files and you need a clear execution strategy. Different from write-spec — plans define HOW to change things (phases, specific files, verification steps), while specs define WHAT to build (behaviour, requirements, acceptance criteria).
---

# Create Implementation Plan

You are creating a detailed implementation plan through an interactive, iterative process. Be skeptical, thorough, and collaborative.

## When to use this vs write-spec

- **Plan**: Changing existing code, fixing bugs, refactoring, integrating features across an existing codebase. The plan names specific files, defines phases, and includes verification steps.
- **Spec**: Building a new component or module where the key question is "what should it do?" not "how do we change what exists."

If you're unsure, ask the user.

## Getting started

If the user provides a file path, ticket, or description — read it fully. If they provide a research doc from `/research`, read that too — it's your primary context.

If nothing was provided, ask:

```
I'll help you create a phased implementation plan. What do we need to build or change?

Provide:
1. The task description or ticket
2. Any relevant context or constraints
3. Links to research docs if you ran /research first
```

## Process

### Step 1: Understand the codebase

Before asking any questions, research the relevant code:

1. Read all mentioned files fully.
2. Spawn parallel Explore agents to understand the current state:
   - Find all files related to the task
   - Understand the current implementation and data flow
   - Identify patterns and conventions in the area
3. Read the files they identify.

Then present your understanding:

```
Based on the task and my research, I understand we need to [summary].

I found:
- [Current implementation detail with file:line]
- [Relevant pattern or constraint]
- [Potential complexity or edge case]

Questions my research couldn't answer:
- [Specific question requiring human judgment]
- [Design preference that affects approach]
```

Only ask questions you genuinely cannot answer through code investigation.

### Step 2: Research and design options

After getting initial clarification:

1. If the user corrects a misunderstanding — verify the correction in the code before proceeding.
2. Spawn deeper research agents if needed.
3. Present design options:

```
**Design Options:**
1. [Option A] — [pros/cons]
2. [Option B] — [pros/cons]

Which approach do you prefer?
```

### Step 3: Propose plan structure

Once aligned on approach, propose the phases:

```
## Proposed Phases:
1. [Phase name] — [what it accomplishes]
2. [Phase name] — [what it accomplishes]
3. [Phase name] — [what it accomplishes]

Does this phasing make sense?
```

Get feedback before writing details.

### Step 4: Write the plan

Save to `docs/plans/YYYY-MM-DD-<description>.md`. Create the directory if needed.

Use this template:

```markdown
# <Task Name> — Implementation Plan

## Overview

<Brief description of what we're changing and why>

## Current State

<What exists now, key constraints discovered>

### Key Discoveries
- [Finding with file:line reference]
- [Pattern to follow]
- [Constraint to work within]

## Out of Scope

<Explicitly list what we're NOT doing to prevent scope creep>

## Approach

<High-level strategy and reasoning>

---

## Phase 1: <Descriptive Name>

### What this phase accomplishes
<Summary>

### Changes

#### <Component/File>
**File**: `path/to/file.ext`
**Changes**: <Summary of what changes>

\`\`\`language
// Key code to add/modify (only include when it clarifies intent)
\`\`\`

### Verification

#### Automated (run these):
- [ ] Tests pass: `<test command>`
- [ ] Type checking passes: `<typecheck command>`
- [ ] Linting passes: `<lint command>`

#### Manual (human confirms):
- [ ] <Observable behaviour to verify>
- [ ] <Edge case to test>

> After automated verification passes, pause for manual confirmation before proceeding to the next phase.

---

## Phase 2: <Descriptive Name>

<Same structure>

---

## Testing Strategy

- <What to test>
- <Key edge cases>
- <Integration scenarios>

## References

- Research doc: `docs/research/<file>.md`
- Related files: `path/to/key/file.ext`
```

### Step 5: Review and iterate

Present the plan location and ask for review:

```
Plan created at: `docs/plans/YYYY-MM-DD-description.md`

Please review:
- Are the phases properly scoped?
- Are the verification steps specific enough?
- Any missing edge cases?
```

Iterate until the user is satisfied. The plan should have **no open questions** — every decision must be resolved before finalising.

## Guidelines

- **Be skeptical**: Question vague requirements, identify risks early, don't assume.
- **Be interactive**: Don't write the full plan in one shot. Get buy-in at each step.
- **Be thorough**: Include file:line references, measurable success criteria, both automated and manual verification.
- **Be practical**: Focus on incremental, testable changes. Think about rollback.
- **No open questions in the final plan**: If something is unresolved, stop and ask. The plan must be complete and actionable.
