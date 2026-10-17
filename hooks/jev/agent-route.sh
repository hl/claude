#!/usr/bin/env bash
# agent-route.sh — PreToolUse hook for the Agent tool. Asks route.sh (Jev) for a
# tier, logs it, and in the opt-in modes sets tool_input.model via updatedInput.
#
# JEV_ROUTE_MODE:
#   log (default)   decide and log to route.jsonl, change nothing
#   fill            set a model on calls that have none, for allowlisted agent
#                   types only (see below); never below sonnet, because a
#                   model-less call would otherwise inherit the parent's model
#   escalate        fill, and also raise an explicit haiku/sonnet/opus model when
#                   Jev's tier (after policy) is higher. Never lowers. "fable",
#                   "inherit" and other full IDs are left alone.
#   off             do nothing
#
# Fill allowlist: a per-call model beats an agent's frontmatter model, so a
# model is only filled where nothing is pinned:
#   - subagent_type in JEV_ROUTE_FILL_TYPES (default "general-purpose"; an
#     empty subagent_type counts as general-purpose), or
#   - a custom agent whose definition file was found (by frontmatter `name:`
#     in $CLAUDE_PROJECT_DIR, cwd, or ${CLAUDE_CONFIG_DIR:-~/.claude} agents/)
#     and has no `model:` line.
# Anything unresolved (plugin "x:y" agents, --agents/SDK agents, built-ins
# outside the allowlist) is skipped. With CLAUDE_CODE_SUBAGENT_MODEL set, the
# hook never changes a model (a per-call model would override that env).
#
# No permissionDecision is returned: the normal permission flow applies and
# updatedInput is still honoured (verified on 2.1.302). Fails open: any
# problem -> exit 0, no output. Every decision goes to ~/.claude/jev/log/route.jsonl.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=agent-route
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

mode=${JEV_ROUTE_MODE:-log}
case $mode in fill | escalate | log) ;; *) exit 0 ;; esac
jev_disabled && exit 0

payload=$(cat)
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
input=$(jq -c '.tool_input // {}' <<<"$payload")
given=$(jq -r '.model // empty' <<<"$input")
stype=$(jq -r '.subagent_type // empty' <<<"$input")
desc=$(jq -r '.description // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$payload")

log_decision() { # <action> [route-json] [final] [reason]
  jev_log route.jsonl "$(jq -cn --arg action "$1" --arg mode "$mode" --arg given "$given" \
    --arg stype "$stype" --arg desc "${desc:0:120}" --arg final "${3:-}" --arg reason "${4:-}" \
    --arg fill "$fill_ok" --argjson r "${2:-null}" '{
      action: $action, mode: $mode, subagent_type: $stype, given_model: $given,
      fill_eligible: ($fill == "yes"),
      jev_model: ($r.model // null), final_model: (if $final == "" then null else $final end),
      confidence: ($r.confidence // null), policy: ($r.policy // null),
      signals: ($r.signals // null), description: $desc}
      + (if $reason == "" then {} else {reason: $reason} end)')"
}

# frontmatter_field <file> <field>: value of a top-level frontmatter field, unquoted.
frontmatter_field() {
  awk -v k="$2" '
    /^---[[:space:]]*$/ { n++; if (n == 2) exit; next }
    n == 1 && $0 ~ "^" k ":" { sub("^" k ":[[:space:]]*", ""); gsub(/["\047]/, ""); sub(/[[:space:]]+$/, ""); print; exit }
  ' "$1"
}

# fill_status -> "yes" | a skip reason. Only meaningful for calls without a model.
fill_status() {
  local t=${stype:-general-purpose} d f
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then echo skip_subagent_model_env; return; fi
  case ",${JEV_ROUTE_FILL_TYPES:-general-purpose}," in *",$t,"*) echo yes; return ;; esac
  case $t in *:*) echo skip_unresolved_plugin; return ;; esac
  for d in ${CLAUDE_PROJECT_DIR:+"$CLAUDE_PROJECT_DIR/.claude/agents"} ${cwd:+"$cwd/.claude/agents"} \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      [ "$(frontmatter_field "$f" name)" = "$t" ] || continue
      if [ -n "$(frontmatter_field "$f" model)" ]; then echo skip_pinned_model; else echo yes; fi
      return
    done
  done
  echo skip_unresolved_type
}

fill_ok=no
if [ -z "$given" ]; then
  fill_ok=$(fill_status)
fi

# Tier of the model the caller asked for: haiku/sonnet/opus alias or full ID.
case $given in
  '') given_rank=-1 ;;
  *haiku*) given_rank=0 ;;
  *sonnet*) given_rank=1 ;;
  *opus*) given_rank=2 ;;
  *) given_rank=9 ;; # fable, inherit, unknown IDs: never touch
esac

# Decide whether this call could change at all before spending an API call.
if [ "$mode" != log ]; then
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
    fill_ok=skip_subagent_model_env
    log_decision skip_subagent_model_env
    exit 0
  fi
  if [ -z "$given" ] && [ "$fill_ok" != yes ]; then
    log_decision "$fill_ok"
    exit 0
  fi
  if [ -n "$given" ] && { [ "$mode" = fill ] || [ "$given_rank" -ge 9 ]; }; then
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

# A model-less call would have inherited the parent's model: never fill below sonnet.
if [ -z "$given" ] && [ "$jev_rank" -lt 1 ]; then
  tier=sonnet jev_rank=1
fi

if [ "$mode" = log ]; then
  log_decision logged "$route" "$tier"
  exit 0
fi
if [ "$given_rank" -ge "$jev_rank" ]; then
  log_decision kept "$route" "$given"
  exit 0
fi

action=filled
[ -n "$given" ] && action=escalated
reason=$(jq -r --arg from "${given:-none}" --arg to "$tier" '
  (.signals | to_entries | max_by(.value)) as $top
  | "jev: \($from)→\($to) (jev \(.model), conf \(.confidence), \($top.key) \($top.value)" +
    (if .policy == "as_is" then "" else ", " + .policy end) + ")"' <<<"$route")
out=$(jq -cn --argjson input "$input" --arg model "$tier" '{
  hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: ($input + {model: $model})}}')
log_decision "$action" "$route" "$tier" "$reason"
printf '%s\n' "$out"
