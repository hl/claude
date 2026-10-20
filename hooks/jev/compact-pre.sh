#!/usr/bin/env bash
# compact-pre.sh — PreCompact hook. Extracts the facts compaction must not lose
# from the records after the last compact boundary (extract.jq: user messages,
# decisions, paths, URLs, branches, the failing command, open items, and facts
# an earlier compaction re-injected) and asks Jev, in ONE request, how much each
# must survive. Writes ~/.local/state/jev/compact/<session_id>.json for
# compact-post.sh (coverage) and compact-session.sh (injection).
#
# Only in Claudette sessions or with JEV_SCOPE=all (lib.sh jev_in_scope);
# elsewhere it exits before reading the transcript and compact-session.sh
# still injects the .orchestrator.md sections and the artifact index.
#
#   compact-pre.sh                       hook mode (PreCompact JSON on stdin)
#   compact-pre.sh --extract <jsonl>     print extracted facts + tail, no API call
#
# Knobs: JEV_COMPACT_MAX_FACTS (60), JEV_COMPACT_TAIL_CHARS (40000),
#        JEV_COMPACT_GUARD=1 (block one auto-compaction per session when the last
#        turn looks mid-operation; see README for the context-limit caveat),
#        JEV_COMPACT_GUARD_MIN (0.85).
# Fails open: never blocks or breaks compaction unless the guard is on and fires.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=compact-pre
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MAX_FACTS=${JEV_COMPACT_MAX_FACTS:-60}
TAIL_CHARS=${JEV_COMPACT_TAIL_CHARS:-40000}

extract() { # <transcript.jsonl> -> {facts, tail}
  local tp=$1 start
  start=$(grep -n '"subtype":"compact_boundary"' "$tp" | tail -n 1 | cut -d: -f1 || true)
  tail -n +"${start:-1}" "$tp" |
    jq -cR -f "$JEV_DIR/slim.jq" |
    jq -s -c --argjson max "$MAX_FACTS" --argjson tail_chars "$TAIL_CHARS" -f "$JEV_DIR/extract.jq"
}

if [ "${1:-}" = --extract ]; then
  trap - EXIT
  extract "${2:?usage: compact-pre.sh --extract <transcript.jsonl>}"
  exit $?
fi

jev_disabled && exit 0
payload=$(cat)
# A subagent compacting its own context carries agent_id and the parent's
# session_id; it must not overwrite the parent's state file.
[ -z "$(jq -r '.agent_id // empty' <<<"$payload")" ] || exit 0
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
case $JEV_SESSION in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
jev_sweep "$JEV_SESSION"
jev_in_scope || exit 0
tp=$(jq -r '.transcript_path // empty' <<<"$payload")
trigger=$(jq -r '.trigger // "unknown"' <<<"$payload")
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

state_dir="$JEV_HOME/compact"
state="$state_dir/$JEV_SESSION.json"
mkdir -p "$state_dir"
prev_blocked=$(jq -r '.guard_blocked // false' "$state" 2>/dev/null || echo false)

ex=$(extract "$tp") || exit 0
nfacts=$(jq '.facts | length' <<<"$ex")
[ "$nfacts" -gt 0 ] || {
  jev_log compact.jsonl '{"event":"pre","status":"no_facts"}'
  exit 0
}

# Keep state + one question under the per-question token limit.
budget=$(jev_state_budget_chars 1500)
facts_chars=$(jq '[.facts[] | .text | length + 6] | add' <<<"$ex")
tail_max=$((budget - facts_chars))
[ "$tail_max" -gt 0 ] || tail_max=0

# One request: a score per fact, plus whether the last turn is mid-operation.
answers=$(jq -c --arg model "$JEV_MODEL" --argjson tail_max "$tail_max" '
  {
    model: $model,
    state: {
      facts: [.facts[] | "\(.n). \(.text)"],
      recent_transcript_tail: (if (.tail | length) > $tail_max then .tail[-$tail_max:] else .tail end)
    },
    questions: (
      ([.facts[] | {
        key: "f\(.n)",
        value: {
          type: "score",
          instructions: "Fact \(.n) in `facts`: \"\(.text)\". This session is about to be compacted into a short summary and will continue from it. How much must fact \(.n) survive compaction for the rest of the session to go correctly? Constraints and context the user stated (names, hosts, ports, tickets, branches, rules), decisions and open items keep mattering for the whole session even when the latest step does not use them. Finished one-off steps and tool noise do not.",
          criteria: [
            "Irrelevant: not needed to continue the work, or already obsolete",
            "Nice to have: useful background; the work continues correctly without it",
            "Important: needed to continue correctly; losing it means re-discovering it",
            "Critical: losing it causes rework, a wrong decision or a repeated mistake"
          ]
        }}] | from_entries)
      + {mid_operation: {
          type: "noul",
          instructions: "In `recent_transcript_tail`, the most recent turn is in the middle of an edit, command or review whose result has not been recorded yet."
        }})
  }' <<<"$ex" | jev_call | jq -c '.answers' 2>/dev/null || echo null)
jev_ok=true
if [ "$answers" = null ] || ! jq -e --argjson n "$nfacts" '[range(1; $n + 1) as $i | has("f\($i)")] | all' <<<"$answers" >/dev/null 2>&1; then
  jev_ok=false
  answers=null
fi

new_state=$(jq -c --arg sid "$JEV_SESSION" --arg trigger "$trigger" --arg tp "$tp" --arg at "$(jev_now)" \
  --argjson epoch "$(date +%s)" --argjson ok "$jev_ok" --argjson a "$answers" --argjson blocked "$prev_blocked" '
  {
    session_id: $sid, trigger: $trigger, transcript_path: $tp,
    extracted_at: $at, extracted_epoch: $epoch, phase: "pre", jev_ok: $ok,
    guard_blocked: $blocked,
    mid_operation: ($a.mid_operation.noul // null),
    facts: ([.facts[] | . as $f | ($a["f\(.n)"] // null) as $s
             | $f + {score: ($s.score // null),
                     legend: (if $s then $s.legend[($s.score | round | tostring)] | split(":")[0] else null end)}]
            | sort_by(-(.score // -1), -.n))
  }' <<<"$ex")

# Optional guard: block one auto-compaction per session that lands mid-operation.
block=false
if [ "${JEV_COMPACT_GUARD:-0}" = 1 ] && [ "$trigger" = auto ] && [ "$jev_ok" = true ] && [ "$prev_blocked" != true ] &&
  jq -e --argjson min "${JEV_COMPACT_GUARD_MIN:-0.85}" '.mid_operation >= $min' <<<"$new_state" >/dev/null; then
  block=true
  new_state=$(jq -c '.guard_blocked = true | .phase = "blocked"' <<<"$new_state")
fi

printf '%s\n' "$new_state" >"$state.tmp" && mv "$state.tmp" "$state"
jev_log compact.jsonl "$(jq -c --arg block "$block" '{event: "pre", status: (if .jev_ok then "ok" else "jev_failed" end),
  trigger, facts: (.facts | length), mid_operation, blocked: ($block == "true"),
  scores: [.facts[] | {n, kind, score}]}' <<<"$new_state")"

if [ "$block" = true ]; then
  echo "jev: compaction deferred once — the last turn looks mid-operation (an edit, command or review without a recorded result). It will run at the next opportunity." >&2
  trap - EXIT
  exit 2
fi
