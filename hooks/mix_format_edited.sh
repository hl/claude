#!/usr/bin/env bash
# PostToolUse hook: format an edited Elixir file using ITS OWN project's formatter config.
#
# Why the cd matters: `mix format` resolves .formatter.exs from the CURRENT DIRECTORY,
# not from the file being formatted. Running it from a directory with no .formatter.exs
# (e.g. a monorepo root) silently falls back to DEFAULT config, dropping the project's
# import_deps — which rewrites `field :name, :string` into `field(:name, :string)` and
# makes `mix format --check-formatted` fail in CI. So chdir to the file's nearest
# ancestor holding mix.exs, then format the path relative to it.

set -euo pipefail

payload=$(cat)
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')

# Only Elixir sources; anything else is a clean no-op.
case "$file" in
  *.ex | *.exs) ;;
  *) exit 0 ;;
esac

[ -n "$file" ] && [ -f "$file" ] || exit 0

# Resolve to a real absolute path so the prefix strip below is reliable.
dir=$(cd "$(dirname "$file")" && pwd -P)
abs="$dir/$(basename "$file")"

# Walk up to the nearest ancestor containing mix.exs.
root="$dir"
while [ "$root" != "/" ] && [ ! -f "$root/mix.exs" ]; do
  root=$(dirname "$root")
done

if [ ! -f "$root/mix.exs" ]; then
  # Not inside a Mix project — format from the file's own directory with defaults.
  root="$dir"
fi

cd "$root"
exec mix format "${abs#"$root"/}"
