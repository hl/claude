#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# agent-route-api.sh — agent-route.sh against the live Jev API (needs a key).
# Checks fill / escalate / never-lower / skip semantics and the output shape.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../agent-route.sh"
JEV_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jev-ar.XXXXXX")
export JEV_HOME
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

payload() { # <model-or-empty> <subagent_type> <prompt>
  jq -cn --arg m "$1" --arg t "$2" --arg p "$3" '{
    session_id: "test-agent-route", hook_event_name: "PreToolUse", tool_name: "Agent",
    tool_use_id: "toolu_test",
    tool_input: ({description: "test task", prompt: $p, subagent_type: $t, run_in_background: false}
                 + (if $m == "" then {} else {model: $m} end))}'
}
run() { # <mode> <payload>
  JEV_ROUTE_MODE=$1 "$HOOK" <<<"$2"
}

mech="Fix the typo \"recieve\" -> \"receive\" on line 42 of README.md. Change nothing else."
hard="First-round review of PR #1601 (+1,240/-380 across 23 files), which moves session storage from cookies to Redis and changes the auth plug. Check correctness, security and migration safety."

# fill, no model, mechanical -> haiku, full input preserved
p=$(payload "" general-purpose "$mech")
o=$(run fill "$p")
if jq -e --argjson p "$p" '.hookSpecificOutput
    | .hookEventName == "PreToolUse" and .permissionDecision == "allow"
      and (.permissionDecisionReason | startswith("jev: none→haiku"))
      and .updatedInput == ($p.tool_input + {model: "haiku"})' <<<"$o" >/dev/null 2>&1; then
  ok "fill: no model + mechanical -> haiku, full input kept ($(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$o"))"
else bad "fill: expected haiku updatedInput, got: $o"; fi

# fill, model present -> untouched
o=$(run fill "$(payload sonnet general-purpose "$hard")")
[ -z "$o" ] && ok "fill: explicit model is left alone" || bad "fill: changed explicit model: $o"

# fill, fork -> untouched
o=$(run fill "$(payload "" fork "$hard")")
[ -z "$o" ] && ok "fill: subagent_type fork is skipped" || bad "fill: touched fork: $o"

# fill, built-in type with its own model (Explore) -> untouched
o=$(run fill "$(payload "" Explore "$hard")")
[ -z "$o" ] && ok "fill: Explore (pins its own model) is skipped" || bad "fill: touched Explore: $o"

# fill, custom agent whose frontmatter pins a model -> untouched
mkdir -p "$JEV_HOME/proj/.claude/agents"
printf -- '---\nname: pinned\nmodel: sonnet\n---\nbody\n' >"$JEV_HOME/proj/.claude/agents/pinned.md"
o=$(run fill "$(payload "" pinned "$hard" | jq -c --arg cwd "$JEV_HOME/proj" '.cwd = $cwd')")
[ -z "$o" ] && ok "fill: custom agent with frontmatter model is skipped" || bad "fill: touched pinned agent: $o"

# escalate, haiku given, hard task -> opus
o=$(run escalate "$(payload haiku general-purpose "$hard")")
if jq -e '.hookSpecificOutput.updatedInput.model == "opus" and (.hookSpecificOutput.permissionDecisionReason | startswith("jev: haiku→opus"))' <<<"$o" >/dev/null 2>&1; then
  ok "escalate: haiku + hard review -> opus ($(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$o"))"
else bad "escalate: expected haiku→opus, got: $o"; fi

# escalate, opus given, mechanical task -> never lowered
o=$(run escalate "$(payload opus general-purpose "$mech")")
[ -z "$o" ] && ok "escalate: never lowers opus on a mechanical task" || bad "escalate: lowered: $o"

# escalate, full haiku ID -> raised
o=$(run escalate "$(payload claude-haiku-5-5 general-purpose "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 &&
  ok "escalate: full haiku ID raised to opus" || bad "escalate: full ID not raised: $o"

# escalate, fable / inherit -> untouched
for m in fable inherit; do
  o=$(run escalate "$(payload "$m" general-purpose "$hard")")
  [ -z "$o" ] && ok "escalate: $m left alone" || bad "escalate: touched $m: $o"
done

# log -> no output, but a log line
before=$(wc -l <"$JEV_HOME/log/route.jsonl" 2>/dev/null || echo 0)
o=$(run log "$(payload "" general-purpose "$hard")")
after=$(wc -l <"$JEV_HOME/log/route.jsonl")
[ -z "$o" ] && [ "$after" -gt "$before" ] && ok "log: no output, decision logged" || bad "log mode: out=$o lines $before->$after"

# off -> nothing
o=$(run off "$(payload "" general-purpose "$hard")")
[ -z "$o" ] && ok "off: no output" || bad "off: $o"

# route.jsonl holds description (<=200 chars) and no prompt text
if jq -e -s 'all(.[]; (has("prompt") | not) and ((.description // "") | length) <= 200)' "$JEV_HOME/log/route.jsonl" >/dev/null; then
  ok "route.jsonl: description only, <=200 chars"
else bad "route.jsonl contains prompt text or long description"; fi

echo "agent-route-api: $fails failure(s)"
[ "$fails" -eq 0 ]
