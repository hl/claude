#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# live-agent.sh — the Agent hooks in real `claude -p` sessions (costs tokens;
# run with JEV_LIVE=1 via run.sh). Writes sanitised evidence to
# test/evidence/agent-scope.txt.
#
# The same parent prompt (sonnet asks for a "haiku" subagent on a non-trivial
# security review, no route id) runs in two scratch projects that load only
# their own settings (the Jev PreToolUse and PostToolUse hooks on Agent):
#  1. no .orchestrator.md: agent-route.sh exits at once; no Jev call is made
#     and the subagent runs on haiku;
#  2. with .orchestrator.md (a Claudette session): one Jev call, the hook
#     raises haiku to opus via updatedInput, and the subagent runs on opus.
# In both, the parent receives artifact-hook.sh's additionalContext
# "Subagent ran on <model>" and quotes it back.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
EVID="$HERE/evidence"
ROOT=${JEV_SCRATCH:-/tmp/jev-live-agent}
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
sanitise() { sed -e "s#$HOME#~#g" -e "s#/private$ROOT#<scratch>#g" -e "s#$ROOT#<scratch>#g"; }

run_case() { # <name> <with-orchestrator:yes|no> <expected model substring>
  local name=$1 orch=$2 want=$3 dir="$ROOT/$1" reply tp models ctx calls
  rm -rf "$dir"
  mkdir -p "$dir/.claude"
  export JEV_HOME="$dir/jevhome"
  [ "$orch" = yes ] && printf '# Orchestrator log\n\n## 2026-10-20 — live scope check\n- Status: implementing\n' >"$dir/.orchestrator.md"
  jq -n --arg j "$J" '{hooks: {
    PreToolUse: [{matcher: "Agent", hooks: [{type: "command", command: "\($j)/agent-route.sh", timeout: 10}]}],
    PostToolUse: [{matcher: "Agent", hooks: [{type: "command", command: "\($j)/artifact-hook.sh", timeout: 10}]}]}}' >"$dir/.claude/settings.json"
  reply=$(cd "$dir" && timeout 300 claude -p --setting-sources project --model sonnet \
    "Use the Agent tool exactly once, in the foreground (run_in_background false), with subagent_type \"general-purpose\", model \"haiku\", description \"Security review\", and this prompt: \"First-round security review of a non-trivial diff to the authentication plug: it moves session storage from signed cookies to Redis and changes how session tokens are validated. No diff is attached; reply with the top three risks you would check, one line each.\" Wait for its result, then reply with one line: 'hook said: <the exact sentence a hook added about which model the subagent ran on, or NONE>'." 2>&1)
  enc=$(cd "$dir" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')
  tp=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc" -path '*/subagents/*' -name '*.jsonl' -newer "$dir/.claude/settings.json" 2>/dev/null | head -n 1)
  models=$( [ -f "$tp" ] && jq -r 'select(.type == "assistant") | .message.model' "$tp" | sort -u | paste -sd, -)
  [ -n "$models" ] || models=$(jq -r 'select(.action == "ran") | .resolved_model' "$JEV_HOME/log/route.jsonl" 2>/dev/null | paste -sd, -)
  calls=$(cat "$JEV_HOME/log/jev.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  ctx=$(grep -oE '(Subagent ran on|Background subagent running on) [^ ]+' <<<"$reply" | head -n 1)
  {
    echo "## case: $name (.orchestrator.md: $orch)"
    echo "--- route.jsonl"
    cat "$JEV_HOME/log/route.jsonl" 2>/dev/null | jq -c '{hook, action, given_model, final_model, resolved_model, reason}' 2>/dev/null
    echo "--- Jev requests: $calls"
    echo "--- subagent message.model values: ${models:-none}"
    echo "--- parent reply:"
    printf '%s\n' "$reply"
    echo
  } | sanitise >>"$EVID/agent-scope.txt"
  case $models in *"$want"*) ok "$name: subagent ran on $models" ;; *) bad "$name: subagent models '${models:-none}', expected *$want*" ;; esac
  ptp=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc" -maxdepth 1 -name '*.jsonl' -newer "$dir/.claude/settings.json" 2>/dev/null | head -n 1)
  att=$(jq -r 'select(.type == "attachment" and (.attachment.type // "" | test("hook")) and .attachment.hookEvent == "PostToolUse") | .attachment.content | tostring' "$ptp" 2>/dev/null | grep -oE '(Subagent ran on|Background subagent running on) [^ "]+' | head -n 1)
  echo "--- PostToolUse additionalContext in the parent transcript: ${att:-none}" | sanitise >>"$EVID/agent-scope.txt"
  case $att in *" on "*"$want"*) ok "$name: the parent transcript holds the hook's additionalContext \"$att\"" ;; *) bad "$name: no ran-on additionalContext in the parent transcript ($(sanitise <<<"$ptp"))" ;; esac
  case $ctx in *" on "*"$want"*) ok "$name: the parent quoted it back: \"$ctx\"" ;; *) bad "$name: parent did not quote the ran-on line: $(sanitise <<<"$reply" | tail -n 3)" ;; esac
  if [ "$orch" = yes ]; then
    [ "$calls" = 1 ] && grep -q '"action":"escalated"' "$JEV_HOME/log/route.jsonl" && ok "$name: one Jev call, escalated haiku -> opus" || bad "$name: $calls Jev call(s), escalation not logged"
  else
    [ "$calls" = 0 ] && ! grep -q '"hook":"agent-route"' "$JEV_HOME/log/route.jsonl" 2>/dev/null && ok "$name: no Jev call, agent-route.sh logged nothing" || bad "$name: $calls Jev call(s) outside a Claudette project"
  fi
}

mkdir -p "$EVID"
echo "# live-agent.sh — $(date -u +%Y-%m-%dT%H:%MZ), $(claude --version 2>/dev/null | head -n 1)" >"$EVID/agent-scope.txt"
run_case plain no haiku
run_case claudette yes opus
echo "live-agent: $fails failure(s)"
[ "$fails" -eq 0 ]
