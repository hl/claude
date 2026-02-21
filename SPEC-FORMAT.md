# Spec File Format

## Overview

Spec files live in `docs/specs/` and define **what** needs to be built. They are the single source of truth for a unit of work. Claude reads these files to understand intent, scope, and acceptance criteria before implementation begins.

Spec files are written collaboratively between you and Claude using the `write-spec` skill. They are consumed by Claude using the `implement-spec` skill.

## File naming

Files follow the pattern `docs/specs/<component-name>.md`. The component name should be descriptive and lowercase with hyphens. For example: `docs/specs/user-authentication.md`, `docs/specs/invoice-pdf-export.md`.

## Format

Every spec file uses the following structure. All sections are required unless marked optional.

```markdown
# <Component Name>

## Purpose

A short paragraph explaining what this component does and why it exists. This is the
high-level intent. A developer reading only this section should understand the goal.

## Requirements

A numbered list of testable requirements. Each requirement describes observable behaviour
from the perspective of the system or its users. Requirements should be specific enough
to write a test against, but should not prescribe implementation details.

1. The system does X when Y happens.
2. If condition A is true, the system responds with B.
3. The component exposes an interface that allows Z.

## Constraints

Conditions that must hold true but are not functional requirements. These include
performance expectations, compatibility needs, security considerations, and boundaries
on what the component should not do.

- Must not introduce new dependencies beyond what is already in the project.
- Response time must remain under 200ms for the common case.
- Must work with the existing database schema without migrations.

## Dependencies

Other specs, modules, or external systems this component depends on or integrates with.
Reference other spec files where they exist.

- Depends on `docs/specs/user-session.md` for session management.
- Integrates with the existing `Accounts` context.
- Requires the Stripe API (already configured in the project).

## Acceptance Criteria

A checklist of concrete, verifiable outcomes that define when this work is done. These
are written as pass/fail checks. When all boxes can be ticked, the spec is implemented.

- [ ] All requirements have corresponding tests that pass.
- [ ] Existing tests continue to pass.
- [ ] The component is documented in the codebase (moduledoc / function docs).
- [ ] No compiler warnings are introduced.

## Notes (optional)

Any additional context, open questions, or design considerations that informed the spec.
This section is a scratchpad for things that don't fit elsewhere. It may include
references to external documentation, links to related discussions, or alternative
approaches that were considered and rejected.

## Decisions (optional, filled during implementation)

Architectural or design decisions made during implementation that future readers should
understand. This section is empty when the spec is first written and gets populated
as Claude works through the implementation.

- Chose GenServer over Agent because state needs to survive process restarts.
- Used ETS for caching rather than adding Redis, keeping the dependency footprint small.
```

## Principles

- **What, not how.** Specs describe behaviour and outcomes. Implementation details belong in the code.
- **Testable.** Every requirement should be verifiable. If you can’t write a test for it, it’s too vague.
- **Scoped.** A spec covers one coherent unit of work. If it’s doing two unrelated things, split it.
- **Living.** The Decisions section gets updated during implementation. The spec remains useful documentation after the work is done.
- **Minimal.** Don’t add sections or ceremony beyond what’s needed. The format above is a ceiling, not a floor. Small components might only need Purpose, Requirements, and Acceptance Criteria.