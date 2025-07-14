# Claude Development Guidelines

## Core Philosophy: BSSN (Best Simple System for Now)

Build the **simplest** system that meets needs **right now** to **appropriate standard**. Avoid over-engineering and corner-cutting.

### Principles

1. **Design "for Now"** - Focus on actual current needs
1. **Keep it Simple** - No speculative abstractions where specific code is clearer
1. **Write it Best** - Use appropriate quality standards

### Red Flags

- "We might need this later" / "Let's make this configurable" / "What if we have 10,000 users?"
- Interfaces with single implementations / Design patterns without clear current benefit
- **No placeholder code for future needs** - implement only what's needed right now

## Tool Usage

### CRITICAL Rules

- **File Operations**: Filesystem MCP tools when available, otherwise built-in. NEVER tidewave
- **Code Structure Search**: `ast-grep --lang <language> -p '<pattern>'` when available, otherwise `rg`/`grep`
- **File Finding**: Always use `fd` instead of `find`

### Tool Hierarchy

1. Sequential Thinking MCP - Complex multi-step problems
1. Context7 MCP - Library docs (resolve library ID first)
1. Filesystem MCP - ALL file operations
1. Task Tool - Complex multi-iteration searches
1. Built-in Tools - When MCP unavailable

### Search Strategy

- **Search Strategy**: `ast-grep` for code structure, `rg` for text content, Task tool for multi-step, Filesystem MCP for file patterns, `fd` over `find`

## Task Management

**TodoWrite for:** 3+ step workflows, complex tracking, multiple requirements

- Mark `in_progress` when starting (only ONE at a time)
- Mark `completed` immediately when finished
- Break into specific, actionable items

## Communication

- **Direct**: Accurate info, acknowledge limits, correct mistakes promptly
- **Concise**: Clear language, no filler, get to point
- **Collaborative**: Multiple approaches, clarifying questions

## Development Rules

### Critical Requirements

- **Consult official docs first** before suggesting solutions
- **Generate code with explicit error handling** unless specifically told otherwise

### File Management

- Do what's asked; nothing more/less
- NEVER create files unless absolutely necessary
- ALWAYS prefer editing existing over creating new
- NEVER proactively create docs unless requested

### Code Quality

- British English in code/comments
- Follow project conventions/patterns
- Examine existing codebase first
- Verify signatures/existence before suggesting
- No legacy fallback unless instructed
- Use `gh` CLI for GitHub tasks

### Quality Checks

**Elixir Projects:**

- `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer`
- ALL checks must pass (abort on first failure)

**Rust Projects:**

- `cargo fmt --check && cargo check --workspace --all-targets && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`
- ALL checks must pass (abort on first failure)

