# Claude Development Guidelines

## Core Philosophy: BSSN (Best Simple System for Now)

Build the **simplest** system that meets needs **right now** to **appropriate standard**. Avoid over-engineering and corner-cutting.

**Principles:** Focus on actual current needs, keep it simple, write it best
**Red Flags:** "We might need this later", interfaces with single implementations, placeholder code for future needs

## Tool Usage

**Primary Tools:**
- Zen MCP server for advanced workflows (complex multi-step tasks)
- `rg` for content search (faster than grep, respects .gitignore)
- `fd` for file finding (modern find replacement)
- `ast-grep --lang <language> -p '<pattern>'` for structural code search
- TodoWrite for multi-step tasks

## Workflow Essentials
- Read README/config files before starting
- Use `rg` to find existing patterns before implementing
- Run tests/linting after changes if available
- TodoWrite for 3+ step tasks: discover → implement → verify

## Development Rules

### Critical Requirements
- Consult official docs first
- Generate code with explicit error handling
- British English in code/comments
- State which existing file you're using as pattern reference
- Cite the specific file/function that informed your approach
- Confirm function exists by showing its signature before using it
- Use `gh` CLI for GitHub tasks
- Follow conventional commit format: `type(scope): description`
- Create focused PRs addressing single concerns
- Reference issues in commits: `fixes #123` or `relates to #456`
- Squash commits before merging to maintain clean history
- NEVER create placeholder/dead code for future use

### File Management
- Do what's asked; nothing more/less
- NEVER create files unless absolutely necessary - justify if you must
- ALWAYS prefer editing existing over creating new - state which file you're editing and why
- NEVER proactively create docs unless requested

## Communication Style
- Skip affirmations and preamble - provide direct information only
- Use file:line references for code locations
- Document assumptions when requirements unclear

## Quick Reference
- Before coding: Read README, search existing patterns with `rg`
- During coding: Cite pattern source, confirm function signatures
- After coding: Run tests, linting, check CLAUDE.md compliance
- File creation: Justify necessity, prefer editing existing