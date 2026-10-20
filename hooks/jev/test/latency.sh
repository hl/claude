#!/usr/bin/env bash
# latency.sh — wall-clock time of each hook (needs a Jev key), in a
# Claudette-scoped scratch project so the Jev-calling hooks really call.
# Budgets: agent-route < 1.5 s; compaction hooks < 5 s each; local hooks < 1 s;
# an out-of-scope agent-route (the common case) < 300 ms.
# JEV_LAT_RUNS (3) runs per hook. With JEV_LIVE=1 or JEV_EVIDENCE=1 the output
# also goes to test/evidence/latency.txt.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures"
if { [ "${JEV_LIVE:-0}" = 1 ] || [ "${JEV_EVIDENCE:-0}" = 1 ]; } && [ -z "${JEV_LAT_TEE:-}" ]; then
  {
    echo "# latency.sh — $(date -u +%Y-%m-%dT%H:%MZ), $(claude --version 2>/dev/null | head -n 1)"
    JEV_LAT_TEE=1 "$0" "$@"
  } 2>&1 | sed -e "s#$HOME#~#g" | tee "$HERE/evidence/latency.txt"
  exit "${PIPESTATUS[0]}"
fi
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID JEV_SCOPE
JEV_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jev-lat.XXXXXX")
export JEV_HOME
mkdir -p "$JEV_HOME/proj" "$JEV_HOME/plain"
: >"$JEV_HOME/proj/.orchestrator.md"
export CLAUDE_PROJECT_DIR="$JEV_HOME/proj"
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
agent='{"session_id":"lat","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Add endpoint","prompt":"Add a paginated GET /api/invoices endpoint following GET /api/orders, with tests.","subagent_type":"general-purpose","model":"haiku"}}'
timeit "agent-route, explicit haiku, no route id (1 Jev call)" 1500 agent-route.sh "$agent"
timeit "agent-route outside a Claudette project (exits at once)" 300 agent-route.sh "$agent" CLAUDE_PROJECT_DIR="$JEV_HOME/plain"
timeit "agent-route, model-less call (no Jev call)" 300 agent-route.sh "$(jq -c 'del(.tool_input.model)' <<<"$agent")"
timeit "compact-pre (extract + 1 Jev call, 13 facts)" 5000 compact-pre.sh \
  "$(jq -cn --arg tp "$JEV_HOME/t.jsonl" '{session_id: "lat-@RUN@", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}')"
timeit "compact-post (SubagentStop, 1 Jev call)" 5000 compact-post.sh \
  "$(jq -cn --arg m "$summary" '{session_id: "lat-@RUN@", hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: $m}')"
timeit "compact-session (no API call)" 1000 compact-session.sh \
  '{"session_id":"lat-@RUN@","hook_event_name":"SessionStart","source":"compact"}'
timeit "compact-post on an ordinary SubagentStop (fast exit)" 300 compact-post.sh \
  '{"session_id":"lat-@RUN@","hook_event_name":"SubagentStop","agent_type":"general-purpose","last_assistant_message":"x"}'
long=$(printf 'line %s of a long subagent report\n' $(seq 1 200))
timeit "artifact-hook PostToolUse(Agent), 6 KB result (local only)" 1000 artifact-hook.sh \
  "$(jq -cn --arg t "$long" '{session_id: "lat", hook_event_name: "PostToolUse", tool_name: "Agent", tool_input: {description: "report @RUN@"}, tool_response: {status: "completed", agentId: "lat@RUN@", resolvedModel: "claude-opus-5-5", content: [{type: "text", text: $t}]}}')"
# shellcheck disable=SC2046 # one number per line, split on purpose
echo "     jev call ms (all calls above): $(stats $(jq -r 'select(.status == "ok") | .ms' "$JEV_HOME/log/jev.jsonl"))"
echo "latency: $fails failure(s)"
[ "$fails" -eq 0 ]
