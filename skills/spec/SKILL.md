---
name: spec
description: Guides spec-driven development through design (plan mode), task creation, implementation, and technical specification writing. Use when implementing features with full documentation and review cycles.
---

# Spec-Driven Development Workflow

Design in plan mode, implement with task tracking, deliver a technical specification.

## Quick Reference

| Phase | Purpose | Key Actions |
|-------|---------|-------------|
| **Pre-workflow** | Context gathering | Search specs, check test infra, assess complexity |
| **Phase 1** | Design (plan mode) | Write design, subagent review, Codex review (Medium+), ExitPlanMode |
| **Phase 2** | Task creation | Create spec task FIRST, then implementation tasks, set dependencies |
| **Phase 3** | Implementation | TDD loop, code review per complexity, commit per task |
| **Phase 4** | Specification | Evaluate skip threshold, write/update spec, commit |

## Complexity Classification

Assess automatically — do not ask user.

### Feature Complexity (Phase 1 depth)

| Level | Criteria | Design Review |
|-------|----------|---------------|
| **Trivial** | 1 file, <30 lines, no new interfaces | Skip Phase 1 |
| **Simple** | 1-3 files, <100 lines, existing patterns | 1 cycle (sonnet), no Codex |
| **Medium** | 3-6 files, 100-300 lines, minor new patterns | 2 cycles (opus), Codex |
| **Complex** | 6+ files OR >300 lines OR new architecture | 3 cycles (opus), Codex |

Use highest matching criterion.

### Task Complexity (Phase 3 depth)

| Level | Criteria | Code Review |
|-------|----------|-------------|
| **Trivial** | 1 file, <20 lines, no new functions | Skip |
| **Simple** | 1-2 files, <50 lines | 1 cycle + self-verify |
| **Complex** | 3+ files OR >50 lines OR new APIs | 2 cycles |

## Operating Principles

- **MCP tools**: Call directly (e.g., `mcp__codex__codex`), never via subagent
- **Tasks**: Use TaskCreate/TaskUpdate/TaskList for all work
- **Commits**: After each completed task with working code
- **AskUserQuestion**: Only for genuine ambiguity; always provide recommended answer with reasoning
- **Risk boundaries**: Ask before data deletion, destructive git, external network calls
- **Review cycles**: Only full subagent invocations count toward limits; inline typo/formatting fixes don't count
- **Dependencies**: Check project CLAUDE.md for restrictions before adding new deps; surface conflicts

## Pre-Workflow Check

Before EnterPlanMode:
1. Search for existing specs related to feature/module
2. Determine spec location convention
3. Assess test infrastructure presence
4. Classify feature complexity

**Test appropriateness**: TDD for business logic, algorithms, APIs. Skip for config, docs, styling. None for trivial/typo fixes.

## Phase 1: Design (Plan Mode)

Call EnterPlanMode, then write design in plan file.

### Design Structure

**Part A — What**: Context, Decision, Consequences, Alternatives considered

**Part B — How**: Scope, API/interface, Architecture, Data model, Error handling, Dependencies, Testing approach

### Review Process

1. **Internal review**: Launch `general-purpose` subagent (model per complexity table) to critique design
2. **Iterate** up to cycle limit; use AskUserQuestion if stuck at limit
3. **Codex review** (Medium/Complex only): Call `mcp__codex__codex` directly with design content
   - CRITICAL feedback: Fix, self-review, proceed
   - ADVISORY feedback: Note for implementation
   - Codex runs exactly once — no iteration
4. **Exit**: Call ExitPlanMode for user approval

**Codex failure**: Report error, ask user whether to retry once or proceed without.

## Phase 2: Task Creation

### Step 1: Create Spec Task (REQUIRED — do this first)

Use TaskCreate. Choose "Write" or "Update" based on whether existing spec was found in pre-workflow check:
```
Subject: "Write specification for [feature]" or "Update specification for [feature]"
Description: Write/update spec. Skip threshold evaluated at execution (Phase 4).
```

