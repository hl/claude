# Personal Development Guidelines for Claude Code

This document contains my personal development guidelines and preferences for working with Claude Code. These rules ensure consistent, high-quality development practices across all projects.

---

## Core Philosophy

### Best Simple System for Now (BSSN)

Follow the BSSN philosophy: Build the **simplest** system that meets the needs **right now**, written to an **appropriate standard**. Avoid both over-engineering and corner-cutting.

#### Core Principles

1. **Design "for Now"**
   - Focus on what is actually needed RIGHT NOW, not anticipated future needs
   - Resist the urge to build generic solutions or "rules engines"
   - See what is really there, not the patterns your brain wants to see
   - Trust that you can evolve the code when needs actually change

2. **Keep it Simple**
   - No speculative interfaces or abstractions
   - No overly broad data types where specific ones will do
   - No generic functionality where specific code is clearer
   - Remove anything that isn't serving a current, concrete need
   - Flexibility comes from simplicity, not from anticipation

3. **Write it Best**
   - Don't cut corners - use the appropriate quality standard for the context
   - Core business functionality deserves higher quality than experimental features
   - Apply practices like TDD where they add value
   - Use consistent domain language
   - Write code that is "joyful" to work with

#### Implementation Guidelines

**When writing new code:**
- Start by solving ONLY the immediate problem
- If there are 9 types, write 9 specific handlers - don't reach for a generic framework
- Choose simple, obvious solutions over clever abstractions
- Make code highly opinionated and deliberately narrow

**When evaluating solutions:**
- Consider the total cost: adoption, learning, dependencies, quirks, future removal
- A few lines of custom code may be better than a complex library
- Home-grown isn't always the answer, but "seeing what's really there" is

**When evolving code:**
- Change in response to actual new demands, not predictions
- Evolve toward a new "Best Simple System" for the new "Now"
- Each change should leave the system as simple as possible
- Delete code that no longer serves current needs

#### Red Flags to Avoid
- "We might need this later"
- "Let's make this configurable"
- "What if we have 10,000 users?" (when you have 12)
- Interfaces with single implementations
- Abstraction layers "for flexibility"
- Design patterns applied without clear current benefit

---

## Communication Style

### Response Formatting Guidelines

#### Be Direct and Honest
- Provide accurate, truthful information
- Acknowledge limitations or uncertainties
- Correct mistakes promptly
- Avoid sugarcoating technical realities

#### Be Concise
- Use clear, direct language
- Avoid unnecessary repetition
- Skip filler phrases like "certainly" or "of course"
- Get to the point quickly

#### Be Precise
- Use specific technical terms correctly
- Provide exact error messages
- Include version numbers when relevant
- Give concrete examples over abstract descriptions

#### Output Structure

**Code Responses:**
```elixir
# Brief comment explaining the approach
defmodule Example do
  # Implementation with inline comments for complex parts
end
```

**Explanations:**
1. **Problem**: State what we're solving
2. **Solution**: Explain the approach
3. **Implementation**: Show the code
4. **Trade-offs**: Discuss alternatives if relevant

**Error Handling:**
- Quote the exact error message
- Identify the root cause
- Provide the fix
- Explain why it works

---

## Elixir Development

### Elixir Development Behavior

Apply the **Best Simple System for Now (BSSN)** philosophy to all Elixir code:
- Always start with the simplest solution that solves the current problem
- Avoid suggesting abstractions unless clearly justified by current needs
- When multiple approaches exist, choose the most direct implementation
- Reject requests for speculative flexibility or "future-proofing"

#### Code Quality Requirements

1. **Documentation First**: Always consult official Elixir/Phoenix documentation
2. **Code Validation**: Before suggesting code, verify module/function existence:
   - **Internal modules** (start with app name): Check current codebase
   - **External modules**: Check official documentation (HexDocs)
   - Verify correct function arity and argument order
   - Prefer minimal working implementations when multiple options exist
3. **Idiomatic Code**: Follow Elixir community conventions and patterns
4. **Error Handling**: Use pattern matching and the "let it crash" philosophy appropriately
5. **Testing**: Write ExUnit tests for business logic
6. **Static Analysis**: Ensure code passes Credo checks

#### Tool Usage Behavior

**When working with existing codebases:**
- Always use Read tool to examine existing patterns before writing new code
- Use Grep/Glob tools to understand current file organization
- Never assume module names or function signatures - verify with documentation or codebase
- Check existing similar implementations before creating new ones

**When suggesting code changes:**
- Prefer editing existing files over creating new ones
- Follow the exact patterns and conventions found in the current codebase
- Use the same library choices and architectural patterns already present

### Elixir Code Style

Adhere to the conventions outlined in [The Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide/blob/master/README.md):

#### Formatting
- Primarily rely on the built-in Elixir code formatter (`mix format`)
- Limit lines to 98 characters unless configured otherwise in `.formatter.exs`
- Use spaces around binary operators, after commas, colons, and semicolons
- Do not use spaces around paired brackets (`[]`, `{}`, `()`) or after unary operators
- Use blank lines between function definitions but not immediately after `defmodule`
- Format multiline lists, maps, structs, `case`, and `cond` clauses with each element/clause on its own line
- Place comments on the line *above* the code they refer to, with a single space after the `#`

