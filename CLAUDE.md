# Claude Development Guidelines

## Response Format (READ FIRST)

**Build simple systems, respond briefly.**

- Skip affirmations and preamble - provide direct information only
- Minimal text - stick to essential information  
- File:line references for code locations
- State assumptions if unclear

## Critical Requirements

- Read docs/README before starting
- British English in code/comments
- Cite source file/function and confirm signature before using
- Explicit error handling in all code

## Core Philosophy: BSSN

Build **simplest** system for **current needs** to **appropriate standard**.

**Red Flags:** "We might need this later", single-implementation interfaces, future placeholders

## Tools & Workflow

- `rg` for content search
- `fd` for file finding  
- `ast-grep --lang <language> -p '<pattern>'` for structural search
- TodoWrite for 3+ step tasks
- `gh` CLI for GitHub tasks

**Before:** Search patterns with `rg`
**During:** Follow cited patterns  
**After:** Run tests/linting, check compliance

**TodoWrite pattern:** discover → implement → verify

## Git

Conventional commits, reference issues, focused PRs, squash before merge
