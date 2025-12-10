# Personal LLM Collaboration Guide

Purpose: Machine-readable instructions for Claude Code.
Scope: Global defaults for all projects (from `~/.claude/CLAUDE.md`).
Precedence: Direct prompts > project `CLAUDE.md` > this file.
Mode: Spec-Driven Development with agent execution (human architects, agent implements).

## Spec-Driven Development (SDD)

The human provides specifications as the source of truth; the agent executes against them.

- **Specifications drive implementation**
  - PRDs, implementation plans, and task lists are the contract
  - When specs exist, follow them—don't reinterpret or expand scope
  - When specs are absent, request them or propose a minimal spec for approval
- **Project principles constrain decisions**
  - Respect project-level architectural constraints (e.g., "no new dependencies", "all APIs must be versioned")
  - When principles conflict with a task, surface the conflict—don't silently violate
  - Principles live in project CLAUDE.md or equivalent; this file provides defaults
- **Explicit uncertainty handling**
  - Mark unclear requirements with `[NEEDS CLARIFICATION]` and ask
  - Do not infer intent—surface gaps in specifications immediately
  - Document assumptions visibly when proceeding despite ambiguity
- **Test-first development**
  - Tests precede or accompany implementation, not follow it
  - Tests validate spec compliance, not just code correctness
  - Missing test coverage is a spec gap—flag it
- **Validate implementation against spec**
  - After implementation, verify deliverables match the specification
  - Flag deviations, scope changes, or discovered requirements
  - Specs may be updated based on implementation learnings (with approval)
- **Report decisions transparently**
  - Explain rationale in commit messages
  - Note alternative approaches considered
  - Call out any technical debt or shortcuts taken

## Core Principles

- Placeholders are legitimate workflow tools
  - TODOs, stubs, and NotImplementedError are valid intermediate states
  - Track them using TodoWrite tool and resolve in subsequent commits
  - Commit incomplete work if it represents logical progress
  - Mark clearly what's incomplete and what remains to be done
- Ask before genuinely risky operations
  - Data deletion/truncation, destructive git operations (force push, rebase on shared branches)
  - External network calls (APIs, web scraping, etc.)
  - Mass file operations that can't be easily undone
- Normal development operations don't require asking
  - Dependency installs, schema migrations (forward-compatible), file creation/reorganization
  - Running tests, builds, or dev servers
  - Local network access for development purposes

## Agent-Driven Workflow

- Use TodoWrite aggressively for self-tracking
  - Break work into discrete, trackable steps
  - Update status as you progress
  - Create new todos when discovering additional work
- Commit logically and frequently
  - Each commit should represent coherent progress
  - Don't wait for "complete features"—commit working increments
  - Use conventional commit style with clear rationale
- Run tests to validate changes
  - Test before and after changes when a test suite exists
  - Create tests if they don't exist and would catch regressions
  - Report test results in commit messages

## Planning

- **When specs/PRDs are provided**: Execute against them; use plan mode only if implementation approach is unclear
- **When specs are absent**:
  - For complex features: request a spec or propose one for approval before implementation
  - For well-defined tasks: proceed directly
  - For unclear scope: ask for clarification before planning

## Commits (autonomous operation)

- Use Conventional Commits style
  - Format: `type(scope): description`
  - Types: feat, fix, refactor, test, docs, chore
- For multi-line messages, write to a file and use `git commit -F <file>`
- Include rationale and context
  - Why this approach was chosen
  - What alternatives were considered
  - Any incomplete work or known issues
  - Link to issue/PR numbers when available
