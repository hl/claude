# Elixir Quality Check

Run comprehensive quality checks on Elixir projects to ensure code meets project standards. **ALL checks must pass (be green) for the quality check to succeed.**

## Execution Strategy

Use **parallel subagents** to run quality checks concurrently for faster feedback. Each check must complete successfully before proceeding.

## Quality Check Steps

1. **Pre-check Setup**
   - Ensure you're in the root directory of an Elixir project
   - Verify `mix.exs` file exists
   - Check that dependencies are installed with `mix deps.get`
   - **ABORT IMMEDIATELY** if any pre-check fails

2. **Parallel Quality Checks** (Run concurrently via subagents)
   
   **Format Check Agent**
   - Run `mix format --check-formatted`
   - Verifies all Elixir files follow consistent formatting
   - **ABORT IMMEDIATELY** if formatting issues found
   
   **Compilation Agent**
   - Run `mix compile --warnings-as-errors`
   - Treats all warnings as errors to maintain high code quality
   - **ABORT IMMEDIATELY** if compilation fails with warnings or errors
   
   **Static Analysis Agent**
   - Run `mix credo --strict --format=json` if Credo is available
   - Performs comprehensive static code analysis
   - **ABORT IMMEDIATELY** if critical issues are found
   - Skip gracefully if Credo not available
   
   **Type Analysis Agent**
   - Run `mix dialyzer` if Dialyzer is available
   - Performs static type analysis to catch type-related bugs
   - **ABORT IMMEDIATELY** if type errors are detected
   - Skip gracefully if Dialyzer not available

3. **Strict Success Validation**
   - **ALL agents must report SUCCESS** for overall success
   - If ANY agent fails, the entire quality check fails immediately
   - No partial success - it's all or nothing

## Implementation with Subagents

When running this quality check:

1. **Launch 4 parallel Task agents** concurrently:
   ```
   Agent 1: Format Check - run `mix format --check-formatted`
   Agent 2: Compilation - run `mix compile --warnings-as-errors` 
   Agent 3: Credo Analysis - run `mix credo --strict --format=json`
   Agent 4: Dialyzer - run `mix dialyzer`
   ```

2. **Wait for ALL agents** to complete before proceeding

3. **Validate ALL GREEN** - every agent must report success

## Example Usage

```bash
# Sequential fallback (if subagents unavailable)
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
```

## Success Criteria (ALL MUST BE GREEN)

**STRICT REQUIREMENT**: Every single check must pass for overall success:
- ✅ Code formatting is consistent (no changes needed)
- ✅ Compilation succeeds without warnings or errors
- ✅ Credo analysis passes with no critical issues
- ✅ Dialyzer analysis passes with no type errors

## Failure Handling

**IMMEDIATE ABORT** policy:
- If ANY single check fails, STOP immediately
- Report the failing check(s) and exact error messages
- Do NOT continue with remaining checks
- Fix identified issues before re-running entire quality check

## Agent Coordination

Each subagent should:
1. Report its specific task status clearly
2. Include full error output on failure
3. Return simple SUCCESS/FAILURE status
4. Execute independently without dependencies on other agents

---

## Elixir Development Standards

### Code Style & Quality Requirements

1. **Style Guide** - Strictly follow [The Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide/blob/master/README.md)
2. **Documentation First** - Always consult official Elixir/Phoenix documentation
3. **Code Validation** - Verify module/function existence before suggesting code
4. **Explicit Error Handling** - Always generate code with explicit error handling by default
5. **Codebase First** - Use Read tool to examine existing patterns before writing new code
6. **BSSN Principles** - Start with simplest solution, avoid speculative abstractions

### Testing Standards

- **DataCase Usage**: Begin tests with `use MyApp.DataCase, async: true`
- **Factory Usage**: ALWAYS use factories for test data, NEVER `Repo.insert` directly
- **Factory Organisation**: New factories in `test/support/factories/`, not main factory file
- **Scoped Data**: Always test proper data isolation if application has tenant-like scoping
- **Test Execution**: Must run specific test after creation/update to verify correctness

### Development Philosophy

- **Design "for Now"** - Focus on current needs, not anticipated future requirements
- **Keep it Simple** - No speculative interfaces or abstractions where specific code is clearer
- **Avoid Over-engineering** - Reject "we might need this later" thinking
- **Quality First** - Use appropriate standards, don't cut corners on core functionality