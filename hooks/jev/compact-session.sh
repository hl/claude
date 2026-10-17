#!/usr/bin/env bash
# compact-session.sh — SessionStart hook (matcher "compact"). Re-injects the
# facts the summary lost, as additionalContext (<= JEV_COMPACT_MAX_CHARS, 9000).
#
# With coverage (compact-post.sh ran on the compaction agent's SubagentStop):
#   facts scored >= JEV_COMPACT_MIN_SCORE (1.5 = "important") that the summary
#   did not keep. Without coverage: the top-ranked facts at that score.
# Marks the state file consumed. No state file, stale state or nothing to say
# -> exit 0 with no output.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=compact-session
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MAX_CHARS=${JEV_COMPACT_MAX_CHARS:-9000}
MIN_SCORE=${JEV_COMPACT_MIN_SCORE:-1.5}
MAX_AGE=${JEV_COMPACT_MAX_AGE:-3600}

jev_disabled && exit 0
payload=$(cat)
source=$(jq -r '.source // empty' <<<"$payload")
[ "$source" = compact ] || exit 0
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
[ -n "$JEV_SESSION" ] || exit 0
state="$JEV_HOME/compact/$JEV_SESSION.json"
[ -f "$state" ] || exit 0
jq -e '(.consumed_at // null) == null' "$state" >/dev/null 2>&1 || exit 0
age=$(($(date +%s) - $(jq -r '.extracted_epoch // 0' "$state")))

mark_consumed() { # <injected-count> <chars> <mode>
  local s
  s=$(jq -c --arg at "$(jev_now)" '.consumed_at = $at | .phase = "consumed"' "$state") &&
    printf '%s\n' "$s" >"$state.tmp" && mv "$state.tmp" "$state"
  jev_log compact.jsonl "$(jq -cn --argjson n "$1" --argjson c "$2" --arg m "$3" \
    '{event: "session", status: "ok", mode: $m, injected: $n, chars: $c}')"
}

if [ "$age" -gt "$MAX_AGE" ] || ! jq -e '.jev_ok == true' "$state" >/dev/null; then
  mark_consumed 0 0 skipped
  exit 0
fi

ctx=$(jq -r --argjson min "$MIN_SCORE" --argjson max "$MAX_CHARS" --arg path "$state" '
  . as $st
  | (.coverage != null) as $cov
  | ([.facts[] | select((.score // 0) >= $min) | select(if $cov then (.covered | not) else true end)]
     | sort_by(-.score, -.n)) as $sel
  | "Facts preserved across compaction by the Jev hook (ranked; the summary did not include these or they were critical):" as $head
  | "The full ranked fact list is in \($path)." as $foot
  | [$sel[] | "- \(.text)"] as $lines
  | ([] + (if $st.work_type then ["Work type before compaction: \($st.work_type)."] else [] end)
        + (if ($st.mid_operation // 0) >= 0.6
           then ["Before compaction the last turn was probably mid-operation (p=\($st.mid_operation)): an edit, command or review whose result had not been recorded yet."]
           else [] end)) as $session
  | (reduce $lines[] as $l ({out: [], len: (($head | length) + ($foot | length) + ([$session[] | length + 1] | add // 0) + 4)};
       if .len + ($l | length) + 1 <= $max then .out += [$l] | .len += ($l | length) + 1 else . end)) as $fit
  | if ($fit.out | length) == 0 then ""
    else ([$head] + $fit.out + $session + [$foot]) | join("\n") end
' "$state")

if [ -z "$ctx" ]; then
  mark_consumed 0 0 "$(jq -r 'if .coverage then "coverage" else "ranking" end' "$state")"
  exit 0
fi
out=$(jq -cn --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}')
mark_consumed "$(($(printf '%s\n' "$ctx" | grep -c '^- ')))" "${#ctx}" "$(jq -r 'if .coverage then "coverage" else "ranking" end' "$state")"
printf '%s\n' "$out"