#### Naming
- Strictly follow the official [Elixir Naming Conventions](https://hexdocs.pm/elixir/naming-conventions.html)
- Use `snake_case` for variables/functions/atoms, `CamelCase` for modules/structs

#### Comments & Documentation
- Write clear and concise comments
- Use standard annotations like `TODO:`, `FIXME:`, `OPTIMIZE:`
- Provide `@moduledoc` for modules and `@doc` for public functions
- Use Markdown for formatting within documentation
- Write comprehensive documentation examples using `iex>` prompts
- Avoid unnecessary comments - explain why, not what

#### Typespecs
- Use `@typedoc` to document custom types defined with `@type`
- Use `@spec` to define function specifications

#### Modules
- Use `alias` to shorten module names, but avoid ambiguity or conflicts
- Module aliases should be listed one per line
- Use `require` specifically when macros from another module are needed
- Use `import` sparingly, preferring fully qualified function calls
- Generally, define one module per file

#### Collections
- Use the shorthand syntax for keyword lists: `[key: value]`
- Use the shorthand map syntax `%{key: value}` when all keys are atoms

#### Testing (ExUnit)
- In assertions, place the expression being tested on the left side: `assert actual == expected`
- For pattern matching assertions: `assert {:ok, value} = function_call()`

### Elixir ExUnit Testing Conventions

#### General Test Structure & Setup
1. **DataCase Usage**: Always begin tests with `use MyApp.DataCase, async: true`
2. **File Naming and Location**: Test file paths MUST mirror source file paths
   - Replace `lib/` with `test/` and append `_test.exs`
   - Example: `lib/my_app/some_module.ex` → `test/my_app/some_module_test.exs`

#### Data Generation & Factories
3. **Factory Usage**:
   - ALWAYS use factories (e.g., `insert(:my_factory, attr: value)`) for creating test data
   - NEVER use `Repo.insert` directly
   - If the required factory is unknown, ask for clarification

4. **Factory Definitions**:
   - New factories SHOULD be created in new files within `test/support/factories/`
   - Do NOT add factory definitions directly to the main `test/support/factory.ex` file

5. **Factory Attributes**:
   - When associating models, pass the full model struct, NOT the `_id`
   - NEVER generate `id` or `_id` fields with random UUIDs/integers if auto-generated

#### Tenant Isolation (If Applicable)
6. **Scoped Data Checks**: If the application has data isolation (e.g., by `tenant_id`), ALWAYS write tests to verify proper scoping

#### Mocking (Using Mox or Similar)
7. **When to Mock**: Mocking should generally be a last resort. Prefer testing with real implementations where feasible
8. **Data Generation**: NEVER use mocks for generating test data for your application's database entities
9. **General Procedure for Using Mocks**:
   a. **Define Behaviour**: Create an Elixir behaviour for the module/functionality you intend to mock
   b. **Implement Behaviour**: Ensure the actual module implements this behaviour
   c. **Define Mocks**: Add mock definitions in appropriate test setup locations
   d. **Utilize Mocks**: Use the defined mocks within your test cases
   e. **Verify Mocks**: If using Mox, call `setup :verify_on_exit!` at the top of test files

#### LiveView Tests (If Applicable)
10. **Imports**: LiveView tests MUST include `import Phoenix.LiveViewTest`
11. **Setup Block**: Utilize a `setup` block to create and log in users, and enable feature flags
12. **Cross-Context Access**: If a LiveView URL includes identifiers that scope data, ALWAYS write tests to check proper access control

#### Test Execution
13. **Running Tests**: Before executing `mix test`, ensure you are in the root directory where `mix.exs` is located
14. **Verification**: After creating or updating a test, MUST run that specific test to verify correctness

---

## Code Analysis & Documentation

### Decision-Making Process

When facing implementation choices:

#### 1. Codebase First
- Examine existing code patterns before suggesting solutions
- Use Read tool to understand current architecture decisions
- Follow established conventions rather than introducing new patterns

#### 2. Documentation Verification
- Always verify function signatures and module existence before suggesting code
- Check official Elixir/Phoenix docs when unsure about API usage
- Never guess at function names or parameters

#### 3. BSSN Application
- When multiple valid approaches exist, choose the simplest
- Avoid suggesting configurable or generic solutions unless specifically requested
- Push back on requirements that seem speculative or over-engineered

#### Ambiguity Resolution
When requirements are unclear:
- Ask specific questions about current needs rather than building flexible solutions
- Suggest concrete examples to clarify intent
- Propose the minimal solution that solves the stated problem

---

## Project Management

### Tool Preferences

**GitHub Operations:**
- Always use `gh` CLI instead of web URLs for GitHub tasks
- Use `gh` for issues, pull requests, checks, and releases
- When given GitHub URLs, extract information using `gh` commands

**Claude Code Tool Usage:**
- Use Read tool before making assumptions about file contents
- Use Grep/Glob tools to understand codebase structure before suggesting changes
- Use concurrent tool calls when gathering related information
- Prefer Task tool for complex searches that might require multiple iterations
