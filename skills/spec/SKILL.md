---
name: spec
description: Guides feature development through design (plan mode), task creation, implementation, and technical documentation. Use when implementing features with full documentation and review cycles.
---

# Feature Development Workflow

## Phase 1: Design (Plan Mode)

Skip for trivial changes (single file, small scope, no new interfaces). Call EnterPlanMode, write design in a plan file.

**Plan file structure** — in this order:

**Part A — Decision** (user-facing; keep tight):
- Context: why this is being built
- Decision: what we're doing, in one paragraph
- Consequences: what changes, what gets harder
- Alternatives: what was considered and rejected

**Part B — Implementation Notes** (agent-facing; written after Part A):
- Scope: files and boundaries
- API/interface: signatures, contracts
- Architecture: component structure and interactions
- Data model: shapes and types
- Error handling: failure modes and responses
- Dependencies: external or internal
- Testing: what to cover and how

**Part C — Deferred** (append during implementation):
- Items out of scope for this cycle. Each entry: what and why. May be empty; must not be omitted.

**Review**: Critique the design for soundness — depth proportional to complexity. Use an independent subagent critique for designs introducing new patterns or architecture. Iterate until no critical issues remain.

ExitPlanMode for user approval.

## Phase 2: Task Creation

1. **Implementation tasks**: Atomic units ordered by dependencies.
2. **Documentation task**: Add if the change warrants a spec (new APIs, architecture, non-obvious behavior). Blocked by all implementation tasks.

## Phase 3: Implementation

For each task: mark in_progress → write tests → implement → refactor while green → code review → commit → mark completed.

**Commit format**: `<type>(<scope>): <description>`

**Testing**: Follow project testing policy. Default: TDD for business logic, algorithms, APIs; skip for config, docs, styling, trivial fixes.

**Code review**: Review code before committing — depth proportional to task complexity. Use a subagent reviewer for non-trivial tasks.

**Tracking deferrals**: Whenever an advisory issue is skipped, a trade-off is accepted, or out-of-scope work is discovered, append it to Part C of the plan file immediately.

## Phase 4: Documentation

Skip if no documentation task was created in Phase 2. Otherwise, launch a subagent with feature name, key decisions, files implemented, full plan file content, and the spec template below. Location: `docs/specs/<feature-name>.md` unless the project has an established pattern.

Updates: modify in place. Major architectural changes: new doc, link from old one.

**Spec template**:

```markdown
# [Feature Name]

[1-2 sentence description of what this component does and why it exists. Link to related specs if relevant.]

## Overview

[What it does, how it fits in. Include a mermaid diagram for non-trivial flows.]

## [Section per major concept]

[Use tables for structured data (fields, operations, complexity). Use code blocks for data structures and examples. Call out invariants inline: **Invariant**: ...]

## Related Specifications

- [`other-spec.md`](other-spec.md) — [one-line description]
```

Sections to include where applicable: data structures/types, key operations, algorithms/protocols, error handling, performance characteristics, configuration.

Commit: `docs(spec): add specification for [feature-name]` or `docs(spec): update specification for [feature-name]`.

## Phase 5: Deferred Triage

Skip for trivial changes (no plan file was written). Otherwise, read Part C of the plan file and collect all deferred items.

**If deferred items exist**: append to `deferred.md` in the same directory as specs (create if absent) with feature name, date, and one entry per item.

