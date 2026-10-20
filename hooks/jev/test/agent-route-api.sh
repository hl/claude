#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# agent-route-api.sh — agent-route.sh against the live Jev API (needs a key), in
# a Claudette-scoped scratch project: an explicit haiku or sonnet without a
# route id is scored and raised (never lowered); a brief carrying a route.sh id
# takes that answer without a second Jev call; outside the scope nothing is sent.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../agent-route.sh"
JEV_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jev-ar.XXXXXX")
export JEV_HOME
unset CLAUDE_CODE_SUBAGENT_MODEL JEV_ROUTE_MODE JEV_SCOPE
PROJ="$JEV_HOME/proj"
mkdir -p "$PROJ"
: >"$PROJ/.orchestrator.md"
export CLAUDE_PROJECT_DIR="$PROJ"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
last_log() { tail -n 1 "$JEV_HOME/log/route.jsonl"; }
calls() { jq -s 'length' "$JEV_HOME/log/jev.jsonl" 2>/dev/null || echo 0; }
payload() { # <model-or-empty> <subagent_type> <prompt>
  jq -cn --arg m "$1" --arg t "$2" --arg p "$3" '{
    session_id: "test-agent-route", hook_event_name: "PreToolUse", tool_name: "Agent", tool_use_id: "toolu_test",
    tool_input: ({description: "test task", prompt: $p, subagent_type: $t} + (if $m == "" then {} else {model: $m} end))}'
}

mech="Fix the typo \"recieve\" -> \"receive\" on line 42 of README.md. Change nothing else."
hard="First-round review of PR #1601 (+1,240/-380 across 23 files), which moves session storage from cookies to Redis and changes the auth plug. Check correctness, security and migration safety."

o=$("$HOOK" <<<"$(payload haiku general-purpose "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus" and (.hookSpecificOutput | has("permissionDecision") | not)' <<<"$o" >/dev/null 2>&1 &&
  last_log | jq -e '.action == "escalated" and (.reason | startswith("jev: haiku→opus"))' >/dev/null &&
  ok "haiku + hard review -> opus ($(last_log | jq -r .reason | cut -c1-110))" || bad "haiku + hard review: $o"
o=$("$HOOK" <<<"$(payload sonnet general-purpose "$hard")")
jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$o" >/dev/null 2>&1 && ok "sonnet + hard review -> opus" || bad "sonnet + hard review: $o"
o=$("$HOOK" <<<"$(payload sonnet general-purpose "$mech")")
[ -z "$o" ] && [ "$(last_log | jq -r .action)" = kept ] && ok "sonnet on a one-line typo fix is kept ($(last_log | jq -c .policy))" || bad "sonnet + typo: $o $(last_log | jq -c '{action, jev_model, policy}')"

# haiku-keep: the two bos pollers (fixture r37, r38) that v3 raised to opus keep haiku;
# a requested haiku on real implementation work is still raised
for id in r37 r38; do
  line=$(jq -c --arg id "$id" 'select(.id == $id)' "$HERE/fixtures/route-eval-real.jsonl")
  n0=$(calls)
  o=$("$HOOK" <<<"$(jq -c '{session_id: "test-agent-route", hook_event_name: "PreToolUse", tool_name: "Agent", tool_use_id: "toolu_test",
    tool_input: {description, prompt, subagent_type, model: "haiku"}}' <<<"$line")")
  [ -z "$o" ] && last_log | jq -e '.action == "kept" and .final_model == "haiku" and (.policy[0] | startswith("haiku:"))' >/dev/null &&
    [ "$(calls)" = $((n0 + 1)) ] &&
    ok "bos poller $id ($(jq -r .description <<<"$line")) asked haiku -> kept haiku, 1 call ($(last_log | jq -r '.policy[0]'))" ||
    bad "bos poller $id: out=$o $(last_log | jq -c '{action, jev_model, probabilities, policy}')"
done
impl="Add a paginated GET /api/invoices endpoint to the Phoenix app: controller, context function with a cursor, JSON view and tests. Wait for review before merging."
o=$("$HOOK" <<<"$(payload haiku general-purpose "$impl")")
[ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$o")" != null ] && [ "$(last_log | jq -r .action)" = escalated ] &&
  ok "haiku on an endpoint implementation (contains \"wait for\") -> still raised to $(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$o")" ||
  bad "haiku + implementation: $o $(last_log | jq -c '{action, probabilities, policy}')"

# routed by route.sh: the hook takes that answer and makes no call of its own
r=$("$HERE/../route.sh" --context '{"kind":"review","diff_size":"+1240/-380 in 23 files"}' "$hard")
rid=$(jq -r .id <<<"$r")
n0=$(calls)
o=$("$HOOK" <<<"$(payload sonnet general-purpose "Route: $rid
$hard")")
want=$(jq -r .model <<<"$r")
if [ "$want" = opus ]; then
  [ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$o")" = opus ] && [ "$(calls)" = "$n0" ] &&
    ok "a brief with route id $rid (route.sh: opus) given sonnet -> opus, no second Jev call" || bad "routed raise: $o"
else bad "route.sh routed a hard review to $want"; fi

# nothing that cannot change is sent
n0=$(calls)
for m in "" opus fable claude-haiku-5-5; do "$HOOK" <<<"$(payload "$m" general-purpose "$hard")" >/dev/null; done
"$HOOK" <<<"$(payload haiku feature-dev:code-reviewer "$hard")" >/dev/null
CLAUDE_PROJECT_DIR="$JEV_HOME" "$HOOK" <<<"$(payload haiku general-purpose "$hard")" >/dev/null
[ "$(calls)" = "$n0" ] && ok "model-less, opus, fable, full ID, plugin agent, and any call outside a Claudette project -> no Jev call" || bad "$(($(calls) - n0)) unexpected Jev call(s)"

jq -e -s 'all(.[]; (has("prompt") | not) and ((.description // "") | length) <= 120)' "$JEV_HOME/log/route.jsonl" >/dev/null && ! grep -q 'recieve' "$JEV_HOME/log/route.jsonl" &&
  ok "route.jsonl: no prompt text" || bad "route.jsonl contains prompt text"

echo "agent-route-api: $fails failure(s)"
[ "$fails" -eq 0 ]
