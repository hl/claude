#!/usr/bin/env bash
# PreToolUse hook: wraps Bash commands with run_silent_wrapper.sh
# On success only "✓ command" enters the context window.
# On failure the full output is shown for debugging.
#
# SUPPRESS LIST: Commands whose successful output is noise.
# Agents: add commands here when output clogs the context window.
# Only these commands get wrapped — everything else passes through.
# Supports "cmd" (first word match) or "cmd subcommand" (two word match).
SUPPRESS_CMDS="
mix test
mix deps.get
mix deps.compile
mix compile
mix format
mix dialyzer
mix credo
mix ci
"

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command')

# Check if any suppress pattern appears in the command
while IFS= read -r suppress; do
    suppress=$(printf '%s' "$suppress" | xargs)
    [ -z "$suppress" ] && continue
    if printf '%s' "$cmd" | grep -qw "$suppress"; then
        jq -n --arg cmd "$cmd" '{
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "updatedInput": {
                    "command": ($ENV.HOME + "/.claude/hooks/run_silent_wrapper.sh " + ($cmd | @sh))
                }
            }
        }'
        exit 0
    fi
done <<< "$SUPPRESS_CMDS"
