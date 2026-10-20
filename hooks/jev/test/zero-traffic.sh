#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# zero-traffic.sh — the invariant "no Jev traffic on a routine turn", against
# the hooks as wired in this repo's settings.json (offline: a local fake Jev
# counts every request).
#
# Replays a 10-turn session through every Jev hook entry in settings.json, with
# the matchers applied as Claude Code does: SessionStart(startup), then per turn
# UserPromptSubmit, Bash and Edit tool calls (Pre/PostToolUse) and Stop; three
# turns spawn a subagent (an explicit haiku with no route id, a model-less one,
# and a sonnet whose brief carries a route.sh id), each with PreToolUse(Agent),
# SubagentStop and PostToolUse(Agent); then one compaction (PreCompact,
# SubagentStop of the compaction agent, SessionStart(compact), PostCompact).
#   1. In an ordinary project (no .orchestrator.md): zero requests in total,
#      Agent spawns and compaction included; the compaction still injects the
#      artifact index (free, local).
#   2. In a Claudette project (.orchestrator.md at CLAUDE_PROJECT_DIR): zero on
#      every routine event; one request for the haiku spawn without a route id,
#      none for the model-less or routed spawns; at most two for the compaction.
# Non-Jev hooks in settings.json are listed but not run.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
SETTINGS=${JEV_SETTINGS:-$(cd "$J/../.." && pwd)/settings.json}
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID JEV_ROUTE_MODE JEV_SCOPE CLAUDE_CODE_SUBAGENT_MODEL JEV_DISABLED
W=$(mktemp -d "${TMPDIR:-/tmp}/jev-zero.XXXXXX")
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

port=$((20000 + RANDOM % 20000))
python3 -I "$HERE/fake-jev.py" "$port" "$W/cap" >"$W/fake.out" 2>&1 &
fpid=$!
trap 'kill $fpid 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q ready "$W/fake.out" 2>/dev/null && break; sleep 0.1; done
export TYPESAFE_BASE_URL="http://127.0.0.1:$port" TYPESAFE_API_KEY=apikFAKEZERO
bodies() { find "$W/cap" -name 'body-*.json' 2>/dev/null | wc -l | tr -d ' '; }

# The hook entries: event, matcher, Jev script (basename) or "-" for anything else.
jq -r '.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m | .hooks[]
  | [$e, (if $m == "" then "*" else $m end), (.command | if test("hooks/jev/") then sub(".*hooks/jev/"; "") | sub("[\"'"'"' ].*$"; "") else "-" end)] | @tsv' \
  "$SETTINGS" >"$W/entries.tsv"
echo "settings: $SETTINGS"
awk -F'\t' '{ printf "     %-16s %-28s %s\n", $1, $2, ($3 == "-" ? "(not Jev: not run)" : $3) }' "$W/entries.tsv"

# fire <label> <event> <match-value> <payload>: run every Jev hook of that event whose
# matcher matches; record "<label> <requests made>" in $W/calls-<scope>.
fire() {
  local label=$1 ev=$2 val=$3 p=$4 e m s before out
  before=$(bodies)
  while IFS=$'\t' read -r e m s; do
    [ "$e" = "$ev" ] && [ "$s" != - ] || continue
    if [ "$m" != "*" ] && ! [[ $val =~ ^($m)$ ]]; then continue; fi
    out=$(CLAUDE_PROJECT_DIR="$PROJ" "$J/$s" <<<"$p" 2>/dev/null)
    [ "$ev" = SessionStart ] && [ "$val" = compact ] && [ -n "$out" ] && printf '%s\n' "$out" >"$W/inject-$SCOPE.json"
    [ "$ev" = PostToolUse ] && [ "$val" = Agent ] && [ -n "$out" ] && printf '%s\n' "$out" >>"$W/posttool-$SCOPE.jsonl"
  done <"$W/entries.tsv"
  echo "$label $(($(bodies) - before))" >>"$W/calls-$SCOPE"
}

replay() { # <scope-name> <project dir>
  SCOPE=$1 PROJ=$2
  export JEV_HOME="$W/home-$SCOPE"
  local sid="zero-$SCOPE" tp="$W/t-$SCOPE.jsonl" i base agent model prompt
  : >"$tp"
  : >"$W/calls-$SCOPE"
  base=$(jq -cn --arg s "$sid" --arg tp "$tp" --arg cwd "$PROJ" '{session_id: $s, transcript_path: $tp, cwd: $cwd}')
  fire startup SessionStart startup "$(jq -c '. + {hook_event_name: "SessionStart", source: "startup"}' <<<"$base")"
  for i in $(seq 1 10); do
    jq -cn --arg u "u$i" --arg t "Turn $i: keep the staging host pg-staging-$i in mind and fix test $i in lib/app/thing_$i.ex." \
      '{type: "user", uuid: $u, promptSource: "typed", message: {role: "user", content: $t}}' >>"$tp"
    fire "turn$i:UserPromptSubmit" UserPromptSubmit "" "$(jq -c --arg p "Turn $i" '. + {hook_event_name: "UserPromptSubmit", prompt: $p}' <<<"$base")"
    for tool in Bash Edit; do
      ti=$(if [ $tool = Bash ]; then jq -cn --arg c "mix test test/thing_${i}_test.exs" '{command: $c}'; else jq -cn --arg f "$PROJ/lib/app/thing_$i.ex" '{file_path: $f, old_string: "a", new_string: "b"}'; fi)
      fire "turn$i:PreToolUse:$tool" PreToolUse $tool "$(jq -c --arg t $tool --argjson ti "$ti" '. + {hook_event_name: "PreToolUse", tool_name: $t, tool_input: $ti, tool_use_id: "toolu_\($t)"}' <<<"$base")"
      fire "turn$i:PostToolUse:$tool" PostToolUse $tool "$(jq -c --arg t $tool --argjson ti "$ti" '. + {hook_event_name: "PostToolUse", tool_name: $t, tool_input: $ti, tool_response: {stdout: "ok"}, tool_use_id: "toolu_\($t)"}' <<<"$base")"
    done
    agent=""
    case $i in
      3) agent=haiku-no-route model=haiku prompt="Add a paginated GET /api/invoices endpoint following GET /api/orders, with tests." ;;
      5) agent=no-model model="" prompt="Investigate why test 5 is flaky and report the root cause." ;;
      7) agent=routed model=sonnet prompt="Route: r1792491674-30786-23727
