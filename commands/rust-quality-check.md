# Rust Quality Check

Run comprehensive quality checks on Rust projects to ensure code meets project standards. **ALL checks must pass (be green) for the quality check to succeed.**

## Execution Strategy

Use **parallel subagents** to run quality checks concurrently for faster feedback. Each check must complete successfully before proceeding.

## Quality Check Steps

1. **Pre-check Setup**
   - Ensure you're in the root directory of a Rust project
   - Verify `Cargo.toml` file exists
   - Check that dependencies are up to date with `cargo check`
   - **ABORT IMMEDIATELY** if any pre-check fails

2. **Parallel Quality Checks** (Run concurrently via subagents)
   
   **Format Check Agent**
   - Run `cargo fmt --check`
   - Verifies all Rust files follow consistent formatting
   - **ABORT IMMEDIATELY** if formatting issues found
   
   **Compilation Agent**
   - Run `cargo check --workspace --all-targets`
   - Ensures all code compiles without errors
   - **ABORT IMMEDIATELY** if compilation fails
   
   **Clippy Analysis Agent**
   - Run `cargo clippy --workspace --all-targets -- -D warnings`
   - Performs comprehensive static code analysis
   - Treats all warnings as errors for strict quality
   - **ABORT IMMEDIATELY** if any clippy issues are found
   
   **Test Execution Agent**
   - Run `cargo test --workspace`
   - Executes all unit and integration tests
   - **ABORT IMMEDIATELY** if any tests fail

3. **Strict Success Validation**
   - **ALL agents must report SUCCESS** for overall success
   - If ANY agent fails, the entire quality check fails immediately
   - No partial success - it's all or nothing

## Implementation with Subagents

When running this quality check:

1. **Launch 4 parallel Task agents** concurrently:
   ```
   Agent 1: Format Check - run `cargo fmt --check`
   Agent 2: Compilation - run `cargo check --workspace --all-targets`
   Agent 3: Clippy Analysis - run `cargo clippy --workspace --all-targets -- -D warnings`
   Agent 4: Test Execution - run `cargo test --workspace`
   ```

2. **Wait for ALL agents** to complete before proceeding

3. **Validate ALL GREEN** - every agent must report success

## Example Usage

```bash
# Sequential fallback (if subagents unavailable)
cargo fmt --check
cargo check --workspace --all-targets
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

## Success Criteria (ALL MUST BE GREEN)

**STRICT REQUIREMENT**: Every single check must pass for overall success:
- ✅ Code formatting is consistent (no changes needed)
- ✅ Compilation succeeds without errors
- ✅ Clippy analysis passes with no warnings (treated as errors)
- ✅ All tests pass

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

## Optional Advanced Checks

For projects requiring additional validation:
- `cargo bench` - Run benchmarks (if present)
- `cargo doc --no-deps` - Verify documentation builds
- `cargo audit` - Check for security vulnerabilities (requires cargo-audit)