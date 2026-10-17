#!/usr/bin/env bash
# latency.sh — wall-clock time of each hook on the fixture (needs a Jev key).
# Budgets: agent-route < 1.5 s, compaction hooks < 5 s each. JEV_LAT_RUNS (3).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures"
JEV_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jev-lat.XXXXXX")
export JEV_HOME
cp "$FIX/transcript.jsonl" "$JEV_HOME/t.jsonl"
RUNS=${JEV_LAT_RUNS:-3}
fails=0

now_ms() { # bash 5 has EPOCHREALTIME; fall back to whole seconds
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t=${EPOCHREALTIME/[.,]/}
    echo $((t / 1000))
  else echo $(($(date +%s) * 1000)); fi
}
timeit() { # <label> <budget-ms> <hook> <payload>
  local t0 t1 ms max=0 all="" i
  for i in $(seq 1 "$RUNS"); do
    t0=$(now_ms)
    "$J/$3" <<<"${4//@RUN@/$i}" >/dev/null 2>&1
    t1=$(now_ms)
    ms=$((t1 - t0))
    all="$all $ms"
    [ "$ms" -gt "$max" ] && max=$ms
  done
  if [ "$max" -le "$2" ]; then echo "ok   - $1: ms per run:$all (budget $2)"; else
    echo "FAIL - $1: ms per run:$all (budget $2)"
    fails=$((fails + 1))
  fi
}

summary=$(cat "$FIX/summary.txt")
timeit "agent-route (fill, Jev call)" 1500 agent-route.sh \
  '{"session_id":"lat","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Add endpoint","prompt":"Add a paginated GET /api/invoices endpoint following GET /api/orders, with tests.","subagent_type":"general-purpose"}}'
timeit "compact-pre (extract + 1 Jev call, 13 facts)" 5000 compact-pre.sh \
  "$(jq -cn --arg tp "$JEV_HOME/t.jsonl" '{session_id: "lat-@RUN@", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}')"
timeit "compact-post (SubagentStop, 1 Jev call)" 5000 compact-post.sh \
  "$(jq -cn --arg m "$summary" '{session_id: "lat-@RUN@", hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: $m}')"
timeit "compact-session (no API call)" 1000 compact-session.sh \
  '{"session_id":"lat-@RUN@","hook_event_name":"SessionStart","source":"compact"}'
timeit "compact-post on an ordinary SubagentStop (fast exit)" 300 compact-post.sh \
  '{"session_id":"lat-@RUN@","hook_event_name":"SubagentStop","agent_type":"general-purpose","last_assistant_message":"x"}'
echo "latency: $fails failure(s)"
[ "$fails" -eq 0 ]
