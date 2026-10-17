#!/usr/bin/env bash
# compact-post.sh — checks which extracted facts the compaction summary kept.
#
# Registered on two events, same script:
#   SubagentStop (agent_type "")  the compaction agent finishing; its
#                                  last_assistant_message is the summary. This
#                                  fires BEFORE SessionStart(compact), so the
#                                  session hook can use the coverage.
#   PostCompact                    compact_summary; fires AFTER SessionStart(compact)
#                                  (observed on 2.1.302). Records coverage/quality
#                                  for the log; skips the Jev call if the
#                                  SubagentStop pass already covered this summary.
#
# One Jev request (two if many facts): per fact a noul "fact N is fully preserved
# in `summary`", plus a 1–5 summary_quality score. Updates the state file.
# Fails open: exit 0, no output, always.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=compact-post
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

SPLIT=${JEV_COMPACT_SPLIT:-40}
MAX_AGE=${JEV_COMPACT_MAX_AGE:-3600}

jev_disabled && exit 0
payload=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$payload")
# Fast exit for every ordinary subagent (this runs on all SubagentStops).
[ "$event" = SubagentStop ] && [ -n "$(jq -r '.agent_type // empty' <<<"$payload")" ] && exit 0
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
[ -n "$JEV_SESSION" ] || exit 0
state="$JEV_HOME/compact/$JEV_SESSION.json"
[ -f "$state" ] || exit 0
jq -e '.jev_ok == true and (.facts | length) > 0' "$state" >/dev/null 2>&1 || exit 0
age=$(($(date +%s) - $(jq -r '.extracted_epoch // 0' "$state")))
[ "$age" -le "$MAX_AGE" ] || exit 0

case $event in
  SubagentStop)
    # Only the compaction agent: no agent type, a pending pre-compaction state,
    # and a summary in the compaction format.
    [ -z "$(jq -r '.agent_type // empty' <<<"$payload")" ] || exit 0
    jq -e '.phase == "pre"' "$state" >/dev/null || exit 0
    summary=$(jq -r '.last_assistant_message // empty' <<<"$payload")
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

nfacts=$(jq '.facts | length' "$state")
build_req() { # <first-index> <last-index> (0-based, inclusive) <with-quality>
  jq -c --arg model "$JEV_MODEL" --arg summary "$summary" --argjson from "$1" --argjson to "$2" --argjson q "$3" '
    {
      model: $model,
      state: {summary: $summary, facts: [.facts | sort_by(.n)[] | "\(.n). \(.text)"]},
      questions: ((
        [.facts[$from:$to + 1][] | {
          key: "c\(.n)",
          value: {
            type: "noul",
            instructions: "Fact \(.n) in `facts`: \"\(.text)\". `summary` fully preserves fact \(.n) with the same specifics (names, paths, numbers, decisions).",
            criteria: {
              true: "`summary` states this fact, or something that clearly implies it, keeping the exact names, paths, numbers and decisions",
              false: "`summary` omits this fact or loses one of its specifics"
            }
          }}] | from_entries
      ) + (if $q then {
        summary_quality: {
          type: "score",
          instructions: "How well does `summary` preserve the specifics in `facts` that matter for continuing the work?",
          criteria: ["1: loses most specifics needed to continue", "2: loses several important specifics",
                     "3: keeps the main thread but drops some specifics", "4: keeps nearly all important specifics",
                     "5: keeps every important specific"]
        }} else {} end))
    }' "$state"
}

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/jev-post.XXXXXX")
trap 'rm -rf "$tmpd"; exit 0' EXIT
if [ "$nfacts" -le "$SPLIT" ]; then
  build_req 0 $((nfacts - 1)) true | jev_call >"$tmpd/r1.json" || : >"$tmpd/r1.json"
else
  half=$(((nfacts + 1) / 2))
  { build_req 0 $((half - 1)) true | jev_call >"$tmpd/r1.json" || : >"$tmpd/r1.json"; } &
  { build_req "$half" $((nfacts - 1)) false | jev_call >"$tmpd/r2.json" || : >"$tmpd/r2.json"; } &
  wait
fi
answers=$(cat "$tmpd"/r*.json | jq -s -c 'if length == 0 then null else (map(.answers) | add) end' 2>/dev/null || echo null)
if [ "$answers" = null ] || ! jq -e --slurpfile s "$state" '[$s[0].facts[] | "c\(.n)"] as $k | [$k[] as $x | has($x)] | all' <<<"$answers" >/dev/null; then
  jev_log compact.jsonl "$(jq -cn --arg e "$event" '{event: "post", source: $e, status: "jev_failed"}')"
  exit 0
fi

new_state=$(jq -c --argjson a "$answers" --arg id "$sum_id" --arg e "$event" --arg at "$(jev_now)" \
  --argjson min "${JEV_COMPACT_COVERED_MIN:-0.5}" '
  .facts |= map(. + {covered_p: $a["c\(.n)"].noul, covered: ($a["c\(.n)"].noul >= $min)})
  | .phase = (if .phase == "pre" then "covered" else .phase end)
  | .coverage = {summary_id: $id, source: $e, at: $at,
                 summary_quality: (if $a.summary_quality then (($a.summary_quality.score + 1) * 100 | round / 100) else null end)}' "$state")
printf '%s\n' "$new_state" >"$state.tmp" && mv "$state.tmp" "$state"
jev_log compact.jsonl "$(jq -c --arg e "$event" '{event: "post", source: $e, status: "ok",
  summary_quality: .coverage.summary_quality,
  covered: [.facts[] | select(.covered) | .n], missing: [.facts[] | select(.covered | not) | .n]}' <<<"$new_state")"
