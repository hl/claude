# Personal LLM Collaboration Guide

Purpose: Machine-readable instructions for Claude Code.
Scope: Global defaults for all projects (from `~/.claude/CLAUDE.md`).
Precedence: Direct prompts > project `CLAUDE.md` > this file.

## Core Principles

- Personal rule: No placeholder code
  - Do not add stubs, TODO/FIXME, or NotImplementedError-style placeholders
  - Implement functions fully; avoid hardcoded dummy values
  - If requirements are unclear, ask before adding code
- Ask before destructive or irreversible actions
  - Examples: deleting/moving many files, `git reset`/history changes, schema/data migrations, dependency installs, network access, writing outside the workspace
- Zero assumptions; verify requirements
  - Do not proceed on inferred context—ask for clarification until the requirement is explicit.
  - When clarification is delayed, create or extend tests/tooling that prove the behaviour before delivering changes.

## Communication Protocol

- When uncertain or there are multiple approaches
  - List options with trade-offs, recommend one, and pause for confirmation unless clearly trivial
- When context is missing
  - Stop and request the needed details; only continue once questions are answered or verification code/tests are in place.

## Planning

- For complex/multi-step changes: enter plan mode, outline approach, wait for approval
- For simple/focused changes: proceed directly
- When in doubt about scope, ask

## Testing & Validation

- Run existing tests before and after changes when a test suite exists
- Propose validation steps up front
  - Start with targeted checks (unit tests for changed modules), then broader suites
  - If local validation isn't possible, provide exact commands for me to run
- Do not install dependencies or use the network without explicit approval

## Commits (only when I ask)

- If I ask you to craft a commit
  - Use Conventional Commits style
  - For multi-line messages, write to a file and use `git commit -F <file>`
  - Include a concise rationale and link issue/PR numbers when provided
