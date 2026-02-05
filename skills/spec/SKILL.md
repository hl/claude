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
| Complex | 6+ files OR >300 lines OR new architecture | 3 cycles (opus), Codex |

**Task Complexity** (determines Phase 3 depth):

| Level | Criteria | Code Review |
|-------|----------|-------------|
| Trivial | 1 file, <20 lines, no new functions | Skip |
| Simple | 1-2 files, <50 lines | 1 cycle + self-verify |
| Complex | 3+ files OR >50 lines OR new APIs | 2 cycles |

## Pre-Workflow

Before EnterPlanMode: search existing specs, note spec location convention, check test infrastructure, classify complexity.

TDD for business logic/algorithms/APIs. Skip tests for config, docs, styling, trivial fixes.

## Phase 1: Design (Plan Mode)

Skip for Trivial complexity. Call EnterPlanMode, write design in plan file.

**Design structure**:
- Part A (What): Context, Decision, Consequences, Alternatives
- Part B (How): Scope, API/interface, Architecture, Data model, Error handling, Dependencies, Testing

**Review process**:
1. Launch `general-purpose` subagent (model per complexity) to critique
2. Iterate up to cycle limit
3. Codex review (Medium+ only): Call `mcp__codex__codex` directly — runs once, no iteration
4. ExitPlanMode for user approval

Codex failure: Ask user whether to retry once or proceed without.

## Phase 2: Task Creation

1. **Spec task first**: "Write specification for [feature]" or "Update specification for [feature]"
2. **Implementation tasks**: Atomic units resulting in working code, ordered by dependencies
3. **Set dependencies**: Spec task blocked by all implementation tasks

Evaluate spec skip threshold now: if <50 lines, 1-2 files, no new APIs/architecture — mark spec task as "will skip" in description.

## Phase 3: Implementation

For each task: mark in_progress → write tests (if appropriate) → implement → refactor while green → code review (per task complexity) → commit → mark completed.

**Code review**:
- Trivial: Skip
- Simple: 1 cycle with `pr-review-toolkit:code-reviewer` (sonnet) → self-verify → commit
- Complex: Up to 2 cycles; CRITICAL issues (security, logic, broken functionality) must be fixed; ADVISORY issues (style, minor optimizations) are optional

At cycle limit with unresolved criticals: AskUserQuestion with options.

Test failures: Fix before committing. Fundamental flaws: stash, mark pending, ask user.

## Phase 4: Specification

Execute spec task created in Phase 2.

**Skip if** (all true): <50 lines, 1-2 files, no new APIs/interfaces, no architectural decisions. Mark completed with skip reason.

**Write spec**: Launch `general-purpose` subagent (sonnet) with feature name, key decisions, files implemented, instruction to match existing format. Location: follow existing pattern or `docs/specs/`.

Minimum sections: Header (name, dates, status), Overview. Add API/Interface if public interface exists.

Updates: Modify in place, add to Change History. Major architectural changes: new spec, mark old as superseded.

Commit: `docs(spec): add specification for [feature-name]`

## Subagent Strategy

| Purpose | Type | Model |
|---------|------|-------|
| Design review | `general-purpose` | opus (sonnet for Simple) |
| Task exploration | `Explore` | haiku |
| Code review | `pr-review-toolkit:code-reviewer` | sonnet |
| Spec writing | `general-purpose` | sonnet |

Never delegate: MCP calls, parallel implementation.

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
