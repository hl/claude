#!/usr/bin/env bash
# live-agent.sh — proves updatedInput on the Agent tool changes the subagent's
# model. Drives real `claude -p` sessions (costs tokens; run with JEV_LIVE=1 via
# run.sh). Writes sanitised evidence to test/evidence/agent-*.
#
#  1. fill:     parent on haiku spawns a mechanical general-purpose subagent with
#               NO model. Inherit would give haiku; Jev says haiku and the fill
#               floor makes it sonnet -> the subagent must run on a sonnet ID
#  2. escalate: parent on sonnet asks for model "haiku" on a non-trivial security
#               review -> the subagent must run on an opus ID
# Also checks the hook output carries no permissionDecision.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
EVID="$HERE/evidence"
SCRATCH=${JEV_SCRATCH:-/tmp/jev-live-agent}
mkdir -p "$EVID" "$SCRATCH/.claude" "$SCRATCH/dump"
export JEV_HOME="$SCRATCH/jevhome"
rm -rf "$JEV_HOME" "$SCRATCH"/dump/*

# Scratch project: a dump hook that records the real stdin, then the Jev hook.
cat >"$SCRATCH/dump.sh" <<'EOF'
#!/usr/bin/env bash
cat >"$(dirname "$0")/dump/$(date +%s)-$1-$$.json"
EOF
chmod +x "$SCRATCH/dump.sh"
# The Jev hook's stdout is tee'd so the evidence shows exactly what it returned.
jq -n --arg d "$SCRATCH/dump.sh" --arg r "$J/agent-route.sh" --arg o "$SCRATCH/dump/hook-output.json" '{hooks: {
  PreToolUse: [{matcher: "Agent", hooks: [{type: "command", command: "\($d) PreToolUse"}, {type: "command", command: "\($r) | tee \($o)", timeout: 10}]}],
  SubagentStop: [{hooks: [{type: "command", command: "\($d) SubagentStop"}]}]}}' >"$SCRATCH/.claude/settings.json"

sanitise() { sed -e "s#$HOME#~#g"; }
fails=0

run_case() { # <name> <parent-model> <mode> <model-clause> <description> <prompt> <expect-substring>
  local name=$1 PARENT=$2 mode=$3 mclause=$4 desc=$5 prompt=$6 want=$7 stop tp models
  rm -f "$SCRATCH"/dump/*
  (cd "$SCRATCH" && JEV_ROUTE_MODE=$mode timeout 300 claude -p --model "$PARENT" \
    "Use the Agent tool exactly once, with subagent_type \"general-purpose\" $mclause, description \"$desc\", and this prompt: \"$prompt\". Then reply with its answer in one line.") >/dev/null 2>&1
  stop=$(find "$SCRATCH/dump" -name '*-SubagentStop-*.json' | sort | tail -n 1)
  tp=$(jq -r '.agent_transcript_path // empty' "$stop" 2>/dev/null)
  models=$( [ -f "$tp" ] && jq -r 'select(.type == "assistant") | .message.model' "$tp" | sort -u | paste -sd, -)
  {
    echo "case: $name (JEV_ROUTE_MODE=$mode, parent --model $PARENT)"
    echo "--- PreToolUse stdin (tool_input as the parent sent it)"
    jq '{hook_event_name, tool_name, tool_input}' "$(find "$SCRATCH/dump" -name '*-PreToolUse-*.json' | sort | tail -n 1)"
    echo "--- agent-route.sh stdout (what Claude Code received)"
    cat "$SCRATCH/dump/hook-output.json" 2>/dev/null
    echo "--- route.jsonl decision"
    tail -n 1 "$JEV_HOME/log/route.jsonl"
    echo "--- subagent transcript: $(sanitise <<<"$tp")"
    echo "message.model values: ${models:-none}"
  } | sanitise >"$EVID/agent-$name.txt"
  cat "$EVID/agent-$name.txt"
  if jq -e '.hookSpecificOutput | has("updatedInput") and (has("permissionDecision") | not)' "$SCRATCH/dump/hook-output.json" >/dev/null 2>&1; then
    echo "ok   - $name: hook returned updatedInput without permissionDecision"
  else
    echo "FAIL - $name: unexpected hook output"
    fails=$((fails + 1))
  fi
  case $models in
    *"$want"*) echo "ok   - $name: subagent ran on $models" ;;
    *)
      echo "FAIL - $name: subagent models '${models:-none}', expected *$want*"
      fails=$((fails + 1))
      ;;
  esac
  echo
}

run_case fill haiku fill "and NO model parameter" "Count files" \
  "Run: ls / | wc -l and reply with only the number." sonnet
run_case escalate sonnet escalate "and model \"haiku\"" "Security review" \
  "First-round security review of a non-trivial diff to the authentication plug: it moves session storage from signed cookies to Redis and changes how session tokens are validated. No diff is attached; reply with the top three risks you would check, one line each." opus

echo "live-agent: $fails failure(s)"
[ "$fails" -eq 0 ]
