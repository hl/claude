# Claude Development Guidelines

## Core Philosophy: BSSN (Best Simple System for Now)

Build the **simplest** system that meets needs **right now** to **appropriate standard**. Avoid over-engineering and corner-cutting.

**Principles:** Focus on actual current needs, keep it simple, write it best
**Red Flags:** "We might need this later", interfaces with single implementations, placeholder code for future needs

## Tool Usage

**Primary Tools:**
- Zen MCP server for advanced workflows
- `ast-grep --lang <language> -p '<pattern>'` for code structure
- `rg` for text content, `fd` for file finding
- TodoWrite for 3+ step workflows

## Development Rules

### Critical Requirements
- Consult official docs first
- Generate code with explicit error handling
- British English in code/comments
- State which existing file you're using as pattern reference
- Cite the specific file/function that informed your approach
- Confirm function exists by showing its signature before using it
- Use `gh` CLI for GitHub tasks

### File Management
- Do what's asked; nothing more/less
- NEVER create files unless absolutely necessary - justify if you must
- ALWAYS prefer editing existing over creating new - state which file you're editing and why
- NEVER proactively create docs unless requested

### Quality Checks 
Run immediately after any code change. Stop at first failure and fix before continuing.

**Elixir:**
```bash
mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer
```

**Rust:**
```bash
cargo fmt --check && cargo check --workspace --all-targets && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

