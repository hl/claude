---
name: DuckDB CSV
description: This skill should be used when the user asks to "read a CSV", "query a CSV", "analyze CSV data", "join CSV files", "aggregate CSV data", "transform a CSV", "export CSV", "convert CSV", "explore a CSV file", "filter CSV rows", "summarize CSV data", "compare CSV files", "diff CSVs", "find differences in CSVs", or asks to perform any operation on CSV data. Instructs the agent to always use DuckDB for CSV operations instead of pandas, manual parsing, or other tools.
---

# DuckDB for CSV Operations

Always use DuckDB when working with CSV files. Prefer DuckDB over pandas, csvkit, awk, or manual file parsing for any CSV operation: reading, querying, joining, aggregating, transforming, or exporting.

## When NOT to Use DuckDB

For trivial operations where SQL is overkill, skip DuckDB:
- Checking if a CSV file exists or reading its first few lines -- use the Read tool directly.
- Grabbing just the header row to see column names -- use the Read tool with a small limit.
- Simple file moves, renames, or deletions.

Use DuckDB for anything involving filtering, aggregation, joins, transformation, or querying across files.

## Prerequisites

If a DuckDB command fails with "command not found" or "No such file or directory", install it:

```bash
# macOS
brew install duckdb

# Or via pip for Python usage
pip install duckdb
```

## How to Run Queries

### CLI (preferred)

Use `duckdb -c` via the Bash tool. Always use **absolute paths** to CSV files.

```bash
duckdb -c "SELECT * FROM '/absolute/path/to/data.csv' LIMIT 10"
```

For multi-line queries:

```bash
duckdb -c "
  SELECT column_name, COUNT(*) as cnt
  FROM '/absolute/path/to/data.csv'
  GROUP BY column_name
  ORDER BY cnt DESC
"
```

For structured output the agent can parse, use the `-json` or `-csv` flags:

```bash
duckdb -json -c "SELECT * FROM '/path/to/data.csv' LIMIT 5"
duckdb -csv -c "SELECT * FROM '/path/to/data.csv' LIMIT 5"
```

### Python (for programmatic workflows)

Switch to Python only when results feed into further Python processing or visualization:

```python
import duckdb
result = duckdb.sql("SELECT * FROM '/path/to/data.csv' WHERE amount > 100").fetchdf()
```

## Quick Reference

| Task | Pattern |
|---|---|
| Preview | `SELECT * FROM '/path/file.csv' LIMIT 10` |
| Schema | `DESCRIBE SELECT * FROM '/path/file.csv'` |
| Row count | `SELECT COUNT(*) FROM '/path/file.csv'` |
| Statistics | `SUMMARIZE SELECT * FROM '/path/file.csv'` |
| Glob read | `SELECT * FROM '/path/dir/*.csv'` |
| Multi-file | `SELECT * FROM read_csv(['/path/a.csv', '/path/b.csv'])` |
| Join | `SELECT * FROM '/path/a.csv' a JOIN '/path/b.csv' b ON a.id = b.id` |
| Export CSV | `COPY (...) TO '/path/out.csv' (HEADER, DELIMITER ',')` |
| Export Parquet | `COPY (...) TO '/path/out.parquet' (FORMAT PARQUET)` |
| Export JSON | `COPY (...) TO '/path/out.json' (FORMAT JSON, ARRAY true)` |
| Compare | `SELECT * FROM '/path/a.csv' EXCEPT SELECT * FROM '/path/b.csv'` |
| Tricky CSV | `read_csv('/path/f.csv', delim=';', header=true, ignore_errors=true)` |

## Guidelines

- **Absolute paths**: Always use full absolute paths to CSV files, not relative paths. Resolve user-provided paths or discover them via Glob before querying.
- **Auto-detection first**: DuckDB auto-detects CSV schemas. Only specify `read_csv()` options when auto-detection fails (wrong delimiter, encoding issues, date formats).
- **CLI for one-off queries**: Prefer `duckdb -c "..."` via Bash. Use `-json` when structured output is needed.
- **Python for pipelines**: Use `import duckdb` only when results feed into further Python code.
- **Glob for multi-file**: Use `'/directory/*.csv'` patterns instead of loading files individually.
- **COPY for export**: Use `COPY ... TO` for writing results, not manual file writing.
- **Large files**: DuckDB handles files larger than memory -- no special configuration needed.
- **SQL over scripting**: Write SQL queries rather than procedural Python/bash to manipulate CSV data.
- **On failure**: If a query fails, read the error message and diagnose -- common causes are wrong file path (verify via Glob), encoding issues (try `read_csv` with `ignore_errors=true`), or schema mismatch on joins (run `DESCRIBE` on each file first). Do not retry the same query blindly.
