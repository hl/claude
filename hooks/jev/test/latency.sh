#!/usr/bin/env bash
# latency.sh — wall-clock time of each hook (needs a Jev key).
# Budgets: agent-route < 1.5 s; ledger Stop p50 < 1.5 s; compaction hooks < 5 s each.
# JEV_LAT_RUNS (3) runs per fixed-payload hook.
#
# The ledger is also replayed turn by turn over the last JEV_LAT_TURNS (20)
# turns of a real local transcript (JEV_LAT_TRANSCRIPT, default: the largest
# main-session transcript under ~/.claude/projects modified in the last 7 days).
# That sends those turns, redacted, to Jev, exactly as the Stop hook would.
# Only timings and sizes are printed. JEV_LAT_REAL=0 skips it. With JEV_LIVE=1
# or JEV_EVIDENCE=1 the output also goes to test/evidence/latency.txt.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures"
if { [ "${JEV_LIVE:-0}" = 1 ] || [ "${JEV_EVIDENCE:-0}" = 1 ]; } && [ -z "${JEV_LAT_TEE:-}" ]; then
  {
    echo "# latency.sh — $(date -u +%Y-%m-%dT%H:%MZ), $(claude --version 2>/dev/null | head -n 1)"
    echo "# the ledger is replayed turn by turn over the fixture and the last turns of a real local transcript (timings and sizes only)"
    JEV_LAT_TEE=1 "$0" "$@"
  } 2>&1 | sed -e "s#$HOME#~#g" | tee "$HERE/evidence/latency.txt"
  exit "${PIPESTATUS[0]}"
fi
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID
JEV_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jev-lat.XXXXXX")
export JEV_HOME
cp "$FIX/transcript.jsonl" "$JEV_HOME/t.jsonl"
RUNS=${JEV_LAT_RUNS:-3}
fails=0

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
stats() { # <ms...> -> "n= p50= p95= max="
  printf '%s\n' "$@" | sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) { print "n=0"; exit }
    p50 = a[int((NR + 1) / 2)]; i = int(NR * 0.95 + 0.999); if (i > NR) i = NR
    printf "n=%d p50=%d p95=%d max=%d", NR, p50, a[i], a[NR] }'
}
check() { # <label> <budget-ms> <value-ms> <detail>
  if [ "$3" -le "$2" ]; then echo "ok   - $1: $4 (budget $2 ms)"; else
    echo "FAIL - $1: $4 (budget $2 ms)"
    fails=$((fails + 1))
  fi
}
timeit() { # <label> <budget-ms> <hook> <payload> [env...]
  local t0 all=() i label=$1 budget=$2 hook=$3 payload=$4
  shift 4
  for i in $(seq 1 "$RUNS"); do
    t0=$(now_ms)
    env "$@" "$J/$hook" <<<"${payload//@RUN@/$i}" >/dev/null 2>&1
    all+=($(($(now_ms) - t0)))
  done
  s=$(stats "${all[@]}")
  check "$label" "$budget" "${s##*max=}" "ms per run: ${all[*]} ($s)"
}

summary=$(cat "$FIX/summary.txt")
timeit "agent-route (escalate, Jev call)" 1500 agent-route.sh \
  '{"session_id":"lat","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Add endpoint","prompt":"Add a paginated GET /api/invoices endpoint following GET /api/orders, with tests.","subagent_type":"general-purpose","model":"haiku"}}'
timeit "compact-pre v1 mode (extract + 1 Jev call, 13 facts)" 5000 compact-pre.sh \
  "$(jq -cn --arg tp "$JEV_HOME/t.jsonl" '{session_id: "lat-v1-@RUN@", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}')" JEV_LEDGER=0
timeit "compact-pre ledger mode, first flush of a session (extract + 1 Jev call + snapshot)" 5000 compact-pre.sh \
  "$(jq -cn --arg tp "$JEV_HOME/t.jsonl" '{session_id: "lat-@RUN@", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}')"
timeit "compact-pre ledger mode, ledger already current (snapshot only)" 1500 compact-pre.sh \
  "$(jq -cn --arg tp "$JEV_HOME/t.jsonl" '{session_id: "lat-@RUN@", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}')"
timeit "compact-post (SubagentStop, 1 Jev call)" 5000 compact-post.sh \
  "$(jq -cn --arg m "$summary" '{session_id: "lat-@RUN@", hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: $m}')"
