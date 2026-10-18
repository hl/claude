#!/usr/bin/env bash
# compact-pre.sh — PreCompact hook. Final ledger flush, then a snapshot of the
# facts compaction must not lose, for compact-post.sh / compact-session.sh in
# ~/.claude/jev/compact/<session_id>.json.
#
# Ledger mode (default): runs ledger.sh --flush (the same incremental step the
# Stop hook runs, waiting for a running one), then snapshots the live,
# non-superseded ledger facts scored >= JEV_COMPACT_MIN_SCORE (critical ones
# first, then the most recent, up to JEV_COMPACT_MAX_FACTS, listed in ledger
# order). No Jev call of its own: the ledger already scored everything up to
# the last turn, so a lagging transcript costs nothing.
#
# v1 mode (JEV_LEDGER=0, or no ledger facts for this session): extracts
# candidate facts from the records after the last compact boundary and asks
# Jev to rank them, as before.
#
#   compact-pre.sh                       hook mode (PreCompact JSON on stdin)
#   compact-pre.sh --extract <jsonl>     print extracted facts + tail, no API call
#
# Knobs: JEV_COMPACT_MAX_FACTS (60), JEV_COMPACT_TAIL_CHARS (40000),
#        JEV_COMPACT_SPLIT (40: facts per Jev request),
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
SPLIT=${JEV_COMPACT_SPLIT:-40}

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
tp=$(jq -r '.transcript_path // empty' <<<"$payload")
trigger=$(jq -r '.trigger // "unknown"' <<<"$payload")
[ -n "$JEV_SESSION" ] && [ -n "$tp" ] && [ -f "$tp" ] || exit 0

state_dir="$JEV_HOME/compact"
state="$state_dir/$JEV_SESSION.json"
mkdir -p "$state_dir"
prev_blocked=$(jq -r '.guard_blocked // false' "$state" 2>/dev/null || echo false)
MIN_SCORE=${JEV_COMPACT_MIN_SCORE:-1.5}

# guard_check <tail-text>: echoes the mid_operation probability (or nothing).
guard_check() {
  jq -cn --arg model "$JEV_MODEL" --arg tail "$1" '{model: $model, state: {recent_transcript_tail: $tail},
    questions: {mid_operation: {type: "noul",
      instructions: "In `recent_transcript_tail`, the most recent turn is in the middle of an edit, command or review whose result has not been recorded yet."}}}' |
    jev_call | jq -r '.answers.mid_operation.noul // empty' 2>/dev/null || true
}

