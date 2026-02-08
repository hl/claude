---
name: spec
description: Guides spec-driven development through design (plan mode), task creation, implementation, and technical specification writing. Use when implementing features with full documentation and review cycles.
---

# Spec-Driven Development Workflow

Design in plan mode, implement with task tracking, deliver a technical specification.

## Complexity Classification

Assess automatically — do not ask user. Use highest matching criterion.

**Feature Complexity** (determines Phase 1 depth):

| Level | Criteria | Design Review |
|-------|----------|---------------|
| Trivial | 1 file, <30 lines, no new interfaces | Skip Phase 1 |
| Simple | 1-3 files, <100 lines, existing patterns | 1 cycle (sonnet), no Codex |
| Medium | 3-6 files, 100-300 lines, minor new patterns | 2 cycles (opus), Codex |
| Complex | 6+ files OR >300 lines OR new architecture | 3 cycles (opus), Codex, or Agent Team |

**Task Complexity** (determines Phase 3 depth):

| Level | Criteria | Code Review |
|-------|----------|-------------|
| Trivial | 1 file, <20 lines, no new functions | Skip |
| Simple | 1-2 files, <50 lines | 1 cycle + self-verify |
| Complex | 3+ files OR >50 lines OR new APIs | 2 cycles |

## Pre-Workflow

Before EnterPlanMode: search existing specs, note spec location convention, check test infrastructure, classify complexity.

**TDD scope**: Business logic, algorithms, APIs. Skip tests for config, docs, styling, trivial fixes. Phase 3 references this — "write tests (if appropriate)" means: apply TDD scope.

## Phase 1: Design (Plan Mode)

Skip for Trivial complexity. Call EnterPlanMode, write design in plan file.

**Design structure**:
- Part A (What): Context, Decision, Consequences, Alternatives
- Part B (How): Scope, API/interface, Architecture, Data model, Error handling, Dependencies, Testing

**Review process**:
1. Launch `general-purpose` subagent (see Subagent Strategy for model) to critique
2. Iterate up to cycle limit
3. Codex review (Medium+ only): single pass, no iteration
4. ExitPlanMode for user approval. If user rejects, revise design and repeat from step 1.

Codex unavailable or fails: Ask user whether to retry once or proceed without.

## Phase 2: Task Creation

1. **Spec task**: "Write specification for [feature]" (new) or "Update specification for [feature]" (extending/modifying existing spec). If feature partially overlaps an existing spec, update the existing one.
2. **Implementation tasks**: Atomic units resulting in working code, ordered by dependencies
3. **Set dependencies**: Spec task blocked by all implementation tasks

**Spec skip evaluation**: If all true — <50 lines, 1-2 files, no new APIs/architecture — mark spec task description as "will skip". Phase 4 checks this flag rather than re-evaluating.

## Phase 3: Implementation

For each task: mark in_progress → write tests (if appropriate) → implement → refactor while green → code review (per task complexity) → commit → mark completed.

**Code review**:
- Trivial: Skip
- Simple: 1 cycle with `pr-review-toolkit:code-reviewer` (sonnet) → self-verify → commit
- Complex: Up to 2 cycles; CRITICAL issues (security, logic, broken functionality) must be fixed; ADVISORY issues (style, minor optimizations) are optional

At cycle limit with unresolved criticals: AskUserQuestion with options.

Test failures: Fix before committing.

**Fundamental flaws discovered mid-implementation**: Stash current work, mark task pending. If completed tasks are affected by the flaw, note which tasks need revisiting. AskUserQuestion with options: (a) revert completed tasks and redesign, (b) fix forward from current state, (c) pause and discuss.

## Phase 4: Specification

Execute spec task created in Phase 2.

**Skip if** spec task was marked "will skip" in Phase 2. Mark completed with skip reason.

**Write spec**: Launch `general-purpose` subagent (sonnet) with feature name, key decisions, files implemented, instruction to match existing format. Location: follow existing pattern or `docs/specs/`.

Minimum sections: Header (name, date created, date updated, status), Overview. Add API/Interface if public interface exists. Set dates to current date on creation; update "date updated" on modifications.

Updates: Modify in place, add to Change History. Major architectural changes: new spec, mark old as superseded.

Commit: `docs(spec): add specification for [feature-name]`

## Subagent Strategy

| Purpose | Type | Model |
|---------|------|-------|
| Design review | `general-purpose` | opus (sonnet for Simple) |
| Task exploration | `Explore` | haiku |
| Code review | `pr-review-toolkit:code-reviewer` | sonnet |
| Spec writing | `general-purpose` | sonnet |
| Design review (Complex) | Agent team | opus (alternative to sequential) |
| Parallel impl (Complex) | Agent team | sonnet per teammate |

Never delegate: MCP calls.

## Agent Teams (Complex Only)

Use when: Complex classification AND 3+ independent modules with clear file boundaries. Teams use 3-5x tokens — only use when parallelism provides clear benefit.

**How teams work**: Lead spawns teammates, each with own context. Teammates message each other directly and coordinate via shared task list. Lead synthesizes results.

**Preflight** — Before spawning teammates:

*Phase 1 (Design review):*
1. Explore feature requirements and existing codebase structure
2. Identify key architectural areas: data model, API surface, error handling, testing, dependencies
3. Map specific file sets to each review perspective
4. Spawn teammates with explicit scope: "Review data model in [files X,Y,Z]", "Review API contracts in [files A,B,C]", etc.

*Phase 3 (Parallel implementation):*
1. Analyze Phase 2 tasks and identify file boundaries
2. Map tasks to distinct file sets with minimal overlap
3. Identify shared interfaces/contracts between boundaries
4. Spawn teammates with explicit ownership: "Own [files X,Y], read-only [file Z for context], coordinate on [shared interface in file W]"

Result: No duplicate exploration, clear boundaries, fewer conflicts.

**Phase 1 alternative** — Design review team:
Spawn teammates with distinct perspectives (architecture, API/interface, devil's advocate). Teammates debate and challenge each other's findings. Lead synthesizes. One team iteration replaces 2-3 sequential subagent cycles.

**Phase 3 alternative** — Parallel implementation:
When tasks map to independent file sets (e.g., frontend/backend/tests), spawn implementation team. Each teammate owns specific files — no overlap. Use delegate mode (Shift+Tab) to restrict lead to coordination only. Lead coordinates merging and resolves cross-cutting concerns.

**Conflict resolution**: If teammates produce conflicting approaches or interface mismatches: (1) lead identifies the conflict, (2) lead decides resolution based on the approved design, (3) affected teammate revises. If the conflict reveals a design gap, pause implementation and escalate to user.

**When NOT to use**: Same-file edits, sequential dependencies, Simple/Medium complexity.

## Quality Gates

- **Phase 1 → 2**: No critical design issues, Codex complete (or skipped), user approved
- **Phase 2 → 3**: All tasks created, spec task has correct dependencies
- **Phase 3 → 4**: All implementation tasks completed, tests pass
- **Phase 4 done**: Spec accurate (or skip documented), all tasks completed

## Usage

```
/spec add user authentication with OAuth2
/spec update the authentication module to support MFA
```
