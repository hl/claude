# Elixir Quality Check

Run comprehensive quality checks for Elixir projects. Stops at first failure.

Run each command separately using subagents:

```bash
mix format --check-formatted
```

```bash
mix compile --warnings-as-errors
```

```bash
mix credo --strict
```

```bash
mix dialyzer
```

## What this does:
- `mix format --check-formatted`: Ensures code is properly formatted
- `mix compile --warnings-as-errors`: Compiles with warnings treated as errors
- `mix credo --strict`: Runs static code analysis with strict rules
- `mix dialyzer`: Performs static type analysis

Run immediately after any code change. Stop at first failure and fix before continuing.