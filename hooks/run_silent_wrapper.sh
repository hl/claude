#!/usr/bin/env bash
# Runs a command silently. On success: prints ✓. On failure: prints full output.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

eval "$1" > "$tmp" 2>&1
ec=$?

if [ "$ec" -eq 0 ]; then
    # Extract a one-line summary from the output (test counts, credo/dialyzer results, etc.)
    summary=$(grep -aE '(tests?,|passed successfully|no issues|done in|Finished in|0 failures)' "$tmp" | tail -1 | sed 's/^[[:space:]]*//')
    if [ -n "$summary" ]; then
        echo "✓ $(echo "$1" | head -c 80) — $summary"
    else
        echo "✓ $(echo "$1" | head -c 120)"
    fi
else
    cat "$tmp"
    exit $ec
fi
