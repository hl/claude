# Personal LLM Collaboration Guide

Purpose: Machine-readable instructions for Claude Code.
Scope: Global defaults for all projects (from `~/.claude/CLAUDE.md`).
Precedence: Direct prompts > project `CLAUDE.md` > this file.
Mode: Human architects, agent implements.

## Spec-Driven Development

The human provides specifications; the agent executes against them.

- **Specifications are the contract**
  - Follow PRDs, implementation plans, and task lists exactly—don't reinterpret or expand scope
  - When specs are absent, request them or propose a minimal spec for approval
  - Mark unclear requirements with `[NEEDS CLARIFICATION]` and ask immediately
- **Project principles constrain decisions**
  - Respect architectural constraints from project CLAUDE.md (e.g., "no new dependencies")
  - When principles conflict with a task, surface the conflict—don't silently violate
- **Test-first development**
  - Tests precede or accompany implementation
  - Tests validate spec compliance, not just code correctness
  - Missing test coverage is a spec gap—flag it
- **Validate and report**
  - After implementation, verify deliverables match the specification
  - Flag deviations, scope changes, or discovered requirements
  - Document assumptions visibly when proceeding despite ambiguity

## Workflow

- **Use TodoWrite aggressively**
  - Break work into discrete, trackable steps
  - Update status as you progress; create new todos when discovering work
- **Placeholders are legitimate**
  - TODOs, stubs, and NotImplementedError are valid intermediate states
  - Track them and resolve in subsequent commits
  - Commit incomplete work if it represents logical progress
- **Commit logically and frequently**
  - Each commit should represent coherent progress, not "complete features"
  - Use Conventional Commits: `type(scope): description`
  - Types: feat, fix, refactor, test, docs, chore
  - Include rationale: why this approach, alternatives considered, known issues
  - Reference issue/PR numbers when provided in context
- **Handle failures explicitly**
  - When tests fail or builds break, diagnose before proceeding
  - When specs contradict each other, surface the conflict immediately
  - Don't silently skip broken steps—report and propose a path forward

## Risk Boundaries

**Ask before:**
- Data deletion/truncation, destructive git operations (force push, rebase on shared branches)
- Network calls to external services not required for the current task
- Mass file operations that can't be easily undone

**Proceed without asking:**
- Dependency installs, schema migrations, file creation/reorganization
- Running tests, builds, dev servers
- Network calls required for the task (package registries, fetching docs, localhost)
