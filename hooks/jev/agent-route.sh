#!/usr/bin/env bash
# agent-route.sh — PreToolUse hook for the Agent tool. Asks route.sh (Jev) for a
# tier, logs it, and may raise the subagent's model via updatedInput.
#
# JEV_ROUTE_MODE:
#   escalate (default)  raise an explicit alias model ("haiku", "sonnet") when
#                       route.sh's tier is higher AND Jev is at least
#                       JEV_ROUTE_MIN_ESCALATE_CONF (0.7) sure the given tier
#                       falls short (route.sh's `above`). Never lowers. Acts
#                       only on the exact aliases haiku|sonnet|opus: model-less
#                       calls (frontmatter / inherit semantics), full model IDs,
#                       "fable", "inherit", subagent_type "fork", plugin "x:y"
#                       agents and sessions with CLAUDE_CODE_SUBAGENT_MODEL set
#                       are left alone. Model-less calls are still routed and
#                       logged, so route.jsonl shows what Jev would have picked.
#   fill                escalate, plus set a model on model-less calls of
#                       allowlisted agent types (see below), never below sonnet
#                       because a model-less call would otherwise inherit the
#                       parent's model
#   log                 decide and log to route.jsonl, change nothing
#   off                 do nothing, send nothing
#
# Fill allowlist: a per-call model beats an agent's frontmatter model, so a
# model is only filled where nothing is pinned:
#   - subagent_type in JEV_ROUTE_FILL_TYPES (default "general-purpose"; an
#     empty subagent_type counts as general-purpose), or
#   - a custom agent whose definition file was found (by frontmatter `name:`
#     in $CLAUDE_PROJECT_DIR, cwd, or ${CLAUDE_CONFIG_DIR:-~/.claude} agents/)
#     and has no `model:` line.
#
# No permissionDecision is returned: the normal permission flow applies and
# updatedInput is still honoured (verified on 2.1.302). Fails open: any
# problem -> exit 0, no output. Every decision goes to ~/.local/state/jev/log/route.jsonl
# with the reason; that file is the only place that shows the model that ran.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=agent-route
export JEV_ENTRY=hook # a hook run: lib.sh may move an old ~/.claude/jev
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

mode=${JEV_ROUTE_MODE:-escalate}
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
tuid=$(jq -r '.tool_use_id // empty' <<<"$payload")

log_decision() { # <action> [route-json] [final] [reason]
  jev_log route.jsonl "$(jq -cn --arg action "$1" --arg mode "$mode" --arg given "$given" \
    --arg stype "$stype" --arg desc "${desc:0:120}" --arg final "${3:-}" --arg reason "${4:-}" \
    --arg fill "$fill_ok" --arg tuid "$tuid" --argjson r "${2:-null}" '{
      action: $action, mode: $mode, tool_use_id: (if $tuid == "" then null else $tuid end),
      subagent_type: $stype, given_model: $given,
      fill_eligible: ($fill == "yes"),
      route_id: ($r.id // null), jev_model: ($r.model // null),
      final_model: (if $final == "" then null else $final end),
      reviewer_model: ($r.reviewer_model // null), deepen: ($r.deepen // null),
      confidence: ($r.confidence // null), probabilities: ($r.probabilities // null),
      above: ($r.above // null), policy: ($r.policy // null),
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
# The allowlist lookup only matters when fill may act.
if [ -z "$given" ] && [ "$mode" = fill ]; then
  fill_ok=$(fill_status)
fi

# Tier of the model the caller asked for. Only the exact aliases can be raised.
case $given in
  '') given_rank=-1 ;;
  haiku) given_rank=0 ;;
  sonnet) given_rank=1 ;;
  opus) given_rank=2 ;;
  *) given_rank=9 ;; # full IDs, fable, inherit, anything else: never touch
esac

# Decide whether this call could change at all before spending an API call.
if [ "$mode" != log ]; then
  skip=""
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then skip=skip_subagent_model_env
  elif [ "$stype" = fork ]; then skip=skip_fork
  elif [ -n "$given" ] && [ "$given_rank" -ge 9 ]; then skip=skip_has_model
  elif [ -n "$given" ]; then
    case $stype in *:*) skip=skip_plugin_agent ;; esac
    [ "$given_rank" -ge 2 ] && skip=kept_opus
  elif [ "$mode" = fill ] && [ "$fill_ok" != yes ]; then skip=$fill_ok
  fi
  if [ -n "$skip" ]; then
    [ "$skip" = skip_subagent_model_env ] && fill_ok=skip_subagent_model_env
    log_decision "$skip"
    exit 0
  fi
fi

text=$(jq -r '[(.description // ""), (if .subagent_type then "subagent_type: " + .subagent_type else empty end), (.prompt // "")] | map(select(. != "")) | join("\n\n")' <<<"$input")
[ -n "$text" ] || exit 0

if ! route=$(printf '%s' "$text" | JEV_ROUTE_NO_LOG=1 JEV_TIMEOUT=${JEV_ROUTE_TIMEOUT:-4} "$JEV_DIR/route.sh" 2>/dev/null); then
  log_decision route_failed
  exit 0
fi
tier=$(jq -r '.model' <<<"$route")
case $tier in haiku) jev_rank=0 ;; sonnet) jev_rank=1 ;; opus) jev_rank=2 ;; *) exit 0 ;; esac

# A model-less call would have inherited the parent's model: never fill below sonnet.
if [ -z "$given" ] && [ "$jev_rank" -lt 1 ]; then
  tier=sonnet jev_rank=1
fi

# Model-less calls are only ever changed in fill mode; everything else is logged.
if [ "$mode" = log ] || { [ -z "$given" ] && [ "$mode" != fill ]; }; then
  log_decision logged "$route" "$tier"
  exit 0
fi
if [ "$given_rank" -ge "$jev_rank" ]; then
  log_decision kept "$route" "$given"
  exit 0
fi
# An explicit choice is only overridden when Jev is sure enough it falls short.
if [ -n "$given" ]; then
  conf=$(jq -r --arg g "$given" '.above[$g] // 0' <<<"$route")
  if ! awk -v c="$conf" -v m="${JEV_ROUTE_MIN_ESCALATE_CONF:-0.7}" 'BEGIN { exit !(c >= m) }'; then
    log_decision kept_low_conf "$route" "$given" "jev: would raise $given→$tier but only $conf sure $given falls short (< ${JEV_ROUTE_MIN_ESCALATE_CONF:-0.7})"
    exit 0
  fi
fi

action=filled
[ -n "$given" ] && action=escalated
reason=$(jq -r --arg from "${given:-none}" --arg to "$tier" '
  "jev: \($from)→\($to) (" + ((.policy // []) | join("; ")) + (if $from != "none" then "; \($from) falls short p=\(.above[$from] // "?")" else "" end) + ")"' <<<"$route")
out=$(jq -cn --argjson input "$input" --arg model "$tier" '{
  hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: ($input + {model: $model})}}')
log_decision "$action" "$route" "$tier" "$reason"
printf '%s\n' "$out"
