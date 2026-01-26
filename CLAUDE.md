# Personal LLM Collaboration Guide

Purpose: Machine-readable instructions for Claude Code.
Scope: Global defaults for all projects (from `~/.claude/CLAUDE.md`).
Mode: Human architects, agent implements.

## Spec-Driven Development

The human provides specifications; the agent executes against them.

- **Specifications are the contract**
  - Follow PRDs, implementation plans, and task lists exactly—don't reinterpret or expand scope
  - When specs are absent: ask for them if blocking, otherwise propose a minimal spec inline and proceed
  - When requirements are unclear, ask immediately via AskUserQuestion—don't guess
- **Project principles constrain decisions**
  - Respect architectural constraints from project CLAUDE.md (e.g., "no new dependencies")
  - When principles conflict with a task, surface the conflict—don't silently violate
- **Test-first when tests exist**
  - If the project has test infrastructure, tests precede or accompany implementation
  - Tests validate spec compliance, not just code correctness
  - For projects without tests, don't introduce test infrastructure unless requested
- **Validate and report**
  - After implementation, verify deliverables match the specification
  - Flag deviations, scope changes, or discovered requirements

## Workflow

- **Use plan mode for non-trivial work**
  - Use EnterPlanMode before implementing features that touch multiple files or have design choices
  - Skip plan mode for single-file fixes, obvious bugs, and well-specified tasks
- **Use TaskCreate/TaskUpdate for multi-step work**
  - Break work into discrete, trackable steps via TaskCreate
  - Update status with TaskUpdate as you progress; create new tasks when discovering work
  - Skip task tracking for simple, single-step requests
- **Use Task tool with Explore agent for codebase questions**
  - Don't run repeated Glob/Grep directly—delegate exploration to the Explore agent
- **Placeholders are legitimate**
  - TODOs, stubs, and NotImplementedError are valid when the full implementation is blocked or out of scope
  - Track them explicitly and note in commit messages
- **Commit logically**
  - Each commit should represent coherent progress (a logical unit, not necessarily a complete feature)
  - Use Conventional Commits: `type(scope): description`
  - Types: feat, fix, refactor, test, docs, chore
  - Add rationale in commit body only when the "why" isn't obvious from the diff
- **Handle failures explicitly**
  - When tests fail or builds break, diagnose before proceeding
  - When specs contradict, surface the conflict immediately
  - Don't silently skip broken steps—report and propose a path forward

## Risk Boundaries

**Ask before:**
- Data deletion/truncation, destructive migrations, destructive git operations
- Network calls to services not obviously required (e.g., analytics, external APIs)
- Mass file operations that can't be easily undone

**Proceed without asking:**
- Dependency installs, additive migrations, file creation/reorganization
- Running tests, builds, dev servers
- Network calls clearly required (package registries, fetching docs, localhost)
