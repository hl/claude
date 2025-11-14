# Personal LLM Collaboration Guide

Purpose: Machine-readable instructions for the agent working in this repo.
Scope: Repo-wide unless overridden by nested `AGENTS.md` files.
Precedence: Direct user/developer prompts override this file.

## Core Principles

- Personal rule: No placeholder code
  - Do not add stubs, TODO/FIXME, or NotImplementedError-style placeholders
  - Implement functions fully; avoid hardcoded dummy values
  - If requirements are unclear, ask before adding code
- Ask before destructive or irreversible actions
  - Examples: deleting/moving many files, `git reset`/history changes, schema/data migrations, dependency installs, network access, long-running tasks (> ~2 min), writing outside the workspace
- Minimal diffs and tight scope
  - Change only what's necessary; don't refactor unrelated code
  - Keep naming/style consistent with the existing codebase
- Zero assumptions; verify requirements
  - Do not proceed on inferred context—ask for clarification until the requirement is explicit.
  - When clarification is delayed, create or extend tests/tooling that prove the behaviour before delivering changes.

## Communication Protocol

- When uncertain or there are multiple approaches
  - List options with trade-offs, recommend one, and pause for confirmation unless clearly trivial
- When context is missing
  - Stop and request the needed details; only continue once questions are answered or verification code/tests are in place.

## Output Preferences

- Be concise; prefer short bullet lists
- Show exact file paths, commands, and identifiers in backticks
- Before editing, state intent and scope; after editing, summarise what changed and why
- Do not dump large file contents; reference paths unless I ask
- Avoid heavy formatting unless requested

## Validation Preferences

- Propose validation steps up front
  - Start with targeted checks (unit tests for changed modules), then broader suites
  - If local validation isn't possible, provide exact commands for me to run
- Do not install dependencies or use the network without explicit approval

## Commits (only when I ask)

- Do not commit or push unless I explicitly request it
- If I ask you to craft a commit
  - Use Conventional Commits style
  - For multi-line messages, write to a file and use `git commit -F <file>`
  - Include a concise rationale and link issue/PR numbers when provided
