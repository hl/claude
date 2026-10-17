#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# agent-route-api.sh — agent-route.sh against the live Jev API (needs a key).
# Checks log (default) / fill / escalate semantics, the fill allowlist, the
# sonnet floor, never-lower, and the output shape (updatedInput only).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../agent-route.sh"
JEV_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jev-ar.XXXXXX")
export JEV_HOME
# Isolate agent-definition lookup from the machine running the test.
export CLAUDE_CONFIG_DIR="$JEV_HOME/config"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SUBAGENT_MODEL JEV_ROUTE_FILL_TYPES
PROJ="$JEV_HOME/proj"
mkdir -p "$PROJ/.claude/agents" "$CLAUDE_CONFIG_DIR/agents"
printf -- '---\nname: pinned\nmodel: opus\n---\nbody\n' >"$PROJ/.claude/agents/pinned.md"
printf -- '---\nname: "code-reviewer-x"\ndescription: name differs from filename\nmodel: opus\n---\nbody\n' >"$PROJ/.claude/agents/reviewer.md"
printf -- '---\nname: free-agent\ndescription: no model line\n---\nbody\n' >"$CLAUDE_CONFIG_DIR/agents/some-other-file.md"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
last_log() { tail -n 1 "$JEV_HOME/log/route.jsonl"; }

payload() { # <model-or-empty> <subagent_type> <prompt>
  jq -cn --arg m "$1" --arg t "$2" --arg p "$3" --arg cwd "$PROJ" '{
    session_id: "test-agent-route", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Agent",
    tool_use_id: "toolu_test",
    tool_input: ({description: "test task", prompt: $p, subagent_type: $t, run_in_background: false}
                 + (if $m == "" then {} else {model: $m} end))}'
}
run() { # <mode|default> <payload>
  if [ "$1" = default ]; then env -u JEV_ROUTE_MODE "$HOOK" <<<"$2"; else JEV_ROUTE_MODE=$1 "$HOOK" <<<"$2"; fi
}
silent() { # <label> <mode> <payload> [expected log action]
  local o
  o=$(run "$2" "$3")
  if [ -z "$o" ] && { [ -z "${4:-}" ] || last_log | jq -e --arg a "$4" '.action == $a' >/dev/null; }; then
    ok "$1"
  else bad "$1: out=${o:0:160} log=$(last_log | jq -c '{action}')"; fi
}

mech="Fix the typo \"recieve\" -> \"receive\" on line 42 of README.md. Change nothing else."
hard="First-round review of PR #1601 (+1,240/-380 across 23 files), which moves session storage from cookies to Redis and changes the auth plug. Check correctness, security and migration safety."

# default mode is log: never changes anything, logs Jev's pick
silent "default mode (log): no output, decision logged" default "$(payload "" general-purpose "$hard")" logged

# fill, general-purpose, mechanical: Jev says haiku, the sonnet floor applies
p=$(payload "" general-purpose "$mech")
o=$(run fill "$p")
if jq -e --argjson p "$p" '.hookSpecificOutput
    | .hookEventName == "PreToolUse" and (has("permissionDecision") | not) and (has("permissionDecisionReason") | not)
      and .updatedInput == ($p.tool_input + {model: "sonnet"})' <<<"$o" >/dev/null 2>&1 &&
  last_log | jq -e '.action == "filled" and .final_model == "sonnet" and (.reason | startswith("jev: none→sonnet"))' >/dev/null; then
  ok "fill: model-less mechanical call -> sonnet (floor), updatedInput only, reason in log: $(last_log | jq -r .reason)"
else bad "fill floor: out=$o log=$(last_log)"; fi

