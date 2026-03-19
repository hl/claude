#!/usr/bin/env bash
# PreToolUse hook: wraps Bash commands with run_silent_wrapper.sh
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command')

jq -n --arg cmd "$cmd" '{
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": {
            "command": ($ENV.HOME + "/.claude/hooks/run_silent_wrapper.sh " + ($cmd | @sh))
        }
    }
}'
