#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# agent-route-api.sh — agent-route.sh against the live Jev API (needs a key).
# Checks escalate (default) / fill / log / off semantics: escalate acts only on
# the exact aliases, never on model-less calls, full IDs, fable, inherit, fork,
# plugin agents or with CLAUDE_CODE_SUBAGENT_MODEL; the escalation confidence
# gate; the fill allowlist and sonnet floor; never-lower; updatedInput only.
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

# default mode is escalate: a model-less call is routed and logged, never changed
silent "default mode (escalate): model-less call left alone, Jev's pick logged" default "$(payload "" general-purpose "$hard")" logged
last_log | jq -e '.mode == "escalate" and .final_model == "opus" and (.route_id | startswith("r")) and (.reviewer_model == "opus")' >/dev/null &&
  ok "default mode logs route id, final_model opus and reviewer_model opus for a hard review" || bad "default-mode log line: $(last_log)"

# escalate: explicit aliases only
o=$(run default "$(payload haiku general-purpose "$hard")")
if jq -e '.hookSpecificOutput.updatedInput.model == "opus" and (.hookSpecificOutput | has("permissionDecision") | not)' <<<"$o" >/dev/null 2>&1 &&
  last_log | jq -e '.action == "escalated" and (.reason | startswith("jev: haiku→opus"))' >/dev/null; then
  ok "escalate: haiku + hard review -> opus ($(last_log | jq -r .reason | cut -c1-120))"
else bad "escalate: expected haiku→opus, got: $o"; fi
o=$(run escalate "$(payload sonnet general-purpose "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 && ok "escalate: sonnet + hard review -> opus" || bad "escalate sonnet: $o"
silent "escalate: never lowers opus (no Jev call needed)" escalate "$(payload opus general-purpose "$mech")" kept_opus
silent "escalate: sonnet on a mechanical task is kept" escalate "$(payload sonnet general-purpose "$mech")" kept
silent "escalate: full haiku ID is left alone" escalate "$(payload claude-haiku-5-5 general-purpose "$hard")" skip_has_model
for m in fable inherit; do
  silent "escalate: $m left alone" escalate "$(payload "$m" general-purpose "$hard")" skip_has_model
done
silent "escalate: plugin agent with an alias is left alone" escalate "$(payload haiku feature-dev:code-reviewer "$hard")" skip_plugin_agent
silent "escalate: fork is left alone" escalate "$(payload haiku fork "$hard")" skip_fork
o=$(CLAUDE_CODE_SUBAGENT_MODEL=haiku run escalate "$(payload haiku general-purpose "$hard")")
[ -z "$o" ] && last_log | jq -e '.action == "skip_subagent_model_env"' >/dev/null && ok "escalate: skipped when CLAUDE_CODE_SUBAGENT_MODEL is set" || bad "escalate with env: $o"
o=$(JEV_ROUTE_MIN_ESCALATE_CONF=1.01 run escalate "$(payload haiku general-purpose "$hard")")
[ -z "$o" ] && last_log | jq -e '.action == "kept_low_conf"' >/dev/null &&
  ok "escalate: below JEV_ROUTE_MIN_ESCALATE_CONF the explicit choice stands ($(last_log | jq -r .reason | cut -c1-100))" || bad "escalation gate: $o"
silent "escalate: model-less plugin agent is not filled" escalate "$(payload "" feature-dev:code-explorer "$hard")" logged

# fill (opt-in): escalate + model-less allowlisted calls, sonnet floor
p=$(payload "" general-purpose "$mech")
o=$(run fill "$p")
if jq -e --argjson p "$p" '.hookSpecificOutput
    | .hookEventName == "PreToolUse" and (has("permissionDecision") | not) and (has("permissionDecisionReason") | not)
      and .updatedInput == ($p.tool_input + {model: "sonnet"})' <<<"$o" >/dev/null 2>&1 &&
  last_log | jq -e '.action == "filled" and .final_model == "sonnet" and (.reason | startswith("jev: none→sonnet"))' >/dev/null; then
  ok "fill: model-less mechanical call -> sonnet (floor), updatedInput only, reason in log"
else bad "fill floor: out=$o log=$(last_log)"; fi
o=$(run fill "$(payload "" general-purpose "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 && ok "fill: model-less hard review -> opus" || bad "fill hard: $o"
o=$(run fill "$(payload "" "" "$hard" | jq -c 'del(.tool_input.subagent_type)')")
jq -e '.hookSpecificOutput.updatedInput.model == "opus" and (.hookSpecificOutput.updatedInput | has("subagent_type") | not)' <<<"$o" >/dev/null 2>&1 &&
  ok "fill: missing subagent_type treated as general-purpose" || bad "fill no type: $o"
silent "fill: Explore (built-in outside the allowlist) is skipped" fill "$(payload "" Explore "$hard")" skip_unresolved_type
silent "fill: plugin agent feature-dev:code-reviewer is skipped" fill "$(payload "" feature-dev:code-reviewer "$mech")" skip_unresolved_plugin
silent "fill: custom agent with frontmatter model is skipped" fill "$(payload "" pinned "$mech")" skip_pinned_model
silent "fill: name != filename, pinned model found by frontmatter name" fill "$(payload "" code-reviewer-x "$mech")" skip_pinned_model
silent "fill: unknown agent type is skipped" fill "$(payload "" made-up-agent "$hard")" skip_unresolved_type
o=$(run fill "$(payload "" free-agent "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 &&
  ok "fill: custom agent found by name in CLAUDE_CONFIG_DIR (file some-other-file.md), no model -> filled" || bad "fill free-agent: $o"
o=$(JEV_ROUTE_FILL_TYPES=general-purpose,Plan run fill "$(payload "" Plan "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 && ok "fill: JEV_ROUTE_FILL_TYPES extends the allowlist" || bad "fill Plan: $o"
o=$(CLAUDE_CODE_SUBAGENT_MODEL=haiku run fill "$(payload "" general-purpose "$hard")")
[ -z "$o" ] && last_log | jq -e '.action == "skip_subagent_model_env"' >/dev/null && ok "fill: skipped when CLAUDE_CODE_SUBAGENT_MODEL is set" || bad "fill with env: $o"

silent "log: no output, decision logged" log "$(payload haiku general-purpose "$hard")" logged
silent "off: no output" off "$(payload haiku general-purpose "$hard")"

# route.jsonl: description only (<= 120 chars), never the prompt
long=$(printf 'd%.0s' $(seq 1 300))
run log "$(payload "" general-purpose "$mech" | jq -c --arg d "$long" '.tool_input.description = $d')" >/dev/null
if jq -e -s 'all(.[]; (has("prompt") | not) and ((.description // "") | length) <= 120)' "$JEV_HOME/log/route.jsonl" >/dev/null &&
  ! grep -q 'recieve' "$JEV_HOME/log/route.jsonl"; then
  ok "route.jsonl: description truncated to 120 chars, no prompt text"
else bad "route.jsonl contains prompt text or long description"; fi

echo "agent-route-api: $fails failure(s)"
[ "$fails" -eq 0 ]