timeit "compact-session (no API call)" 1000 compact-session.sh \
  '{"session_id":"lat-@RUN@","hook_event_name":"SessionStart","source":"compact"}'
timeit "compact-post on an ordinary SubagentStop (fast exit)" 300 compact-post.sh \
  '{"session_id":"lat-@RUN@","hook_event_name":"SubagentStop","agent_type":"general-purpose","last_assistant_message":"x"}'
long=$(printf 'line %s of a long subagent report\n' $(seq 1 200))
timeit "artifact-hook PostToolUse(Agent), 6 KB result (local only)" 1000 artifact-hook.sh \
  "$(jq -cn --arg t "$long" '{session_id: "lat", hook_event_name: "PostToolUse", tool_name: "Agent", tool_input: {description: "report @RUN@"}, tool_response: {status: "completed", agentId: "lat@RUN@", content: [{type: "text", text: $t}]}}')"

# --- ledger Stop, turn by turn: replay(<transcript> <turns> <label>)
replay() {
  local src=$1 turns=$2 label=$3 tp="$JEV_HOME/replay-$RANDOM.jsonl" starts n i from to t0 ms all=() bytes=()
  # line numbers where a typed user prompt starts a turn
  starts=$(grep -n '"promptSource"' "$src" | cut -d: -f1 | tail -n "$((turns + 1))")
  n=$(wc -w <<<"$starts" | tr -d ' ')
  [ "$n" -ge 2 ] || {
    echo "skip - $label: fewer than 2 turns"
    return
  }
  from=$(head -n 1 <<<"$starts")
  if [ "$from" -gt 1 ]; then head -n $((from - 1)) "$src" >"$tp"; else : >"$tp"; fi
  # the history before the replayed turns is the ledger's first run (from the last boundary)
  t0=$(now_ms)
  jq -cn --arg tp "$tp" --arg s "lat-replay-$label" '{session_id: $s, transcript_path: $tp, hook_event_name: "Stop"}' | "$J/ledger.sh"
  echo "     $label: first run over $(wc -c <"$tp" | tr -d ' ') bytes of history: $(($(now_ms) - t0)) ms"
  for i in $(seq 2 "$n"); do
    to=$(sed -n "${i}p" <<<"$starts")
    sed -n "${from},$((to - 1))p" "$src" >>"$tp"
    bytes+=("$(sed -n "${from},$((to - 1))p" "$src" | wc -c | tr -d ' ')")
    from=$to
    t0=$(now_ms)
    jq -cn --arg tp "$tp" --arg s "lat-replay-$label" '{session_id: $s, transcript_path: $tp, hook_event_name: "Stop"}' | "$J/ledger.sh"
    ms=$(($(now_ms) - t0))
    all+=("$ms")
  done
  s=$(stats "${all[@]}")
  p50=${s#*p50=}
  p50=${p50%% *}
  check "ledger Stop per turn, $label" 1500 "$p50" "$s ms; slice bytes $(stats "${bytes[@]}"); statuses $(jq -r -s --arg s "lat-replay-$label" '[.[] | select(.session_id == $s and .event == "step") | .status] | group_by(.) | map("\(.[0])=\(length)") | join(",")' "$JEV_HOME/log/ledger.jsonl")"
}
replay "$FIX/ledger-session.jsonl" 12 fixture
if [ "${JEV_LAT_REAL:-1}" = 1 ]; then
  real=${JEV_LAT_TRANSCRIPT:-$(find "$HOME/.claude/projects" -name '*.jsonl' -not -path '*/subagents/*' -mtime -7 -size +1000k -print0 2>/dev/null |
    xargs -0 ls -S 2>/dev/null | grep -v -e '/-private-tmp' -e '/-tmp-' | sed -n 1p)}
  if [ -n "$real" ] && [ -f "$real" ]; then
    echo "     real transcript: $(wc -c <"$real" | tr -d ' ') bytes, $(grep -c '"promptSource"' "$real") typed prompts"
    replay "$real" "${JEV_LAT_TURNS:-20}" real
  else echo "skip - no real transcript found"; fi
fi
# shellcheck disable=SC2046 # one number per line, split on purpose
echo "     jev call ms (all calls above): $(stats $(jq -r 'select(.status == "ok") | .ms' "$JEV_HOME/log/jev.jsonl"))"
echo "latency: $fails failure(s)"
[ "$fails" -eq 0 ]