Rename the helper in lib/app/thing_7.ex as specified." ;;
    esac
    if [ -n "$agent" ]; then
      ti=$(jq -cn --arg m "$model" --arg p "$prompt" --arg d "Agent $agent" '{description: $d, prompt: $p, subagent_type: "general-purpose"} + (if $m == "" then {} else {model: $m} end)')
      fire "turn$i:PreToolUse:Agent($agent)" PreToolUse Agent "$(jq -c --argjson ti "$ti" --arg u "toolu_ag$i" '. + {hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: $ti, tool_use_id: $u}' <<<"$base")"
      fire "turn$i:SubagentStop" SubagentStop "" "$(jq -c --arg a "ag$i" '. + {hook_event_name: "SubagentStop", agent_id: $a, agent_type: "general-purpose", last_assistant_message: "done", background_tasks: []}' <<<"$base")"
      long=$(printf 'Finding %s of the subagent report, long enough to be saved.\n' $(seq 1 60))
      fire "turn$i:PostToolUse:Agent($agent)" PostToolUse Agent "$(jq -c --argjson ti "$ti" --arg u "toolu_ag$i" --arg a "ag$i" --arg t "$long" '. + {hook_event_name: "PostToolUse", tool_name: "Agent", tool_input: $ti, tool_use_id: $u,
        tool_response: {status: "completed", agentId: $a, resolvedModel: "claude-opus-5-5", content: [{type: "text", text: $t}]}}' <<<"$base")"
    fi
    jq -cn --arg u "a$i" --arg t "Decision: fixed test $i because the clock was shared." \
      '{type: "assistant", uuid: $u, message: {role: "assistant", content: [{type: "text", text: $t}]}}' >>"$tp"
    fire "turn$i:Stop" Stop "" "$(jq -c '. + {hook_event_name: "Stop", stop_hook_active: false}' <<<"$base")"
  done
  local summary
  summary="<summary>Fixed tests 1-10.</summary>"
  fire "compact:PreCompact" PreCompact auto "$(jq -c '. + {hook_event_name: "PreCompact", trigger: "auto"}' <<<"$base")"
  fire "compact:SubagentStop" SubagentStop "" "$(jq -c --arg m "$summary" '. + {hook_event_name: "SubagentStop", agent_id: "acompact", agent_type: "", last_assistant_message: $m}' <<<"$base")"
  fire "compact:SessionStart" SessionStart compact "$(jq -c '. + {hook_event_name: "SessionStart", source: "compact"}' <<<"$base")"
  fire "compact:PostCompact" PostCompact auto "$(jq -c --arg m "$summary" '. + {hook_event_name: "PostCompact", trigger: "auto", compact_summary: $m}' <<<"$base")"
}

