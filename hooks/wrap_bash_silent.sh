#!/usr/bin/env bash
# PreToolUse hook: wraps Bash commands with run_silent_wrapper.sh
# On success only "✓ command" enters the context window.
# On failure the full output is shown for debugging.
#
# PASSTHROUGH LIST: Commands whose output is needed in context.
# Agents: add commands here when you need to see their output.
# One command per line. Lines starting with # are ignored.
PASSTHROUGH_CMDS="
git
gh
docker
kubectl
"

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command')

# Extract the first command (before pipes, &&, ||, ;)
first_cmd=$(printf '%s' "$cmd" | sed 's/[|;&].*//' | awk '{print $1}')

# Check against passthrough list
for passthrough in $PASSTHROUGH_CMDS; do
    if [ "$first_cmd" = "$passthrough" ]; then
        exit 0
    fi
done

jq -n --arg cmd "$cmd" '{
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": {
            "command": ($ENV.HOME + "/.claude/hooks/run_silent_wrapper.sh " + ($cmd | @sh))
        }
    }
}'
