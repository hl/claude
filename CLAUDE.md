# Personal Development Guidelines for Claude Code

This document contains my personal development guidelines and preferences for working with Claude Code. These rules override default behavior and ensure consistent practices across all projects.

---

## Core Philosophy

### Best Simple System for Now (BSSN)

Build the **simplest** system that meets the needs **right now**, written to an **appropriate standard**. Avoid both over-engineering and corner-cutting.

#### Core Principles

1. **Design "for Now"** - Focus on what is actually needed RIGHT NOW, not anticipated future needs
2. **Keep it Simple** - No speculative interfaces, abstractions, or generic functionality where specific code is clearer
3. **Write it Best** - Use appropriate quality standards for the context; don't cut corners on core functionality

#### Red Flags to Avoid

- "We might need this later"
- "Let's make this configurable"  
- "What if we have 10,000 users?" (when you have 12)
- Interfaces with single implementations
- Design patterns applied without clear current benefit

---

## Tool Usage

### CRITICAL Tool Restrictions

**ALWAYS follow these tool usage rules:**

- **File Operations**: Use Filesystem MCP tools when available, otherwise use built-in file tools. NEVER use tidewave for file operations
- **Code Structure Search**: Use `ast-grep --lang <language> -p '<pattern>'` when available, otherwise use text-only tools like `rg`/`grep` for structural matching

### Tool Hierarchy

When multiple tools can accomplish the same task, use this order:

1. **Sequential Thinking MCP** - Complex problems requiring step-by-step analysis
2. **Context7 MCP** - Library documentation lookup (always resolve library ID first)
3. **Filesystem MCP** - ALL file operations (read, write, edit, search)
4. **Task Tool** - Complex searches requiring multiple iterations
5. **Built-in Tools** - Simple, direct operations when MCP alternatives don't exist

### Search Strategy

- **Code structure/syntax searches**: `ast-grep --lang <language> -p '<pattern>'` when available
- **Plain text content searches**: `rg` for non-structural content or when ast-grep unavailable
- **Complex multi-step searches**: Task tool
- **File pattern matching**: Filesystem MCP glob when available
- **Command line tools**: Use `fd` instead of `find` when available

### Usage Guidelines

- Use Sequential Thinking MCP for problems requiring 3+ steps or unfamiliar domains
- Use concurrent tool calls when gathering related information
- Use Read tool before making assumptions about file contents
- Respect .gitignore when searching files unless instructed otherwise

---

## Task Management

### TodoWrite Usage

**Use for:** Multi-step workflows (3+ actions), complex tasks requiring tracking, multiple user requirements

**Behavior:**
- Mark tasks `in_progress` immediately when starting
- Only ONE task `in_progress` at a time
- Mark `completed` immediately upon finishing
- Break complex tasks into specific, actionable items

---

## Communication & Reasoning

### Response Style

- **Be Direct**: Accurate information, acknowledge limitations, correct mistakes promptly
- **Be Concise**: Clear language, avoid repetition, skip filler phrases, get to the point
- **Be Collaborative**: Treat interactions like junior developer code reviews, propose multiple approaches, ask clarifying questions

### Problem-Solving Approach

1. **Explain Approach** - Describe planned approach step-by-step
2. **Use Sequential Thinking** - For complex tasks requiring reasoning
3. **Validate Against BSSN** - Choose simplest approach that solves current problem
4. **Propose Alternatives** - When multiple valid approaches exist

---

## Development Rules

### File Management

- Do what has been asked; nothing more, nothing less
- NEVER create files unless absolutely necessary for achieving the goal
- ALWAYS prefer editing existing files over creating new ones
- NEVER proactively create documentation files unless explicitly requested

### Code Quality

- Use British English instead of American English in code and comments
- Follow established project conventions and patterns
- Always examine existing codebase patterns before suggesting solutions
- Verify function/method signatures and module/class existence before suggesting code
- Generate code with explicit error handling by default
- Do not create legacy fallback code unless specifically instructed
- Consult official language/framework documentation first

### Project Management

- Always use `gh` CLI instead of web URLs for GitHub tasks
- Use `gh` for issues, pull requests, checks, and releases