### Step 2: Create Implementation Tasks

- Atomic tasks resulting in working code
- Reference specific design sections
- Order by dependencies
- Include documentation updates

### Step 3: Set Spec Task Dependencies

```
TaskUpdate: specTaskId, addBlockedBy: [all implementation task IDs]
```

### Verification

- [ ] Spec task exists and is blocked by all implementation tasks
- [ ] All implementation items have corresponding tasks
- [ ] Task count matches plan

**5+ tasks**: Ask user whether to continue sequentially or stop for parallel sessions.

## Phase 3: Implementation

For each task:

1. TaskUpdate → `in_progress`
2. Write tests (if appropriate)
3. Run tests (expect failure)
4. Implement minimum code
5. Refactor while green
6. Run full test suite
7. Code review (per task complexity)
8. Commit with descriptive message
9. TaskUpdate → `completed`

### Code Review Loop

**Trivial**: Skip entirely

**Simple**: 1 cycle with `pr-review-toolkit:code-reviewer` (sonnet) → fix critical issues → self-verify → commit

Self-verify checklist: (1) each critical issue addressed, (2) fixes don't add new control flow, (3) fixes match surrounding patterns, (4) tests pass. If concerns remain, AskUserQuestion rather than second subagent.

**Complex**: Up to 2 cycles with `pr-review-toolkit:code-reviewer` (sonnet)
- CRITICAL: Security, logic errors, broken functionality, missing error handling
- ADVISORY: Style, minor optimizations, unlikely edge cases

**At cycle limit with unresolved issues**: AskUserQuestion with options (proceed documented, different approach, guidance).

### Failure Handling

- Test failures: Fix or rethink; never commit failing tests
- Fundamental flaws: `git stash`, mark task pending, AskUserQuestion
- Interruption: Check TaskList, git status; resume or discard broken work

## Phase 4: Specification

Execute as final task (created in Phase 2). TaskUpdate → `in_progress` when starting, `completed` when done.

### Skip Threshold

Skip spec if ALL true:
- <50 lines changed
- 1-2 files affected
- No new APIs/interfaces
- No architectural decisions

Mark task completed with note: "Skipped: <50 lines, 2 files, no APIs/architecture."

### Writing the Spec

Launch `general-purpose` subagent (sonnet) with:
- Feature name and key decisions
- Files implemented
- Instruction to match existing spec format

**Location**: Follow existing pattern, or `docs/specs/` for greenfield.

**Minimum sections**: Header (name, dates, status), Overview. Add API/Interface if public interface exists.

### Post-Generation

- Read and verify accuracy
- Check required sections present
- Validate links to related specs
- Commit: `docs(spec): add specification for [feature-name]`

### Updates to Existing Specs

- Update in place (don't create new)
- Add to Change History with date
- For major architectural changes: create new spec, mark old as `superseded`

## Subagent Strategy

| Purpose | Type | Model |
|---------|------|-------|
| Design review | `general-purpose` | opus (sonnet for Simple) |
| Task preparation | `Explore` | haiku |
| Code review | `pr-review-toolkit:code-reviewer` | sonnet |
| Spec writing | `general-purpose` | sonnet |

**Never delegate**: MCP calls, parallel implementation

## Quality Gates

**Phase 1 → 2**: No critical design issues, Codex complete (or user-approved skip), user approved plan

**Phase 2 → 3**: All tasks created, spec task verified

**Phase 3 → 4**: All implementation tasks completed, tests pass, code review done

**Phase 4 done**: Spec accurate, commits descriptive

## Usage

```
/spec add user authentication with OAuth2
/spec update the authentication module to support MFA
```

## Precedence

1. User prompts (highest)
2. Project CLAUDE.md
3. Global CLAUDE.md
4. This skill

Surface conflicts rather than silently violate constraints.
