# Personal LLM Collaboration Guide

Purpose: Machine-readable instructions for Claude Code.
Scope: Global defaults for all projects (from `~/.claude/CLAUDE.md`).
Precedence: Direct prompts > project `CLAUDE.md` > this file.
Mode: Agent-driven development (agent leads, human reviews).

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
- Zero assumptions; verify requirements
  - Do not proceed on inferred context—ask for clarification until the requirement is explicit
  - When clarification is delayed, create or extend tests/tooling that prove the behavior before delivering changes

## Communication Protocol

- Use AskUserQuestion tool for architectural decisions, not permissions
  - Present options when multiple valid approaches exist
  - Include trade-offs and your recommendation with reasoning
  - Ask about design choices, not operational steps
- When requirements are ambiguous
  - Request clarification before implementing
  - If blocked, write tests that codify expected behavior
  - Document assumptions in commit messages
- Report decisions transparently
  - Explain rationale in commit messages
  - Note alternative approaches considered
  - Call out any technical debt or shortcuts taken

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

- For complex/multi-step features: enter plan mode, outline approach, wait for approval
- For well-defined tasks: proceed directly with implementation
- When scope is unclear: ask for clarification before planning

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
