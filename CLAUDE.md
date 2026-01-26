# Personal LLM Collaboration Guide

Purpose: Machine-readable instructions for Claude Code.
Scope: Global defaults for all projects (from `~/.claude/CLAUDE.md`).
Precedence: Project-level CLAUDE.md overrides this file when they conflict.
Mode: Human architects, agent implements.

## Spec-Driven Development

The human provides specifications; the agent executes against them.

- **Specifications are the contract**
  - Follow PRDs, implementation plans, and task lists exactly—don't reinterpret or expand scope
  - When specs are absent: ask for them if blocking, otherwise propose a minimal inline spec and proceed
    - Format: `Assuming: [behavior]. Proceeding unless you object.`
  - When requirements are unclear, ask immediately via AskUserQuestion—don't guess
  - Placeholders (TODOs, stubs, NotImplementedError) are valid when full implementation is blocked or out of scope—track them explicitly
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

- **Plan before non-trivial work** — use EnterPlanMode for multi-file changes or design decisions; skip for single-file fixes and well-specified tasks
- **Track multi-step work** — use TaskCreate/TaskUpdate for complex tasks; skip for simple requests
- **Explore via agents** — use Task tool with Explore agent for codebase questions instead of repeated Glob/Grep
- **Commit logically** — one logical unit per commit using Conventional Commits (`type(scope): description`); types: feat, fix, refactor, test, docs, chore

## Error Handling

- **Fail fast** — surface errors early; don't mask with fallbacks
- **Log actionable context** — include what failed and relevant identifiers, not just the error message
- **Validate at boundaries** — check external input (user input, API responses, file contents); trust internal code
- **Use typed errors** — prefer specific error types over generic exceptions or string messages
- **Diagnose before proceeding** — when tests fail or builds break, investigate first; don't silently skip broken steps

## Risk Boundaries

**Ask before:**
- Data deletion/truncation, destructive migrations, destructive git operations
- Network calls to unfamiliar external services (analytics, third-party APIs not in existing code)
- Mass file operations that can't be easily undone

**Proceed without asking:**
- Dependency installs, additive migrations, file creation/reorganization
- Running tests, builds, dev servers
- Network calls to: localhost, package registries (npm, PyPI, crates.io, etc.), GitHub/GitLab raw files, documentation sites

