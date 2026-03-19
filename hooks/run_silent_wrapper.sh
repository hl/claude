#!/usr/bin/env bash
# Runs a command silently. On success: prints ✓. On failure: prints full output.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

eval "$1" > "$tmp" 2>&1
ec=$?

if [ "$ec" -eq 0 ]; then
    echo "✓ $(echo "$1" | head -c 120)"
else
    cat "$tmp"
    exit $ec
fi
