#!/usr/bin/env bash
# agent-route.sh — PreToolUse hook for the Agent tool. Asks route.sh (Jev) for a
# tier and sets tool_input.model through updatedInput.
#
# JEV_ROUTE_MODE:
#   fill (default)  set model only when the call has none (never for subagent_type fork)
#   escalate        fill, and also raise a haiku/sonnet/opus model when Jev's tier
#                   (after policy) is higher. Never lowers. Full IDs other than
#                   haiku/sonnet/opus ones, "fable" and "inherit" are left alone.
#   log             decide and log, change nothing
#   off             do nothing
#
# Never touched: subagent_type in JEV_ROUTE_SKIP_TYPES (default
# fork,Explore,claude-code-guide,statusline-setup) or a custom agent whose
# frontmatter sets `model:`.
#
# Fails open: any problem -> exit 0, no output, normal Agent call. Every decision
# goes to ~/.claude/jev/log/route.jsonl.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=agent-route
# shellcheck source=lib.sh
. "$JEV_DIR/lib.sh"

mode=${JEV_ROUTE_MODE:-fill}
case $mode in fill | escalate | log) ;; *) exit 0 ;; esac
jev_disabled && exit 0

payload=$(cat)
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
input=$(jq -c '.tool_input // {}' <<<"$payload")
given=$(jq -r '.model // empty' <<<"$input")
stype=$(jq -r '.subagent_type // empty' <<<"$input")
desc=$(jq -r '.description // empty' <<<"$input")

log_decision() { # <action> [route-json] [final]
  jev_log route.jsonl "$(jq -cn --arg action "$1" --arg mode "$mode" --arg given "$given" \
    --arg stype "$stype" --arg desc "${desc:0:200}" --arg final "${3:-}" --argjson r "${2:-null}" '{
      action: $action, mode: $mode, subagent_type: $stype, given_model: $given,
      jev_model: ($r.model // null), final_model: (if $final == "" then null else $final end),
      confidence: ($r.confidence // null), policy: ($r.policy // null),
      signals: ($r.signals // null), description: $desc}')"
}

# Agent types whose definition pins a model keep it: a per-call model would
# override their frontmatter. JEV_ROUTE_SKIP_TYPES lists built-ins; custom
# agents are checked for a `model:` line in their frontmatter. Only matters
# when the call has no model; an explicit model is the caller's choice.
if [ -z "$given" ]; then
  case ",${JEV_ROUTE_SKIP_TYPES:-fork,Explore,claude-code-guide,statusline-setup}," in
    *",$stype,"*)
      log_decision skip_type
      exit 0
      ;;
  esac
  cwd=$(jq -r '.cwd // empty' <<<"$payload")
  for f in ${cwd:+"$cwd/.claude/agents/$stype.md"} "$HOME/.claude/agents/$stype.md"; do
    if [ -n "$stype" ] && [ -f "$f" ] &&
      awk '/^---$/ { n++; next } n == 1 && /^model:[[:space:]]*[^[:space:]]/ { found = 1 } END { exit !found }' "$f"; then
      log_decision skip_pinned_model
      exit 0
    fi
  done
fi

# Tier of the model the caller asked for: haiku/sonnet/opus alias or full ID.
given_rank=-1
case $given in
  '') given_rank=-1 ;;
  *haiku*) given_rank=0 ;;
  *sonnet*) given_rank=1 ;;
  *opus*) given_rank=2 ;;
  *) given_rank=9 ;; # fable, inherit, unknown IDs: never touch
esac

if [ -n "$given" ]; then
  if [ "$mode" = fill ] || [ "$given_rank" -ge 9 ]; then
    log_decision skip_has_model
    exit 0
  fi
fi

text=$(jq -r '[(.description // ""), (if .subagent_type then "subagent_type: " + .subagent_type else empty end), (.prompt // "")] | map(select(. != "")) | join("\n\n")' <<<"$input")
[ -n "$text" ] || exit 0

if ! route=$(printf '%s' "$text" | JEV_TIMEOUT=${JEV_ROUTE_TIMEOUT:-4} "$JEV_DIR/route.sh" 2>/dev/null); then
  log_decision route_failed
  exit 0
fi
tier=$(jq -r '.model' <<<"$route")
case $tier in haiku) jev_rank=0 ;; sonnet) jev_rank=1 ;; opus) jev_rank=2 ;; *) exit 0 ;; esac

if [ "$mode" = log ]; then
  log_decision logged "$route"
  exit 0
fi
if [ "$given_rank" -ge "$jev_rank" ]; then
  log_decision kept "$route" "$given"
  exit 0
fi

action=filled
[ -n "$given" ] && action=escalated
reason=$(jq -r --arg from "${given:-none}" '
  (.signals | to_entries | max_by(.value)) as $top
  | "jev: \($from)→\(.model) (conf \(.confidence), \($top.key) \($top.value)" +
    (if .policy == "as_is" then "" else ", " + .policy end) + ")"' <<<"$route")
out=$(jq -cn --argjson input "$input" --arg model "$tier" --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: $reason,
    updatedInput: ($input + {model: $model})
  }}')
log_decision "$action" "$route" "$tier"
printf '%s\n' "$out"
