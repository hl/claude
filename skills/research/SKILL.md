---
name: research
description: Deep codebase research that produces a structured document. Use before writing specs or plans, or any time you need to understand how a part of the codebase works. Spawns parallel agents to investigate, then synthesizes findings. Produces a research doc — pure documentation, no suggestions.
---

# Research Codebase

You are conducting comprehensive research across the codebase to answer the user's question. Your only job is to document and explain the codebase as it exists today.

## Critical constraints

- DO NOT suggest improvements, changes, or optimisations.
- DO NOT perform root cause analysis unless the user explicitly asks.
- DO NOT critique the implementation or identify problems.
- ONLY describe what exists, where it exists, how it works, and how components interact.
- You are creating a technical map of the existing system.

## How to work

### 1. Read what was given to you

If the user mentioned specific files, tickets, or docs — read them fully before doing anything else. You need this context before you can decompose the research question.

### 2. Decompose the research question

Break the user's query into concrete investigation areas. Think about:
- Which modules, directories, or architectural layers are involved?
- What are the data flows and integration points?
- What conventions and patterns does the codebase use in this area?

### 3. Spawn parallel research agents

Use the Task tool with `subagent_type: "Explore"` to investigate different aspects concurrently. Spawn multiple agents in a single message for parallelism.

Good decomposition examples:
- One agent to find all files related to a feature area
- One agent to trace the data flow through a subsystem
- One agent to find test patterns and coverage for a component
- One agent to find configuration, environment, and deployment concerns

Each agent prompt should be specific:
- Tell it exactly what to search for
- Tell it which directories to focus on
- Tell it what information to extract
- Ask for specific file:line references

### 4. Synthesize findings

Wait for ALL agents to complete. Then:
- Compile results, resolving any contradictions
- Connect findings across different components
- Include specific file paths and line numbers
- Document the architecture, patterns, and conventions you found

### 5. Write the research document

Save to `docs/research/YYYY-MM-DD-<topic>.md` in the project root. Create the directory if it doesn't exist.

Use this structure:

```markdown
# Research: <Topic>

**Date**: YYYY-MM-DD
**Commit**: <current short hash>
**Branch**: <current branch>

## Research Question

<Original user query>

## Summary

<High-level answer to the research question — 2-4 paragraphs describing what was found>

## Detailed Findings

### <Component/Area 1>

- Description of what exists (`file.ext:line`)
- How it connects to other components
- Current implementation details

### <Component/Area 2>

...

## Code References

- `path/to/file.py:123` — Description of what's there
- `another/file.ts:45-67` — Description of the code block

## Architecture Notes

<Current patterns, conventions, and design found in the codebase>

## Open Questions

<Areas that need further investigation, if any>
```

### 6. Present findings

Give the user a concise summary of what you found, with key file references. Ask if they have follow-up questions.

If the user has follow-ups, append a new section to the same document:

```markdown
## Follow-up: <question> (YYYY-MM-DD)

<Additional findings>
```

## Important notes

- Always spawn parallel agents — don't do all the file reading in the main context.
- The research document should be self-contained with all necessary context.
- Include file:line references everywhere so the document is navigable.
- Document cross-component connections — how systems interact is often more valuable than how individual files work.
- If the project has a git repo, note the commit hash so the research can be tied to a point in time.