# --- ledger mode
ledger="$JEV_HOME/ledger/$JEV_SESSION.jsonl"
if [ "${JEV_LEDGER:-1}" != 0 ]; then
  JEV_HOOK=ledger-flush "$JEV_DIR/ledger.sh" --flush <<<"$payload" || true
  if [ -s "$ledger" ] && jq -e -s 'any(.[]; .superseded_by == null and .kind != "artifact")' "$ledger" >/dev/null 2>&1; then
    mid=null
    if [ "${JEV_COMPACT_GUARD:-0}" = 1 ] && [ "$trigger" = auto ] && [ "$prev_blocked" != true ]; then
      tail_text=$(extract "$tp" | jq -r '.tail' 2>/dev/null | tail -c "${JEV_COMPACT_TAIL_CHARS:-40000}" || true)
      m=$(guard_check "$tail_text")
      [ -n "$m" ] && mid=$m
    fi
    new_state=$(jq -s -c --arg sid "$JEV_SESSION" --arg trigger "$trigger" --arg tp "$tp" --arg at "$(jev_now)" \
      --argjson epoch "$(date +%s)" --argjson blocked "$prev_blocked" --argjson min "$MIN_SCORE" \
      --argjson max "${JEV_COMPACT_MAX_FACTS:-60}" --arg lp "$ledger" --argjson mid "$mid" '
      {
        session_id: $sid, mode: "ledger", ledger_path: $lp, trigger: $trigger, transcript_path: $tp,
        extracted_at: $at, extracted_epoch: $epoch, phase: "pre", jev_ok: true,
        guard_blocked: $blocked, work_type: null, mid_operation: $mid,
        superseded: ([.[] | select(.superseded_by != null)] | length),
        facts: ([.[] | select(.superseded_by == null and .kind != "artifact" and (.score // 0) >= $min)]
                | to_entries | map(.value + {ord: .key})
                | sort_by(-(if .score >= 2.5 then 1 else 0 end), -.ord) | .[0:$max] | sort_by(.ord)
                | to_entries | map(.value + {n: (.key + 1)} | {n, id, kind, text, score}))
      }' "$ledger")
    block=false
    if [ "${JEV_COMPACT_GUARD:-0}" = 1 ] && [ "$trigger" = auto ] && [ "$prev_blocked" != true ] && [ "$mid" != null ] &&
      awk -v m="$mid" -v t="${JEV_COMPACT_GUARD_MIN:-0.85}" 'BEGIN { exit !(m >= t) }'; then
      block=true
      new_state=$(jq -c '.guard_blocked = true | .phase = "blocked"' <<<"$new_state")
    fi
    printf '%s\n' "$new_state" >"$state.tmp" && mv "$state.tmp" "$state"
    jev_log compact.jsonl "$(jq -c --arg block "$block" '{event: "pre", mode: "ledger", status: "ok", trigger,
      facts: (.facts | length), superseded, mid_operation, blocked: ($block == "true")}' <<<"$new_state")"
    if [ "$block" = true ]; then
      echo "jev: compaction deferred once — the last turn looks mid-operation (an edit, command or review without a recorded result). It will run at the next opportunity." >&2
      trap - EXIT
      exit 2
    fi
    exit 0
  fi
fi

# --- v1 mode: no ledger for this session
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

# build_req <from-n> <to-n> <with-session-questions>
build_req() {
  jq -c --arg model "$JEV_MODEL" --argjson from "$1" --argjson to "$2" --argjson sess "$3" \
    --argjson tail_max "$tail_max" '
    {
      model: $model,
      state: {
        facts: [.facts[] | "\(.n). \(.text)"],
        recent_transcript_tail: (if (.tail | length) > $tail_max then .tail[-$tail_max:] else .tail end)
      },
      questions: ((
        [.facts[] | select(.n >= $from and .n <= $to) | {
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
          }}] | from_entries
      ) + (if $sess then {
        work_type: {
          type: "choice",
          instructions: "What kind of work is the session in `recent_transcript_tail` mostly doing?",
          criteria: {
            orchestration: "Planning, briefing and supervising subagents or pull requests rather than editing code itself",
            implementation: "Writing or changing code, configuration or documentation",
            debugging: "Diagnosing a failure or unexpected behaviour",
            research: "Reading code, documentation or data to answer a question",
            other: "None of the above"
          }
        },
        mid_operation: {
          type: "noul",
          instructions: "In `recent_transcript_tail`, the most recent turn is in the middle of an edit, command or review whose result has not been recorded yet."
        }
      } else {} end))
    }' <<<"$ex"
}

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/jev-pre.XXXXXX")
cleanup() { rm -rf "$tmpd"; }
trap 'cleanup; exit 0' EXIT

# One request, or two in parallel when there are many facts.
if [ "$nfacts" -le "$SPLIT" ]; then
  build_req 1 "$nfacts" true | jev_call >"$tmpd/r1.json" || : >"$tmpd/r1.json"
else
  half=$(((nfacts + 1) / 2))
  { build_req 1 "$half" true | jev_call >"$tmpd/r1.json" || : >"$tmpd/r1.json"; } &
  { build_req $((half + 1)) "$nfacts" false | jev_call >"$tmpd/r2.json" || : >"$tmpd/r2.json"; } &
  wait
fi

answers=$(cat "$tmpd"/r*.json | jq -s -c 'if length == 0 then null else (map(.answers) | add) end' 2>/dev/null || echo null)
jev_ok=true
if [ "$answers" = null ] || ! jq -e --argjson n "$nfacts" '[range(1; $n + 1) as $i | has("f\($i)")] | all' <<<"$answers" >/dev/null; then
  jev_ok=false
fi

new_state=$(jq -c --arg sid "$JEV_SESSION" --arg trigger "$trigger" --arg tp "$tp" --arg at "$(jev_now)" \
  --argjson epoch "$(date +%s)" --argjson ok "$jev_ok" --argjson a "${answers:-null}" \
  --argjson blocked "$prev_blocked" '
  {
    session_id: $sid, mode: "v1", trigger: $trigger, transcript_path: $tp,
    extracted_at: $at, extracted_epoch: $epoch, phase: "pre", jev_ok: $ok,
    guard_blocked: $blocked,
    work_type: ($a.work_type.choice // null),
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
  trigger, facts: (.facts | length), work_type, mid_operation, blocked: ($block == "true"),
  scores: [.facts[] | {n, kind, score}]}' <<<"$new_state")"

if [ "$block" = true ]; then
  echo "jev: compaction deferred once — the last turn looks mid-operation (an edit, command or review without a recorded result). It will run at the next opportunity." >&2
  trap - EXIT
  cleanup
  exit 2
fi
