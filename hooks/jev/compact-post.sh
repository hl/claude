#!/usr/bin/env bash
# compact-post.sh — checks which extracted facts the compaction summary kept.
#
# Registered on two events, same script:
#   SubagentStop (agent_type "")  the compaction agent finishing; its
#                                  last_assistant_message is the summary. This
#                                  fires BEFORE SessionStart(compact), so the
#                                  session hook can use the coverage.
#   PostCompact                    compact_summary; fires AFTER SessionStart(compact)
#                                  (observed on 2.1.302). Skips the Jev call if the
#                                  SubagentStop pass already covered this summary.
#
# Acts only when compact-pre.sh left a scored state file for this session (so
# only in Claudette sessions or with JEV_SCOPE=all). ONE Jev request per
# compaction: per fact a noul "fact N is fully preserved in `summary`". Updates
# the state file. Fails open: exit 0, no output, always.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=compact-post
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MAX_AGE=${JEV_COMPACT_MAX_AGE:-3600}

jev_disabled && exit 0
payload=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$payload")
# Fast exit for every ordinary subagent (this runs on all SubagentStops).
[ "$event" = SubagentStop ] && [ -n "$(jq -r '.agent_type // empty' <<<"$payload")" ] && exit 0
jev_in_scope || exit 0
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
case $JEV_SESSION in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
state="$JEV_HOME/compact/$JEV_SESSION.json"
[ -f "$state" ] || exit 0
jq -e '.jev_ok == true and (.facts | length) > 0' "$state" >/dev/null 2>&1 || exit 0
age=$(($(date +%s) - $(jq -r '.extracted_epoch // 0' "$state")))
[ "$age" -le "$MAX_AGE" ] || exit 0

case $event in
  SubagentStop)
    # Only the compaction agent: no agent type, a pending pre-compaction state,
    # and a summary in the compaction format.
    jq -e '.phase == "pre"' "$state" >/dev/null || exit 0
    summary=$(jq -r '.last_assistant_message // empty' <<<"$payload")
    if [ -z "$summary" ]; then
      # Claude Code 2.1.304 leaves last_assistant_message out for some agents; read the transcript.
      atp=$(jq -r '.agent_transcript_path // empty' <<<"$payload")
      if [ -n "$atp" ] && [ -f "$atp" ]; then
        summary=$(jq -cR 'fromjson? | select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | join("\n")' "$atp" 2>/dev/null |
          jq -s -r 'map(select(length > 0)) | last // empty' 2>/dev/null || true)
      fi
    fi
    case $summary in *"<summary>"*) ;; *) exit 0 ;; esac
    ;;
  PostCompact)
    # A subagent's own compaction carries agent_id; the state belongs to the parent.
    [ -z "$(jq -r '.agent_id // empty' <<<"$payload")" ] || exit 0
    summary=$(jq -r '.compact_summary // empty' <<<"$payload")
    ;;
  *) exit 0 ;;
esac
[ -n "$summary" ] || exit 0

sum_id=$(printf '%s' "$summary" | cksum | tr -s ' ' '-')
if jq -e --arg id "$sum_id" '.coverage.summary_id == $id' "$state" >/dev/null; then
  jev_log compact.jsonl "$(jq -cn --arg e "$event" '{event: "post", source: $e, status: "already_covered"}')"
  exit 0
fi
# PostCompact fires after SessionStart(compact): once the state is consumed or
# covered, a coverage answer would never be read, so nothing is sent.
if ! jq -e '.phase == "pre" and (.consumed_at // null) == null' "$state" >/dev/null; then
  jev_log compact.jsonl "$(jq -cn --arg e "$event" '{event: "post", source: $e, status: "state_consumed"}')"
  exit 0
fi

# What stays in context is the <summary> part; the <analysis> scratchpad is dropped.
case $summary in
  *"<summary>"*)
    summary=${summary#*<summary>}
    summary=${summary%%</summary>*}
    ;;
esac
budget=$(jev_state_budget_chars 1500)
facts_chars=$(jq '[.facts[] | .text | length + 6] | add' "$state")
max_sum=$((budget - facts_chars))
[ "$max_sum" -gt 1000 ] || max_sum=1000
summary=${summary:0:$max_sum}

answers=$(jq -c --arg model "$JEV_MODEL" --arg summary "$summary" '
  {
    model: $model,
    state: {summary: $summary, facts: [.facts | sort_by(.n)[] | "\(.n). \(.text)"]},
    questions: ([.facts[] | {
      key: "c\(.n)",
      value: {
        type: "noul",
        instructions: "Fact \(.n) in `facts`: \"\(.text)\". `summary` fully preserves fact \(.n) with the same specifics (names, paths, numbers, decisions).",
        criteria: {
          true: "`summary` states this fact, or something that clearly implies it, keeping the exact names, paths, numbers and decisions",
          false: "`summary` omits this fact or loses one of its specifics"
        }
      }}] | from_entries)
  }' "$state" | jev_call | jq -c '.answers' 2>/dev/null || echo null)
if [ "$answers" = null ] || ! jq -e --slurpfile s "$state" '[$s[0].facts[] | "c\(.n)"] as $k | [$k[] as $x | has($x)] | all' <<<"$answers" >/dev/null 2>&1; then
  jev_log compact.jsonl "$(jq -cn --arg e "$event" '{event: "post", source: $e, status: "jev_failed"}')"
  exit 0
fi

new_state=$(jq -c --argjson a "$answers" --arg id "$sum_id" --arg e "$event" --arg at "$(jev_now)" \
  --argjson min "${JEV_COMPACT_COVERED_MIN:-0.5}" '
  .facts |= map(. + {covered_p: $a["c\(.n)"].noul, covered: ($a["c\(.n)"].noul >= $min)})
  | .phase = (if .phase == "pre" then "covered" else .phase end)
  | .coverage = {summary_id: $id, source: $e, at: $at}' "$state")
printf '%s\n' "$new_state" >"$state.tmp" && mv "$state.tmp" "$state"
jev_log compact.jsonl "$(jq -c --arg e "$event" '{event: "post", source: $e, status: "ok",
  covered: [.facts[] | select(.covered) | .n], missing: [.facts[] | select(.covered | not) | .n]}' <<<"$new_state")"