# fill, general-purpose, hard -> opus
o=$(run fill "$(payload "" general-purpose "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 &&
  ok "fill: model-less hard review -> opus" || bad "fill hard: $o"

# empty subagent_type counts as general-purpose
o=$(run fill "$(payload "" "" "$hard" | jq -c 'del(.tool_input.subagent_type)')")
jq -e '.hookSpecificOutput.updatedInput.model == "opus" and (.hookSpecificOutput.updatedInput | has("subagent_type") | not)' <<<"$o" >/dev/null 2>&1 &&
  ok "fill: missing subagent_type treated as general-purpose" || bad "fill no type: $o"

# fill allowlist: everything not known to be model-less is skipped
silent "fill: explicit model is left alone" fill "$(payload sonnet general-purpose "$hard")" skip_has_model
silent "fill: fork is skipped" fill "$(payload "" fork "$hard")" skip_unresolved_type
silent "fill: Explore (built-in outside the allowlist) is skipped" fill "$(payload "" Explore "$hard")" skip_unresolved_type
silent "fill: plugin agent feature-dev:code-reviewer is skipped" fill "$(payload "" feature-dev:code-reviewer "$mech")" skip_unresolved_plugin
silent "fill: custom agent with frontmatter model is skipped" fill "$(payload "" pinned "$mech")" skip_pinned_model
silent "fill: name != filename, pinned model found by frontmatter name" fill "$(payload "" code-reviewer-x "$mech")" skip_pinned_model
silent "fill: unknown agent type is skipped" fill "$(payload "" made-up-agent "$hard")" skip_unresolved_type
o=$(run fill "$(payload "" free-agent "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 &&
  ok "fill: custom agent found by name in CLAUDE_CONFIG_DIR (file some-other-file.md), no model -> filled" || bad "fill free-agent: $o"
o=$(JEV_ROUTE_FILL_TYPES=general-purpose,Plan run fill "$(payload "" Plan "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 &&
  ok "fill: JEV_ROUTE_FILL_TYPES extends the allowlist" || bad "fill Plan: $o"

# CLAUDE_CODE_SUBAGENT_MODEL set -> never change a model
o=$(CLAUDE_CODE_SUBAGENT_MODEL=haiku run fill "$(payload "" general-purpose "$hard")")
[ -z "$o" ] && last_log | jq -e '.action == "skip_subagent_model_env"' >/dev/null && ok "fill: skipped when CLAUDE_CODE_SUBAGENT_MODEL is set" || bad "fill with env: $o"
o=$(CLAUDE_CODE_SUBAGENT_MODEL=haiku run escalate "$(payload haiku general-purpose "$hard")")
[ -z "$o" ] && ok "escalate: skipped when CLAUDE_CODE_SUBAGENT_MODEL is set" || bad "escalate with env: $o"

# escalate
o=$(run escalate "$(payload haiku general-purpose "$hard")")
if jq -e '.hookSpecificOutput.updatedInput.model == "opus" and (.hookSpecificOutput | has("permissionDecision") | not)' <<<"$o" >/dev/null 2>&1 &&
  last_log | jq -e '.action == "escalated" and (.reason | startswith("jev: haiku→opus"))' >/dev/null; then
  ok "escalate: haiku + hard review -> opus ($(last_log | jq -r .reason))"
else bad "escalate: expected haiku→opus, got: $o"; fi
o=$(run escalate "$(payload haiku feature-dev:code-reviewer "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 &&
  ok "escalate: an explicit low model on a plugin agent is still raised" || bad "escalate plugin: $o"
silent "escalate: never lowers opus on a mechanical task" escalate "$(payload opus general-purpose "$mech")" kept
o=$(run escalate "$(payload claude-haiku-5-5 general-purpose "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 &&
  ok "escalate: full haiku ID raised to opus" || bad "escalate: full ID not raised: $o"
for m in fable inherit; do
  silent "escalate: $m left alone" escalate "$(payload "$m" general-purpose "$hard")" skip_has_model
done
silent "escalate: model-less plugin agent is skipped (not filled)" escalate "$(payload "" feature-dev:code-explorer "$hard")" skip_unresolved_plugin

silent "off: no output" off "$(payload "" general-purpose "$hard")"

# route.jsonl: description only (<= 120 chars), never the prompt
long=$(printf 'd%.0s' $(seq 1 300))
run log "$(payload "" general-purpose "$mech" | jq -c --arg d "$long" '.tool_input.description = $d')" >/dev/null
if jq -e -s 'all(.[]; (has("prompt") | not) and ((.description // "") | length) <= 120)' "$JEV_HOME/log/route.jsonl" >/dev/null &&
  ! grep -q 'recieve' "$JEV_HOME/log/route.jsonl"; then
  ok "route.jsonl: description truncated to 120 chars, no prompt text"
else bad "route.jsonl contains prompt text or long description"; fi

echo "agent-route-api: $fails failure(s)"
[ "$fails" -eq 0 ]
