#!/usr/bin/env bash
# agent-route.sh — PreToolUse hook for the Agent tool: may raise an explicit
# "haiku" or "sonnet" to the tier route.sh would pick, via updatedInput.
#
# Acts only in Claudette sessions (an .orchestrator.md at $CLAUDE_PROJECT_DIR)
# or with JEV_SCOPE=all; anywhere else it exits before reading the payload.
# In scope, it never calls Jev when nothing can change:
#   - no model (frontmatter / inherit semantics stay), a full model ID, fable,
#     inherit, opus, subagent_type fork, a plugin agent ("x:y"), or
#     CLAUDE_CODE_SUBAGENT_MODEL set: left alone, logged;
#   - the prompt or description has a line "Route: <id>" (r<epoch>-<pid>-<n>, the
#     last such line wins) and route.jsonl holds that id: Claudette already
#     routed it. The model is raised to that answer if lower, never re-scored.
# Any other explicit haiku/sonnet, including one whose id is not in route.jsonl,
# is scored (one Jev request, description + subagent_type + prompt) and raised
# when route.sh's tier is higher. Never lowers. route.sh gets --context from
# policy.jq hook_context ({requested, poll_verb}), so a requested haiku stays
# haiku when Jev is sure of it (P(haiku) >= 0.95, security and review < 0.5) or
# the brief opens with a poll/fetch verb, P(haiku) >= 0.8 and security < 0.5 (the haiku-keep rule
# in policy.jq; the hook cannot see route.sh's `kind`).
#
# JEV_ROUTE_MODE=off turns it off. No permissionDecision is returned, so
# permission rules apply as usual. Fails open: any problem -> exit 0, no output.
# Every decision goes to $JEV_HOME/log/route.jsonl; artifact-hook.sh tells the
# parent which model ran (PostToolUse additionalContext).
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=agent-route
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

[ "${JEV_ROUTE_MODE:-escalate}" = off ] && exit 0
jev_disabled && exit 0
jev_in_scope || exit 0

payload=$(cat)
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
input=$(jq -c '.tool_input // {}' <<<"$payload")
given=$(jq -r '.model // empty' <<<"$input")
stype=$(jq -r '.subagent_type // empty' <<<"$input")
desc=$(jq -r '.description // empty' <<<"$input")
tuid=$(jq -r '.tool_use_id // empty' <<<"$payload")

log_decision() { # <action> [route-json] [final] [reason]
  jev_log route.jsonl "$(jq -cn --arg action "$1" --arg given "$given" --arg stype "$stype" \
    --arg desc "${desc:0:120}" --arg final "${3:-}" --arg reason "${4:-}" --arg tuid "$tuid" --argjson r "${2:-null}" '{
      action: $action, tool_use_id: (if $tuid == "" then null else $tuid end),
      subagent_type: $stype, given_model: $given,
      route_id: ($r.id // null), jev_model: ($r.model // null),
      final_model: (if $final == "" then null else $final end),
      reviewer_model: ($r.reviewer_model // null), confidence: ($r.confidence // null),
      probabilities: ($r.probabilities // null), policy: ($r.policy // null), description: $desc}
      + (if $reason == "" then {} else {reason: $reason} end)')"
}
rank() { case $1 in haiku) echo 0 ;; sonnet) echo 1 ;; opus) echo 2 ;; *) echo 9 ;; esac; }
raise() { # <action> <route-json> <tier> <reason>
  log_decision "$1" "$2" "$3" "$4"
  jq -cn --argjson input "$input" --arg model "$3" '{
    hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: ($input + {model: $model})}}'
}

# Decide whether this call could change at all before spending an API call.
skip=""
if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then skip=skip_subagent_model_env
elif [ "$stype" = fork ]; then skip=skip_fork
elif [ -z "$given" ]; then skip=skip_no_model
elif [ "$given" = opus ]; then skip=kept_opus
elif [ "$(rank "$given")" -ge 9 ]; then skip=skip_has_model
else case $stype in *:*) skip=skip_plugin_agent ;; esac; fi
if [ -n "$skip" ]; then
  log_decision "$skip"
  exit 0
fi

# Routed already: a "Route: <id>" line whose id route.sh logged. Take that
# answer, never a second opinion. An id not in route.jsonl is not trusted.
rid=$(jq -r '[.description // "", .prompt // ""] | join("\n")' <<<"$input" |
  sed -n -E 's/^[[:space:]]*Route:[[:space:]]*(r[0-9]{9,}-[0-9]+-[0-9]+)[[:space:]]*$/\1/p' | tail -n 1 || true)
tier=""
if [ -n "$rid" ]; then
  routed=$(grep -F "\"id\":\"$rid\"" "$JEV_LOG_DIR/route.jsonl" 2>/dev/null | jq -c 'select(.action == "route")' 2>/dev/null | tail -n 1 || true)
  [ -z "$routed" ] || tier=$(jq -r '.model // empty' <<<"$routed" 2>/dev/null || true)
fi
if [ -n "$tier" ] && [ "$(rank "$tier")" -lt 9 ]; then
  if [ "$(rank "$given")" -lt "$(rank "$tier")" ]; then
    raise raised_to_route "$routed" "$tier" "route $rid said $tier; $given is lower"
  else
    log_decision kept_routed "$routed" "$given" "route $rid"
  fi
  exit 0
fi

text=$(jq -r '[(.description // ""), (if .subagent_type then "subagent_type: " + .subagent_type else empty end), (.prompt // "")] | map(select(. != "")) | join("\n\n")' <<<"$input")
[ -n "$text" ] || exit 0
hctx=$(jq -c -L "$JEV_DIR" 'include "policy"; hook_context' <<<"$input" 2>/dev/null || echo '{}')
if ! route=$(printf '%s' "$text" | JEV_ROUTE_NO_LOG=1 JEV_TIMEOUT=${JEV_ROUTE_TIMEOUT:-4} "$JEV_DIR/route.sh" --context "$hctx" 2>/dev/null); then
  log_decision route_failed
  exit 0
fi
tier=$(jq -r '.model' <<<"$route")
[ "$(rank "$tier")" -lt 9 ] || exit 0
if [ "$(rank "$given")" -ge "$(rank "$tier")" ]; then
  log_decision kept "$route" "$given"
  exit 0
fi
raise escalated "$route" "$tier" "$(jq -r --arg from "$given" --arg to "$tier" '"jev: \($from)→\($to) (" + ((.policy // []) | join("; ")) + ")"' <<<"$route")"
