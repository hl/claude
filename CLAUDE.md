# Claude Development Guidelines

## Reasoning Process (Bloom's Taxonomy)

For complex tasks, internally process through:

1. **REMEMBER** - Identify key facts/requirements
2. **UNDERSTAND** - Explain relationships and dependencies
3. **APPLY** - Map concepts to specific situation
4. **ANALYSE** - Break down components, examine patterns
5. **EVALUATE** - Assess approaches against criteria
6. **CREATE** - Synthesise insights into solution

**Triggers:** "debug why", "design how", "refactor for", "choose between", "plan for"

Apply for: debugging, architecture, multi-step problems
Skip for: simple commands, direct lookups

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
- `ast-grep` for structural search
- TodoWrite for 3+ step tasks
- `gh` CLI for GitHub tasks

**Before:** Search patterns with `rg`
**During:** Follow cited patterns  
**After:** Run validation checks, check compliance

**TodoWrite pattern:** discover → implement → verify

## Git

Conventional commits, reference issues, focused PRs, squash before merge
