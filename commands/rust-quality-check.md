# Rust Quality Check

Run comprehensive quality checks for Rust projects. Stops at first failure.

Run each command separately using subagents:

```bash
cargo fmt --check
```

```bash
cargo check --workspace --all-targets
```

```bash
cargo clippy --workspace --all-targets -- -D warnings
```

```bash
echo "=== Suppressed Clippy Warnings ===" && rg --type rust '#\[allow\(clippy::' . --count --with-filename | sort -t: -k2 -nr | head -20 && echo && rg --type rust '#\[allow\(clippy::' . -n | head -10
```

```bash
cargo test --workspace
```

## What this does:
- `cargo fmt --check`: Ensures code is properly formatted
- `cargo check --workspace --all-targets`: Compiles all targets in workspace
- `cargo clippy --workspace --all-targets -- -D warnings`: Runs linter with warnings as errors
- Suppressed clippy warnings check: Shows count per file and examples of suppressed warnings
- `cargo test --workspace`: Runs all tests in workspace

Run immediately after any code change. Stop at first failure and fix before continuing.