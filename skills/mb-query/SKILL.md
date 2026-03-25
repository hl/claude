---
name: mb-query
description: This skill should be used when the user asks to "query the database", "look up production data", "run a SQL query", "check the database", "find in the database", "query prod", "use mb", "metabase query", or any request that requires reading data from the production PostgreSQL database.
---

# Production Database Queries with `mb`

Use the Metabase CLI (`mb`) to run read-only SQL queries against the production database.

## Core Command

```bash
mb query run --database-id 2 --sql "<SELECT query>"
```

- **Database ID 2** = GCP Prod (PostgreSQL)
- **Read-only**: Only run `SELECT` queries. Never run `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, or any other mutating statement.

## Schema Discovery

The database schema changes frequently. Never assume table or column names — always discover them dynamically.

### List all tables

```bash
mb table list --database-id 2
```

The output is JSON with an array at `.data`, each entry having `name`, `schema`, and `display_name` fields. Pipe through `python3` or `jq` to filter for relevant table names when looking for a specific entity.

### Describe a table's columns and types

```bash
mb table describe --database-id 2 TABLE_NAME
```

### Workflow

1. If the needed table name is not known, run `mb table list --database-id 2` and filter for relevant names.
2. Once the table is identified, run `mb table describe --database-id 2 TABLE_NAME` to discover columns and types.
3. Write and execute the `SELECT` query with `mb query run --database-id 2 --sql "..."`.

## Output Handling

`mb query run` returns JSON. The result rows are at `.data.data.rows` and column metadata at `.data.data.results_metadata.columns`. Extract and format the relevant data for the user rather than dumping raw JSON.

## Known Schema Quirks

- The `organisations` table uses `organisation_id` (not `id`) as its primary key.

## Important Notes

- Always include `LIMIT` on exploratory queries to avoid pulling excessive data.
- Quote all string and UUID values with single quotes in SQL.
- The database is PostgreSQL — use PostgreSQL syntax (e.g., `ILIKE`, `::uuid`, `NOW()`, `INTERVAL`).