# --- 1. an ordinary project
mkdir -p "$W/plain"
replay plain "$W/plain"
n=$(awk '{ s += $2 } END { print s + 0 }' "$W/calls-plain")
[ "$n" = 0 ] && [ ! -e "$W/home-plain/log/jev.jsonl" ] &&
  ok "ordinary project: $(wc -l <"$W/calls-plain" | tr -d ' ') hook events over 10 turns (3 Agent spawns, 1 compaction) -> 0 Jev requests, nothing in jev.jsonl" ||
  bad "ordinary project: $n request(s): $(awk '$2 > 0' "$W/calls-plain" | paste -sd' ' -)"
case $(jq -r '.hookSpecificOutput.additionalContext // empty' "$W/inject-plain.json" 2>/dev/null) in
  *"Artifacts saved this session"*agent-*) ok "ordinary project: the compaction still re-injects the artifact index (local, free)" ;;
  *) bad "ordinary project: no artifact index injected" ;;
esac
[ "$(jq -r -s '[.[].hookSpecificOutput.additionalContext | split("\n")[0]] | unique | join("|")' "$W/posttool-plain.jsonl" 2>/dev/null)" = "Subagent ran on claude-opus-5-5." ] &&
  ok "ordinary project: every Agent call tells the parent \"Subagent ran on <model>\"" || bad "ordinary project: ran-on line missing"

# --- 2. a Claudette project
mkdir -p "$W/claudette"
printf '# Orchestrator log\n\n## 2026-10-20 — zero-traffic check\n- Status: implementing\n' >"$W/claudette/.orchestrator.md"
replay claudette "$W/claudette"
routine=$(grep -v -e ':PreToolUse:Agent' -e '^compact:' "$W/calls-claudette" | awk '{ s += $2 } END { print s + 0 }')
spawn() { awk -v l="$1" '$1 == l { print $2 }' "$W/calls-claudette"; }
compact=$(grep '^compact:' "$W/calls-claudette" | awk '{ s += $2 } END { print s + 0 }')
[ "$routine" = 0 ] && ok "Claudette project: 0 Jev requests on routine events (UserPromptSubmit, Bash/Edit tool calls, SubagentStop, PostToolUse(Agent), Stop, startup)" ||
  bad "Claudette project: $routine request(s) on routine events: $(grep -v -e ':PreToolUse:Agent' -e '^compact:' "$W/calls-claudette" | awk '$2 > 0' | paste -sd' ' -)"
[ "$(spawn 'turn3:PreToolUse:Agent(haiku-no-route)')" = 1 ] && [ "$(spawn 'turn5:PreToolUse:Agent(no-model)')" = 0 ] && [ "$(spawn 'turn7:PreToolUse:Agent(routed)')" = 0 ] &&
  ok "Claudette project: Agent spawns -> 1 request for the explicit haiku without a route id, 0 for the model-less one, 0 for the routed one" ||
  bad "Claudette project spawns: $(grep ':PreToolUse:Agent' "$W/calls-claudette" | paste -sd' ' -)"
[ "$compact" -ge 1 ] && [ "$compact" -le 2 ] && ok "Claudette project: the compaction made $compact request(s) (<= 2: $(grep '^compact:' "$W/calls-claudette" | awk '$2 > 0 { print $1 "=" $2 }' | paste -sd' ' -))" ||
  bad "Claudette project compaction: $compact request(s)"
case $(jq -r '.hookSpecificOutput.additionalContext // empty' "$W/inject-claudette.json" 2>/dev/null) in
  *"zero-traffic check"*"Artifacts saved"*"Facts preserved"*) ok "Claudette project: injection has the live .orchestrator.md section, the artifact index and the uncovered facts" ;;
  *) bad "Claudette project injection incomplete" ;;
esac
total=$(awk '{ s += $2 } END { print s + 0 }' "$W/calls-claudette")
echo "     Claudette project: $total request(s) in total over $(wc -l <"$W/calls-claudette" | tr -d ' ') hook events"

echo "zero-traffic: $fails failure(s)"
[ "$fails" -eq 0 ]
