# Elixir Quality Check

Run comprehensive quality checks on Elixir projects to ensure code meets project standards.

1. **Pre-check Setup**
   - Ensure you're in the root directory of an Elixir project
   - Verify `mix.exs` file exists
   - Check that dependencies are installed with `mix deps.get`

2. **Format Code**
   - Run `mix format` to automatically format all Elixir files
   - This ensures consistent code formatting across the project

3. **Compilation Check**
   - Run `mix compile --warnings-as-errors`
   - Treats all warnings as errors to maintain high code quality
   - Abort if compilation fails with warnings or errors

4. **Static Code Analysis**
   - Run `mix credo --strict --format=json` if Credo is available in the project
   - Performs comprehensive static code analysis
   - Checks for code readability, consistency, and potential issues
   - Abort if critical issues are found

5. **Type Analysis**
   - Run `mix dialyzer` if Dialyzer is available in the project
   - Performs static type analysis to catch type-related bugs
   - May take longer on first run as it builds PLT (Persistent Lookup Table)
   - Abort if type errors are detected

6. **Summary Report**
   - Display results of all quality checks
   - Indicate which checks passed/failed
   - Provide guidance on next steps if any checks fail

## Example Usage

```bash
mix format
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
```

## Success Criteria

All checks must pass for the quality check to be considered successful:
- ✅ Code formatting is consistent
- ✅ Compilation succeeds without warnings
- ✅ Credo analysis passes with no critical issues
- ✅ Dialyzer analysis passes with no type errors

## Failure Handling

If any check fails:
1. Review the specific error messages
2. Fix the identified issues
3. Re-run the quality check