---
name: spec
description: Guides feature development through design (plan mode), task creation, implementation, and technical documentation. Use when implementing features with full documentation and review cycles.
---

# Feature Development Workflow

Project instructions override these defaults — testing policy, CI requirements, and phase behavior.

## Complexity Classification

Assess automatically — do not ask user. Use the highest matching level.

**Feature Complexity** (determines Phase 1 depth):

| Level | Criteria | Design Review |
|-------|----------|---------------|
| Trivial | 1 file, <30 lines, no new interfaces | Skip Phase 1 |
| Simple | 1-3 files, <100 lines, existing patterns | 1 cycle (opus), no Codex |
| Medium | 3-6 files, 100-300 lines, minor new patterns | 2 cycles (opus), Codex |
| Complex | 6+ files OR >300 lines OR new architecture | 3 cycles (opus), Codex |

**Task Complexity** (determines Phase 3 code review depth):

| Level | Criteria | Code Review |
|-------|----------|-------------|
| Trivial | 1 file, <20 lines, no new functions | Skip |
| Simple | 1-2 files, <50 lines | 1 cycle + self-verify |
| Complex | 3+ files OR >50 lines OR new APIs | 2 cycles |

## Pre-Workflow

Before Phase 1:
1. Discover project CI checks
2. Classify feature complexity
3. Scan the original prompt for a GitHub issue reference
4. Check GitHub availability — all three must be true: `gh auth status` succeeds, `git remote get-url origin` returns a URL, and that URL is a GitHub host

Store the issue reference (or none) and GitHub status (available/unavailable) — they will be written into the plan file so they survive a context clear.

## Phase 1: Design (Plan Mode)

Skip for Trivial complexity. Call EnterPlanMode, write design in plan file.

**Plan file structure** — in this order:

**Metadata** (first line, written from Pre-Workflow findings):
```
Issue: <URL or none> | GitHub: <available|unavailable>
```

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

**Review process**:
1. Launch `general-purpose` subagent (opus) to critique
2. Iterate up to the cycle limit from the Complexity table
3. Codex review (Medium+ only): call `mcp__codex__codex` with the plan file content as the prompt, single pass, no iteration. Only skip if the tool returns an error — proceed without in that case.
4. ExitPlanMode for user approval. If user rejects, revise and repeat from step 1.

## GitHub Issue Sync

Run after user approves the plan, before Phase 2. Use `gh` CLI (never delegate MCP calls). Use the issue reference detected in Pre-Workflow.

**If GitHub unavailable**: skip this step. The plan file is the record. Continue to Phase 2.

**If issue found**: Add the approved plan as a new comment:
```
gh issue comment <number> --body "<plan-markdown>"
```

**If no issue found**:
1. Create a new issue — title from feature name, body from the feature description in the prompt:
   ```
   gh issue create --title "<feature name>" --body "<feature description>"
   ```
2. Add the approved plan as a comment to the new issue.

**Plan comment format**: Markdown with a `## Design Plan` header followed by the full plan file content.

Store the issue URL — include it in commit messages and PR descriptions throughout Phases 3–5.

## Phase 2: Task Creation

1. **Documentation task**: "Write documentation for [feature]" (new) or "Update documentation for [feature]" (extending or modifying existing).
2. **Implementation tasks**: Atomic units ordered by dependencies.
3. **Set dependencies**: Documentation task blocked by all implementation tasks.

**Documentation skip**: If all true — <50 lines, 1-2 files, no new APIs/architecture — mark documentation task as "will skip". Phase 4 checks this flag.

## Phase 3: Implementation

For each task: mark in_progress → write tests → implement → refactor while green → run CI checks → code review → commit → mark completed.

**Testing**: Follow project testing policy. Default: TDD for business logic, algorithms, APIs; skip for config, docs, styling, trivial fixes.

**CI checks**: Run whatever the project defines (linting, type checking, compilation, test suite). Fix failures before proceeding.

**Code review**:
- Trivial: Skip
- Simple: 1 cycle with `pr-review-toolkit:code-reviewer` (sonnet) → self-verify → commit
- Complex: Up to 2 cycles; CRITICAL issues (security, logic, broken functionality) must be fixed; ADVISORY issues (style, minor optimizations) are optional

At cycle limit with unresolved criticals: AskUserQuestion with options: (a) fix and do another cycle, (b) document and proceed, (c) pause and discuss.

Test failures: Fix before committing.

**Tracking deferrals**: Whenever an ADVISORY issue is skipped, a trade-off is accepted, or out-of-scope work is discovered, append it to Part C of the plan file immediately. Do not rely on memory.

**Fundamental flaws mid-implementation**: Stash current work, mark task pending. AskUserQuestion with options: (a) revert completed tasks and redesign, (b) fix forward, (c) pause and discuss.

## Phase 4: Documentation

Execute the documentation task from Phase 2.

**Skip if** marked "will skip". Mark completed with skip reason.

**Write documentation**: Launch `general-purpose` subagent (sonnet) with feature name, key decisions, files implemented, and the spec template below. Location: `docs/specs/<feature-name>.md` unless the project has an established pattern.

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

Sections to include where applicable: data structures/types, key operations, algorithms/protocols, error handling, performance characteristics, configuration. Omit sections with nothing to say.

Commit: `docs(spec): add specification for [feature-name]` or `docs(spec): update specification for [feature-name]`.

## Phase 5: Deferred Triage

Read Part C of the plan file. Collect all deferred items from Phase 1 and any appended during Phase 3.

**If no deferred items**: workflow complete.

**If deferred items exist**:
- GitHub available: create one issue per item (do not batch):
  ```
  gh issue create --title "<item title>" --body "<what it is, why deferred, link to parent issue>"
  ```
  Then post a comment on the parent issue listing all new follow-up issues with one-line summaries.
- GitHub unavailable: append to `deferred.md` in the same directory as specs (create if absent) with feature name, date, and one entry per item.

## Subagent Strategy

| Purpose | Type | Model |
|---------|------|-------|
| Design review | `general-purpose` | opus |
| Code review | `pr-review-toolkit:code-reviewer` | sonnet |
| Documentation writing | `general-purpose` | sonnet |

Never delegate: MCP calls.

## Phase Checklist

- **Phase 1 → 2**: No critical design issues, Codex complete (or skipped), user approved, GitHub Issue Sync complete (or skipped — GitHub unavailable)
- **Phase 2 → 3**: All tasks created, documentation task has correct dependencies
- **Phase 3 → 4**: All implementation tasks completed, CI checks pass
- **Phase 4 → 5**: Documentation committed (or skip documented)
- **Phase 5 done**: Deferred items posted to GitHub issues or appended to `deferred.md` alongside specs (or list is empty)

## Usage

```
/spec add user authentication with OAuth2
/spec update the authentication module to support MFA
```
