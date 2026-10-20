#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# offline-hooks.sh — hook behaviour without the real API: the routing policy as
# code, and route.sh, the Agent hook, artifacts, compaction requests, injection
# and the daily sweep against a local fake Jev (fake-jev.py: every score
# "important", every noul 0.1, every choice its first option at 0.9).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID JEV_ROUTE_MODE JEV_SCOPE CLAUDE_CODE_SUBAGENT_MODEL
W=$(mktemp -d "${TMPDIR:-/tmp}/jev-offh.XXXXXX")
export JEV_HOME="$W/home"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
bodies() { find "$W/cap" -name 'body-*.json' 2>/dev/null | wc -l | tr -d ' '; }

# --- 1. policy.jq (pure jq, no API)
pol() { jq -c -n -L "$J" --argjson in "$1" 'include "policy"; $in | route_policy'; }
expect() { # <label> <input> <jq-condition>
  local o
  o=$(pol "$2")
  jq -e "$3" <<<"$o" >/dev/null 2>&1 && ok "policy: $1" || bad "policy: $1 -> $o"
}
easy='{"probabilities":{"haiku":0.95,"sonnet":0.05,"opus":0},"confidence":0.9,"signals":{"mechanical":0.9,"security_or_high_blast_radius":0.05,"review_of_nontrivial_diff":0.02,"nontrivial_change":0.05}}'
mid='{"probabilities":{"haiku":0.02,"sonnet":0.9,"opus":0.08},"confidence":0.85,"signals":{"mechanical":0.3,"security_or_high_blast_radius":0.2,"review_of_nontrivial_diff":0.05,"nontrivial_change":0.4}}'
expect "sure, mechanical, safe -> haiku, reviewer sonnet" "$easy" '.model == "haiku" and .reviewer_model == "sonnet" and (keys == ["model", "policy", "reviewer_model"])'
expect "P(haiku) 0.8 is not enough for haiku -> sonnet" "$(jq -c '.probabilities = {haiku: 0.8, sonnet: 0.2, opus: 0}' <<<"$easy")" '.model == "sonnet"'
expect "mechanical 0.6 is not enough for haiku" "$(jq -c '.signals.mechanical = 0.6' <<<"$easy")" '.model == "sonnet"'
expect "security 0.55 rules out haiku and sonnet -> opus" "$(jq -c '.signals.security_or_high_blast_radius = 0.55' <<<"$easy")" '.model == "opus" and .reviewer_model == "opus"'
expect "kind poll -> haiku whatever Jev says" "$(jq -c '.ctx = {kind: "poll"} | .probabilities = {haiku: 0.1, sonnet: 0.3, opus: 0.6}' <<<"$mid")" '.model == "haiku" and .policy[0] == "haiku: kind poll"'
expect "kind fetch and lookup -> haiku" "$(jq -c '.ctx = {kind: "fetch"}' <<<"$mid")" '.model == "haiku"'
expect "kind poll with security 0.8 -> opus (the gate wins)" "$(jq -c '.ctx = {kind: "poll"} | .signals.security_or_high_blast_radius = 0.8' <<<"$mid")" '.model == "opus"'
expect "risky path on a poll task -> no bump" "$(jq -c '.ctx = {kind: "poll", risky_paths: [".github/workflows/ci.yml"]}' <<<"$easy")" '.model == "haiku"'
expect "P(opus) 0.08, no signal -> sonnet" "$mid" '.model == "sonnet" and .reviewer_model == "sonnet"'
expect "P(opus) 0.2 -> opus (default)" "$(jq -c '.probabilities = {haiku: 0, sonnet: 0.8, opus: 0.2}' <<<"$mid")" '.model == "opus" and (.policy[0] | test("default"))'
expect "review signal 0.55 rules out sonnet" "$(jq -c '.signals.review_of_nontrivial_diff = 0.55' <<<"$mid")" '.model == "opus"'
expect "security 0.8 -> opus, reviewer opus" "$(jq -c '.signals.security_or_high_blast_radius = 0.8' <<<"$mid")" '.model == "opus" and .reviewer_model == "opus" and (.policy[0] | test("security"))'
expect "non-trivial change -> reviewer opus over a sonnet implementer" "$(jq -c '.signals.nontrivial_change = 0.7' <<<"$mid")" '.model == "sonnet" and .reviewer_model == "opus"'
expect "retry (attempt 2 after sonnet) -> opus" "$(jq -c '.ctx = {attempt: 2, prior_model: "sonnet", prior_outcome: "thin"}' <<<"$mid")" '.model == "opus" and any(.policy[]; test("retry"))'
expect "retry after haiku -> sonnet at least" "$(jq -c '.ctx = {attempt: 2, prior_model: "haiku"}' <<<"$easy")" '.model == "sonnet"'
expect "poll retried after haiku -> sonnet" "$(jq -c '.ctx = {kind: "poll", attempt: 2, prior_model: "haiku"}' <<<"$mid")" '.model == "sonnet"'
expect "prior_outcome \"review FAIL x2\" counts as a retry" "$(jq -c '.ctx = {prior_outcome: "review FAIL x2", prior_model: "sonnet"}' <<<"$mid")" '.model == "opus"'
expect "prior_outcome \"PASS, no failures\" is not a retry" "$(jq -c '.ctx = {prior_outcome: "PASS, no failures", prior_model: "sonnet"}' <<<"$mid")" '.model == "sonnet"'
expect "risky path on an implement task -> opus" "$(jq -c '.ctx = {kind: "implement", risky_paths: ["priv/repo/migrations/1_add.exs"]}' <<<"$mid")" '.model == "opus" and any(.policy[]; test("high-blast-radius"))'
expect "investigate is at least sonnet" "$(jq -c '.ctx = {kind: "investigate"}' <<<"$easy")" '.model == "sonnet" and any(.policy[]; test("kind investigate"))'
expect "6 files rule out haiku" "$(jq -c '.ctx = {files: 6}' <<<"$easy")" '.model == "sonnet"'
expect "12 files mean opus" "$(jq -c '.ctx = {files: 12}' <<<"$mid")" '.model == "opus"'
# haiku-keep (Agent hook, requested haiku, no Route: id): the two bos pollers raised to opus in v3
bos1='{"probabilities":{"haiku":0.99,"sonnet":0.01,"opus":0},"signals":{"mechanical":0.52,"security_or_high_blast_radius":0.1,"review_of_nontrivial_diff":0.56,"nontrivial_change":0.03}}'
bos2='{"probabilities":{"haiku":1,"sonnet":0,"opus":0},"signals":{"mechanical":0.67,"security_or_high_blast_radius":0.13,"review_of_nontrivial_diff":0.5,"nontrivial_change":0.06}}'
expect "bos poller 1 without hook context -> opus (the v3 raise)" "$bos1" '.model == "opus"'
expect "bos poller 1, requested haiku + poll verb -> haiku kept" "$(jq -c '.ctx = {requested: "haiku", poll_verb: true}' <<<"$bos1")" '.model == "haiku" and (.policy[0] | test("poll/fetch"))'
expect "bos poller 2, requested haiku + poll verb -> haiku kept" "$(jq -c '.ctx = {requested: "haiku", poll_verb: true}' <<<"$bos2")" '.model == "haiku"'
expect "bos poller 1, no poll verb: review 0.56 >= 0.5 -> opus" "$(jq -c '.ctx = {requested: "haiku", poll_verb: false}' <<<"$bos1")" '.model == "opus"'
expect "requested haiku, P(haiku) 0.96, mechanical 0.3, signals low -> haiku kept" "$(jq -c '.ctx = {requested: "haiku"} | .probabilities = {haiku: 0.96, sonnet: 0.04, opus: 0} | .signals.mechanical = 0.3' <<<"$easy")" '.model == "haiku" and (.policy[0] | test("requested haiku kept, P"))'
expect "requested haiku, P(haiku) 0.94, no poll verb -> not kept" "$(jq -c '.ctx = {requested: "haiku"} | .probabilities = {haiku: 0.94, sonnet: 0.06, opus: 0} | .signals.mechanical = 0.3' <<<"$easy")" '.model != "haiku"'
expect "requested haiku, P(haiku) 0.99 but security 0.5 -> not kept" "$(jq -c '.ctx = {requested: "haiku"} | .probabilities = {haiku: 0.99, sonnet: 0.01, opus: 0} | .signals.mechanical = 0.3 | .signals.security_or_high_blast_radius = 0.5' <<<"$easy")" '.model == "opus"'
expect "poll verb, P(haiku) 0.79 -> not kept" "$(jq -c '.ctx = {requested: "haiku", poll_verb: true} | .probabilities = {haiku: 0.79, sonnet: 0.01, opus: 0.2} | .signals.mechanical = 0.3' <<<"$easy")" '.model == "opus"'
expect "poll verb with security 0.8 -> opus (the gate wins)" "$(jq -c '.ctx = {requested: "haiku", poll_verb: true} | .signals.security_or_high_blast_radius = 0.8' <<<"$bos2")" '.model == "opus"'
expect "poll verb with security 0.6 (under the gate) -> not kept" "$(jq -c '.ctx = {requested: "haiku", poll_verb: true} | .signals.security_or_high_blast_radius = 0.6' <<<"$bos2")" '.model == "opus"'
expect "poll verb, review 0.6, security 0.13 -> kept (review is not capped)" "$(jq -c '.ctx = {requested: "haiku", poll_verb: true} | .signals.review_of_nontrivial_diff = 0.6' <<<"$bos2")" '.model == "haiku"'
expect "poll verb but sonnet requested -> no keep rule" "$(jq -c '.ctx = {requested: "sonnet", poll_verb: true}' <<<"$bos1")" '.model == "opus"'
hc() { jq -c -L "$J" 'include "policy"; hook_context' <<<"$1"; }
[ "$(hc '{"model":"haiku","description":"Watch PR 487 checks","prompt":"x"}')" = '{"requested":"haiku","poll_verb":true}' ] &&
  [ "$(hc '{"model":"haiku","description":"Run the suite","prompt":"Download the build log and report it"}')" = '{"requested":"haiku","poll_verb":true}' ] &&
  [ "$(hc "$(jq -cn '{model: "haiku", description: "Rename a module", prompt: (("x" * 200) + " then poll CI")}')")" = '{"requested":"haiku","poll_verb":false}' ] &&
  [ "$(hc '{"model":"haiku","description":"Review the detail view","prompt":"Check the retail totals"}')" = '{"requested":"haiku","poll_verb":false}' ] &&
  ok "policy: hook_context finds a poll/fetch verb in the first 200 chars only, whole words" || bad "policy: hook_context"

# --- 1b. anchor lines: stripped only when a tier follows the label
anchor_probe() { jq -R -r -L "$J" 'include "anchors"; if anchor_line then "strip" else "keep" end'; }
strip_lines=(
  "Model: opus — cross-cutting change across three services"
  "**Model:** opus (first-round review of a non-trivial diff)"
  "jev: sonnet/opus 0.81 [bumped]"
  "jev: opus/opus 0.92 [opus: P(opus) 0.92 > 0.35]"
  "Model: haiku — poll CI, no judgement"
  "- Model: haiku — poll CI"
  "> model: sonnet"
  "Why opus: the change touches auth and billing"
  "Tier: sonnet — routine fix with tests"
  "Chosen model: opus, because the design is open"
  "Model (opus): first-round review"
  "Model choice: sonnet"
  "  * model tier: haiku"
)
keep_lines=(
  "jev: route.sh returns a wrong reviewer_model when kind is review; fix it"
  "JEV: the Jev hooks under hooks/jev need a README fix"
  "Model: User schema lives in lib/app/accounts/user.ex"
  "model: claude-haiku-5-5"
  "- the model haiku - and the model sonnet differ in context size"
  "Model picker Opus gate"
  "data model: users table has a unique email index"
  "## Model choice"
  "Fix the Model: field validation in the form"
  "Use opus-level care here; the migration is risky"
  "We chose sonnet last time and it worked"
  "jev: compaction hooks: keep facts"
  "Model: see the ADR for the data model"
  "Route: r1792491674-30786-23727"
)
bad_anchor=0
for l in "${strip_lines[@]}"; do [ "$(printf '%s\n' "$l" | anchor_probe)" = strip ] || { bad_anchor=$((bad_anchor + 1)); echo "     should strip: $l"; }; done
for l in "${keep_lines[@]}"; do [ "$(printf '%s\n' "$l" | anchor_probe)" = keep ] || { bad_anchor=$((bad_anchor + 1)); echo "     should keep: $l"; }; done
[ "$bad_anchor" -eq 0 ] && ok "anchors: ${#strip_lines[@]} tier-naming lines stripped, ${#keep_lines[@]} look-alikes kept" || bad "anchors: $bad_anchor probe lines wrong"

# --- fake Jev for everything below
port=$((20000 + RANDOM % 20000))
python3 -I "$HERE/fake-jev.py" "$port" "$W/cap" >"$W/fake.out" 2>&1 &
fpid=$!
trap 'kill $fpid 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q ready "$W/fake.out" 2>/dev/null && break; sleep 0.1; done
export TYPESAFE_BASE_URL="http://127.0.0.1:$port" TYPESAFE_API_KEY=apikFAKEOFFLINE

# --- 2. route.sh
"$J/route.sh" --context 'not json' "x" >/dev/null 2>&1
[ $? -eq 2 ] && ok "route.sh: bad --context exits 2" || bad "route.sh: bad --context"
o=$("$J/route.sh" --context '{"kind":"implement","paths":["lib/app/auth/session.ex","README.md"],"files_hint":["a.ex","b.ex"]}' "Add a field.")
jq -e '(.id | test("^r[0-9]+-[0-9]+-[0-9]+$")) and .model == "opus" and (keys == ["confidence", "id", "model", "policy", "probabilities", "reviewer_model"])' <<<"$o" >/dev/null &&
  ok "route.sh: output is exactly {id, model, reviewer_model, confidence, probabilities, policy}; auth path -> opus" || bad "route.sh output: $o"
tail -n 1 "$JEV_HOME/log/route.jsonl" | jq -e --arg id "$(jq -r .id <<<"$o")" '.action == "route" and .id == $id and .context.files == 2 and .context.risky_paths == ["lib/app/auth/session.ex"] and (has("task") | not)' >/dev/null &&
  ok "route.sh: logged with id and normalised context, no task text" || bad "route.sh log: $(tail -n 1 "$JEV_HOME/log/route.jsonl")"
jq -e '.state.context.kind == "implement" and (.state.context | has("risky_paths") | not) and (.questions | keys == ["mechanical", "nontrivial_change", "review_of_nontrivial_diff", "security_or_high_blast_radius", "tier"])' \
  "$(find "$W/cap" -name 'body-*.json' | sort | tail -n 1)" >/dev/null &&
  ok "route.sh: one request, Jev state {task, context}, five questions" || bad "route.sh: request body"
CLAUDE_CODE_SESSION_ID=sess-cli-1 "$J/route.sh" "Add a field." >/dev/null
tail -n 1 "$JEV_HOME/log/route.jsonl" | jq -e '.action == "route" and .session_id == "sess-cli-1"' >/dev/null &&
  tail -n 1 "$JEV_HOME/log/jev.jsonl" | jq -e '.session_id == "sess-cli-1"' >/dev/null &&
  ok "route.sh: a CLI run records \$CLAUDE_CODE_SESSION_ID as session_id (route.jsonl and jev.jsonl)" || bad "route.sh session: $(tail -n 1 "$JEV_HOME/log/route.jsonl")"
o=$("$J/route.sh" --context '{"kind":"poll"}' "Model: opus — because I said so
Poll CI on PR 12 every minute until it is green or red; change nothing.")
jq -e '.model == "haiku"' <<<"$o" >/dev/null && ! grep -q 'because I said so' "$(find "$W/cap" -name 'body-*.json' | sort | tail -n 1)" &&
  ok "route.sh: kind poll -> haiku; the \"Model: opus\" anchor line never reaches Jev" || bad "route.sh poll/anchor: $o"

# --- 3. agent-route.sh: scope, skips without an API call, route ids, escalation
P="$W/proj"
mkdir -p "$P"
: >"$P/.orchestrator.md"
agent() { # <model-or-empty> <subagent_type> <prompt> -> hook stdout
  jq -cn --arg m "$1" --arg t "$2" --arg p "$3" '{session_id: "sAR", hook_event_name: "PreToolUse", tool_name: "Agent", tool_use_id: "toolu_ar",
    tool_input: ({description: "test task", prompt: $p, subagent_type: $t} + (if $m == "" then {} else {model: $m} end))}' |
    CLAUDE_PROJECT_DIR="$P" "$J/agent-route.sh"
}
last_action() { tail -n 1 "$JEV_HOME/log/route.jsonl" | jq -r .action; }
n0=$(bodies)
lines0=$(wc -l <"$JEV_HOME/log/route.jsonl" | tr -d ' ')
o=$(jq -cn '{session_id: "sAR", hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: {prompt: "x", model: "haiku"}}' | CLAUDE_PROJECT_DIR="$W" "$J/agent-route.sh")
[ -z "$o" ] && [ "$(bodies)" = "$n0" ] && [ "$(wc -l <"$JEV_HOME/log/route.jsonl" | tr -d ' ')" = "$lines0" ] &&
  ok "agent-route: no .orchestrator.md at CLAUDE_PROJECT_DIR -> exit before anything (no call, no log line)" || bad "agent-route out of scope: $o"
o=$(jq -cn '{session_id: "sAR", hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: {prompt: "x", model: "haiku"}}' | env -u CLAUDE_PROJECT_DIR JEV_SCOPE=all "$J/agent-route.sh")
[ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$o")" = sonnet ] && [ "$(bodies)" = $((n0 + 1)) ] &&
  ok "agent-route: JEV_SCOPE=all acts without an .orchestrator.md" || bad "agent-route JEV_SCOPE=all: $o"
n0=$(bodies)
for c in ":general-purpose:skip_no_model" "opus:general-purpose:kept_opus" "claude-haiku-5-5:general-purpose:skip_has_model" \
  "fable:general-purpose:skip_has_model" "inherit:general-purpose:skip_has_model" "haiku:fork:skip_fork" "haiku:feature-dev:code-reviewer:skip_plugin_agent"; do
  m=${c%%:*} rest=${c#*:} want=${c##*:}
  t=${rest%:*}
  o=$(agent "$m" "$t" "Review the auth plug.")
  [ -z "$o" ] && [ "$(last_action)" = "$want" ] || bad "agent-route ${m:-no model}/$t: out=$o action=$(last_action), want $want"
done
o=$(CLAUDE_CODE_SUBAGENT_MODEL=haiku agent haiku general-purpose "Review the auth plug.")
[ -z "$o" ] && [ "$(last_action)" = skip_subagent_model_env ] || bad "agent-route with CLAUDE_CODE_SUBAGENT_MODEL: $o"
[ "$(bodies)" = "$n0" ] && ok "agent-route: no model, opus, full ID, fable, inherit, fork, plugin agent, CLAUDE_CODE_SUBAGENT_MODEL -> left alone, logged, no Jev call" ||
  bad "agent-route: $(($(bodies) - n0)) Jev call(s) where nothing could change"
# a brief carrying route.sh's id: never re-scored; raised to the routed tier when lower
rid=$("$J/route.sh" --context '{"kind":"implement","paths":["lib/app/auth/session.ex"]}' "Rotate the session tokens." | jq -r .id)
n0=$(bodies)
o=$(agent sonnet general-purpose "Route: $rid
Rotate the session tokens.")
[ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$o")" = opus ] && [ "$(last_action)" = raised_to_route ] && [ "$(bodies)" = "$n0" ] &&
  ok "agent-route: a brief with route id $rid (route said opus) given sonnet -> raised to opus from route.jsonl, no Jev call" || bad "agent-route route id raise: $o $(last_action)"
rid2=$("$J/route.sh" --context '{"kind":"poll"}' "Poll CI." | jq -r .id)
n0=$(bodies)
o=$(agent haiku general-purpose "Poll CI on PR 12.
  Route: $rid2")
[ -z "$o" ] && [ "$(last_action)" = kept_routed ] && [ "$(bodies)" = "$n0" ] &&
  ok "agent-route: route said haiku, brief asks haiku -> kept, no Jev call" || bad "agent-route kept_routed: $o"
o=$(agent sonnet general-purpose "Route: $rid2
Retry of the earlier brief.
Route: $rid")
[ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$o")" = opus ] && [ "$(bodies)" = "$n0" ] &&
  ok "agent-route: of two Route: lines the last one wins (opus), no Jev call" || bad "agent-route last Route: line: $o"
# not a Route: line, or an id route.sh never logged: scored like any brief (the fake answers sonnet)
scored=0
for p in "jev: $rid" "See pr$rid for context." "Route: $rid (inline)" "Route: r1700000000-1-1"; do
  n0=$(bodies)
  o=$(agent haiku general-purpose "$p")
  if [ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$o")" = sonnet ] && [ "$(last_action)" = escalated ] && [ "$(bodies)" = $((n0 + 1)) ]; then
    scored=$((scored + 1))
  else bad "agent-route should have scored \"$p\": $o $(last_action)"; fi
done
[ "$scored" = 4 ] && ok "agent-route: an id outside a whole \"Route: <id>\" line, or one not in route.jsonl, is not trusted: the brief is scored (1 call each)"
# no route id: one Jev call; the fake answers sonnet
n0=$(bodies)
o=$(agent haiku general-purpose "Add a paginated GET /api/invoices endpoint with tests.")
jq -e '.hookSpecificOutput | .updatedInput.model == "sonnet" and .updatedInput.prompt != null and (has("permissionDecision") | not)' <<<"$o" >/dev/null &&
  [ "$(last_action)" = escalated ] && [ "$(bodies)" = $((n0 + 1)) ] &&
  ok "agent-route: explicit haiku with no route id -> one Jev call, raised to route.sh's sonnet (updatedInput only)" || bad "agent-route escalate: $o"
o=$(agent sonnet general-purpose "Add a paginated GET /api/invoices endpoint with tests.")
[ -z "$o" ] && [ "$(last_action)" = kept ] || bad "agent-route kept: $o"
o=$(jq -cn '{session_id: "sAR", hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: {prompt: "x", model: "haiku"}}' | CLAUDE_PROJECT_DIR="$P" JEV_ROUTE_MODE=off "$J/agent-route.sh")
[ -z "$o" ] && ok "agent-route: sonnet at route.sh's tier kept; JEV_ROUTE_MODE=off does nothing" || bad "agent-route off: $o"
jq -e -s 'all(.[]; (has("prompt") | not) and ((.description // "") | length) <= 120)' "$JEV_HOME/log/route.jsonl" >/dev/null && ! grep -q 'paginated' "$JEV_HOME/log/route.jsonl" &&
  ok "route.jsonl: no prompt text" || bad "route.jsonl holds prompt text"

# --- 4. artifact.sh
p=$(printf '# Findings\nall good\n' | CLAUDE_CODE_SESSION_ID=sA "$J/artifact.sh" "review r1")
[ "$p" = "$JEV_HOME/artifacts/sA/review-r1.md" ] && [ -f "$p" ] && ok "artifact.sh: session from \$CLAUDE_CODE_SESSION_ID, name sanitised -> review-r1.md" || bad "artifact.sh path: $p"
printf 'round two\n' | CLAUDE_CODE_SESSION_ID=sA "$J/artifact.sh" "review r1" >/dev/null
[ "$(cat "$p")" = "round two" ] && ok "artifact.sh: saving the same name again replaces the file" || bad "artifact re-save"
(cd "$W" && printf 'x\n' | "$J/artifact.sh" nothing >/dev/null 2>&1)
[ $? -eq 2 ] && ok "artifact.sh: no session id -> exit 2" || bad "artifact.sh without session"
p=$(printf 'x\n' | "$J/artifact.sh" "../../etc/evil name" --session sA)
[ "$p" = "$JEV_HOME/artifacts/sA/etc-evil-name.md" ] && ok "artifact.sh: path characters stripped from names" || bad "name sanitising: $p"

# --- 5. artifact-hook.sh (PostToolUse Agent + SubagentStop)
long=$(printf 'Finding line %s with enough words to make the result long.\n' $(seq 1 60))
post() { # <text> <agent-id> [status] [model]; the text goes through a file, so it can be larger than ARG_MAX
  local tf
  tf=$(mktemp "$W/post.XXXXXX")
  printf '%s' "$1" >"$tf"
  jq -cn --rawfile t "$tf" --arg a "$2" --arg st "${3:-completed}" --arg m "${4-claude-opus-5-5}" '{session_id: "sH", hook_event_name: "PostToolUse", tool_name: "Agent", tool_use_id: ("toolu_" + $a),
  tool_input: {description: "Review the auth plug", subagent_type: "general-purpose", model: "opus"},
  tool_response: ({status: $st, agentId: $a, content: [{type: "text", text: $t}]} + (if $m == "" then {} else {resolvedModel: $m} end))}' | "$J/artifact-hook.sh"
  rm -f "$tf"
}
ctxof() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"; }
o=$(post "$long" ag1)
f=$(ctxof "$o" | sed -n 's/^Subagent result (Review the auth plug) saved to //p')
[ "$(ctxof "$o" | head -n 1)" = "Subagent ran on claude-opus-5-5." ] && jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$o" >/dev/null &&
  [ -f "$f" ] && grep -q 'Finding line 60' "$f" && case $f in */artifacts/sH/agent-1-review-the-auth-plug-ag1.md) true ;; *) false ;; esac &&
  ok "artifact-hook: long result -> \"Subagent ran on claude-opus-5-5.\" + saved as agent-1-review-the-auth-plug-ag1.md, path cited" || bad "artifact-hook PostToolUse: $o"
o=$(post "short answer" ag2)
[ "$(ctxof "$o")" = "Subagent ran on claude-opus-5-5." ] && ok "artifact-hook: short result -> only the ran-on line, nothing saved" || bad "artifact-hook short: $o"
[ -z "$(post "short answer" ag2b completed "")" ] && ok "artifact-hook: no resolvedModel and nothing saved -> no output" || bad "artifact-hook no model"
o=$(jq -cn '{session_id: "sH", hook_event_name: "PostToolUse", tool_name: "Agent", tool_input: {description: "bg"},
  tool_response: "{\"isAsync\":true,\"status\":\"async_launched\",\"agentId\":\"ag3\",\"resolvedModel\":\"claude-sonnet-5-5\"}"}' | "$J/artifact-hook.sh")
[ "$(ctxof "$o")" = "Background subagent running on claude-sonnet-5-5." ] && ok "artifact-hook: background launch (string tool_response) -> \"Background subagent running on <model>.\"" || bad "artifact-hook async: $o"
# an escalation by agent-route.sh is named
jq -cn '{action: "escalated", tool_use_id: "toolu_agE", given_model: "haiku", final_model: "sonnet"}' >>"$JEV_HOME/log/route.jsonl"
o=$(post "short" agE completed claude-sonnet-5-5)
[ "$(ctxof "$o")" = "Subagent ran on claude-sonnet-5-5 (raised from haiku by the Jev Agent hook)." ] && ok "artifact-hook: an override by the Agent hook is named in the ran-on line" || bad "artifact-hook override note: $o"
jq -cn --arg t "$long" '{session_id: "sH", hook_event_name: "SubagentStop", agent_id: "ag4", agent_type: "general-purpose", last_assistant_message: $t,
  background_tasks: [{id: "ag4", description: "Survey retry logic", agent_type: "general-purpose", status: "running"}]}' | "$J/artifact-hook.sh"
f4=$(find "$JEV_HOME/artifacts/sH" -name 'agent-*-survey-retry-logic-ag4.md')
[ -n "$f4" ] && ok "artifact-hook: background agent saved on SubagentStop ($(basename "$f4"))" || bad "artifact-hook SubagentStop"
o=$(post "$long" ag4)
[ "$(ctxof "$o" | tail -n 1)" = "Subagent result (Review the auth plug) saved to $f4" ] && [ "$(find "$JEV_HOME/artifacts/sH" -name 'agent-*.md' | wc -l | tr -d ' ')" = 2 ] &&
  ok "artifact-hook: SubagentStop then PostToolUse for the same agent -> one file, same path" || bad "artifact-hook dedupe: $o"
jq -cn --arg t "<summary>$long</summary>" '{session_id: "sH", hook_event_name: "SubagentStop", agent_id: "acmp", agent_type: "", last_assistant_message: $t}' | "$J/artifact-hook.sh"
jq -cn --arg t "$long" '{session_id: "sH", hook_event_name: "SubagentStop", agent_id: "ag5", agent_type: "general-purpose", last_assistant_message: $t, background_tasks: []}' | "$J/artifact-hook.sh"
[ "$(find "$JEV_HOME/artifacts/sH" -name 'agent-*.md' | wc -l | tr -d ' ')" = 2 ] &&
  ok "artifact-hook: the compaction agent and a foreground agent's SubagentStop are not saved" || bad "artifact-hook saved a compaction summary or foreground SubagentStop"
# two agents with the same description finishing together: two files, each parent told its own
for run in 1 2 3; do
  cpids=()
  for a in "par${run}x" "par${run}y"; do
    (post "$(printf 'RESULT-OF-%s line %s with enough words to be long.\n' "$a" $(seq 1 80))" "$a" >"$W/ctx-$a.json") &
    cpids+=($!)
  done
  wait "${cpids[@]}"
done
good=0
for run in 1 2 3; do for a in "par${run}x" "par${run}y"; do
  p=$(jq -r '.hookSpecificOutput.additionalContext // empty' "$W/ctx-$a.json" | sed -n 's/^Subagent result (Review the auth plug) saved to //p')
  [ -f "$p" ] && grep -q "RESULT-OF-$a " "$p" && good=$((good + 1))
done; done
[ "$good" = 6 ] && [ "$(find "$JEV_HOME/artifacts/sH" -name 'agent-*-par*.md' | wc -l | tr -d ' ')" = 6 ] &&
  ok "artifact-hook: 3 x 2 same-description agents finishing together -> 6 files, each parent pointed at its own" || bad "artifact-hook concurrency: $good of 6"
jq -e -s '[.[] | select(.action == "ran")] | length >= 8 and any(.[]; .tool_use_id == "toolu_ag1" and .agent_id == "ag1" and .resolved_model == "claude-opus-5-5")' "$JEV_HOME/log/route.jsonl" >/dev/null &&
  ok "artifact-hook: every PostToolUse(Agent) logs action ran with resolved_model and tool_use_id" || bad "ran records missing"
# Claude Code 2.1.304 shapes: handbackReport.text, and SubagentStop without last_assistant_message
jq -cn '{session_id: "sH", hook_event_name: "PostToolUse", tool_name: "Agent", tool_use_id: "toolu_hb1",
  tool_input: {description: "Handback check", subagent_type: "general-purpose"},
  tool_response: {status: "completed", agentId: "aghb1", resolvedModel: "claude-haiku-5-5", handback: "send",
    handbackReport: {text: "Artifact: handback-note\nthe real report"},
    content: [{type: "text", text: "This agent report was delivered to you as a message."}]}}' | "$J/artifact-hook.sh" >/dev/null
grep -q 'the real report' "$JEV_HOME/artifacts/sH/handback-note.md" 2>/dev/null && ok "artifact-hook: a SubagentHandback report (handbackReport.text) is what gets saved" || bad "handback report"
ATP="$W/agent-hb2.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "SubagentHandback", input: {message: "Artifact: bg-handback\nbackground report"}}]}}' >"$ATP"
jq -cn --arg atp "$ATP" '{session_id: "sH", hook_event_name: "SubagentStop", agent_id: "aghb2", agent_type: "general-purpose", agent_transcript_path: $atp,
  background_tasks: [{id: "aghb2", description: "Background handback", status: "running"}]}' | "$J/artifact-hook.sh"
grep -q 'background report' "$JEV_HOME/artifacts/sH/bg-handback.md" 2>/dev/null && ok "artifact-hook: SubagentStop without last_assistant_message reads the handback from agent_transcript_path" || bad "background handback"
# "Artifact: <name>" is saved whatever its length, under that name
o=$(post "Artifact: review-auth-r1
Two blocking findings: tokens are not rotated; the session cookie lacks SameSite." agm1)
fm="$JEV_HOME/artifacts/sH/review-auth-r1.md"
[ -f "$fm" ] && [ "$(ctxof "$o")" = "Subagent ran on claude-opus-5-5.
Subagent result (Review the auth plug) saved to $fm" ] &&
  ok "artifact-hook: a short \"Artifact: review-auth-r1\" reply is saved as review-auth-r1.md, both lines cited" || bad "artifact marker: $o"
post "Artifact: review-auth-r1
A second opinion." agm2 >/dev/null
[ -f "$JEV_HOME/artifacts/sH/review-auth-r1-agm2.md" ] && grep -q 'SameSite' "$fm" &&
  ok "artifact-hook: the same name from another agent becomes review-auth-r1-agm2.md" || bad "artifact marker collision"
o=$(JEV_ARTIFACTS=0 post "$long" agoff)
[ "$(ctxof "$o")" = "Subagent ran on claude-opus-5-5." ] && [ -z "$(find "$JEV_HOME/artifacts/sH" -name '*agoff*')" ] &&
  ok "artifact-hook: JEV_ARTIFACTS=0 saves nothing but still says which model ran" || bad "JEV_ARTIFACTS=0: $o"
huge=$(head -c 1500000 /dev/zero | tr '\0' 'y')
post "$huge" aghuge >/dev/null
jq -e -s 'any(.[]; .action == "ran" and .agent_id == "aghuge" and has("input_model"))' "$JEV_HOME/log/route.jsonl" >/dev/null &&
  ok "artifact-hook: a 1.5 MB result still logs its ran record" || bad "ran record for a 1.5 MB result"
fb=$(find "$JEV_HOME/artifacts/sH" -name 'agent-*-aghuge.md')
[ -n "$fb" ] && [ "$(wc -c <"$fb" | tr -d ' ')" -lt 530000 ] && tail -n 1 "$fb" | grep -q 'truncated by the Jev artifact hook' &&
  ok "artifact-hook: a 1.5 MB result is cut to 512 KB with a note" || bad "artifact cap"
mb=$(printf 'é%.0s' $(seq 1 300000))
post "$mb" agmb >/dev/null
fmb=$(find "$JEV_HOME/artifacts/sH" -name 'agent-*-agmb.md')
[ -n "$fmb" ] && iconv -f UTF-8 -t UTF-8 "$fmb" >/dev/null 2>&1 && ok "artifact-hook: the 512 KB cut leaves valid UTF-8" || bad "artifact cut split a character"

# --- 6. compaction: one Jev request each for pre and coverage, at most 2 per compaction
TP="$W/many.jsonl"
for i in $(seq 1 80); do
  jq -cn --arg u "m$i" --arg t "Constraint number $i: the service on port $((7000 + i)) must never be restarted by hand." \
    '{type: "user", uuid: $u, promptSource: "typed", message: {role: "user", content: $t}}'
done >"$TP"
summary=$(cat "$FIX/summary.txt")
n0=$(bodies)
jq -cn --arg tp "$TP" '{session_id: "sC", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-pre.sh"
n1=$(bodies)
jq -e '.jev_ok and (.facts | length) == 60' "$JEV_HOME/compact/sC.json" >/dev/null 2>&1 && [ $((n1 - n0)) = 1 ] &&
  jq -e '.questions | length == 61' "$(find "$W/cap" -name 'body-*.json' | sort | tail -n 1)" >/dev/null &&
  ok "compact-pre: 80 candidates -> 60 facts scored in ONE request (61 questions with mid_operation)" || bad "compact-pre: $((n1 - n0)) requests"
jq -cn --arg m "$summary" '{session_id: "sC", hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: $m}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-post.sh"
jq -cn --arg m "$summary" '{session_id: "sC", hook_event_name: "PostCompact", trigger: "auto", compact_summary: $m}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-post.sh"
n2=$(bodies)
jq -e '.coverage.source == "SubagentStop" and all(.facts[]; has("covered"))' "$JEV_HOME/compact/sC.json" >/dev/null 2>&1 && [ $((n2 - n1)) = 1 ] &&
  ok "compact-post: coverage of 60 facts in ONE request; PostCompact on the same summary makes none (2 calls for the compaction)" || bad "compact-post: $((n2 - n1)) requests"
o=$(jq -cn '{session_id: "sC", hook_event_name: "SessionStart", source: "compact"}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-session.sh")
case $(ctxof "$o") in *"Facts preserved across compaction"*"Constraint number 80"*"The full ranked fact list is in $JEV_HOME/compact/sC.json"*) ok "compact-session: uncovered facts injected with the path of the full list" ;; *) bad "compact-session facts: $(ctxof "$o" | head -c 300)" ;; esac
# SubagentStop without a <summary> covers nothing; SessionStart consumes the state; PostCompact then sends nothing
jq -cn --arg tp "$TP" '{session_id: "sD", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-pre.sh"
jq -cn '{session_id: "sD", hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: "no summary tag here"}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-post.sh"
jq -cn '{session_id: "sD", hook_event_name: "SessionStart", source: "compact"}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-session.sh" >/dev/null
n0=$(bodies)
jq -cn --arg m "$summary" '{session_id: "sD", hook_event_name: "PostCompact", trigger: "auto", compact_summary: $m}' | CLAUDE_PROJECT_DIR="$P" "$J/compact-post.sh"
[ "$(bodies)" = "$n0" ] && jq -e '.coverage == null' "$JEV_HOME/compact/sD.json" >/dev/null && tail -n 1 "$JEV_HOME/log/compact.jsonl" | jq -e '.status == "state_consumed"' >/dev/null &&
  ok "compact-post: PostCompact after SessionStart consumed the state -> no Jev call (its answer would never be read)" || bad "compact-post after consumption made a call"
# out of scope: no state, no call; the session hook still injects the free parts
n0=$(bodies)
jq -cn --arg tp "$TP" '{session_id: "sOut", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}' | CLAUDE_PROJECT_DIR="$W" "$J/compact-pre.sh"
[ ! -e "$JEV_HOME/compact/sOut.json" ] && [ "$(bodies)" = "$n0" ] && ok "compact-pre outside a Claudette session: no state file, no Jev call" || bad "compact-pre out of scope"

# --- 7. compact-session.sh without Jev: authored state and artifacts still come back
cat >"$P/.orchestrator.md" <<'EOF'
# Orchestrator log
## 2026-10-18 — live change A
- Status: implementing
## 2026-10-17 — finished change B — DONE
- What: x
## 2026-10-16 — stuck change C
- Status: BLOCKED on review
## 2026-10-15 — change D
| what | PR | outcome |
|---|---|---|
| merged thing | #1 | DONE |
- Status: review round 2
EOF
o=$(jq -cn --arg cwd "$P" '{session_id: "sA", cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}' | env -u TYPESAFE_API_KEY JEV_ZSHENV=/dev/null "$J/compact-session.sh")
ctx=$(ctxof "$o")
case $ctx in *"live change A"*"change D"*) ok "session: live .orchestrator.md sections injected without any Jev call" ;; *) bad "session: live sections missing: $ctx" ;; esac
case $ctx in *"finished change B"* | *"stuck change C"*) bad "session: DONE/BLOCKED section injected" ;; *) ok "session: DONE and BLOCKED sections left out" ;; esac
case $ctx in *"| merged thing"*) bad "session: DONE table row used as a first line" ;; *) ok "session: table rows marked DONE are not used as a section's first line" ;; esac
case $ctx in *"$JEV_HOME/artifacts/sA/review-r1.md"*) ok "session: artifact index injected" ;; *) bad "session: artifact index missing" ;; esac
case $ctx in *"Facts preserved"* | *"ranked fact list"*) bad "session: a fact block without a state file" ;; *) ok "session: no state file -> no fact block" ;; esac
cat >"$W/o2.md" <<'EOF'
# Orchestrator log
## 2026-10-18 — a — DONE
## 2026-10-18 — b — DONE: merged #12
## 2026-10-18 — c (DONE)
## 2026-10-18 — c2 [BLOCKED]
## DONE: d
## 2026-10-18 - e - DONE
## 2026-10-18 – h – DONE
## 2026-10-18 — g — **BLOCKED** on CI
### sub of g
## Make the DONE marker visible
- Status: implementing
## 2026-10-18 — live one
EOF
live=$(awk -f "$J/orchestrator.awk" "$W/o2.md" | cut -f1 | paste -sd'|' -)
[ "$live" = "## Make the DONE marker visible|## 2026-10-18 — live one" ] &&
  ok "orchestrator: em/en dash and hyphen separators, (DONE)/[BLOCKED] and DONE: are finished; a heading that only mentions DONE is live" ||
  bad "orchestrator heading shapes: live = $live"
# size: 200 live sections and 300 scored facts still fit, authored state first
for i in $(seq 1 200); do printf '## 2026-10-%02d — live change number %s with a long descriptive heading\n- Brief: %s\n- Status: implementing\n' $((i % 28 + 1)) "$i" "$(printf 'x%.0s' $(seq 1 150))"; done >"$P/.orchestrator.md"
jq -cn --argjson e "$(date +%s)" '{session_id: "sBig", phase: "pre", jev_ok: true, extracted_epoch: $e,
  facts: [range(1; 301) as $i | {n: $i, kind: "user", text: ("User said: fact number \($i) " + ("y" * 120)), score: 2.5}]}' >"$JEV_HOME/compact/sBig.json"
o=$(jq -cn --arg cwd "$P" '{session_id: "sBig", cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}' | "$J/compact-session.sh")
ctx=$(ctxof "$o")
[ "${#ctx}" -le 9000 ] && [ "${#ctx}" -gt 7000 ] && case $ctx in *"live change number 200"*"fact number"*) true ;; *) false ;; esac &&
  ok "session: 200 sections + 300 facts -> ${#ctx} chars (<= 9000), newest sections kept, facts fill the rest" || bad "session budget: ${#ctx} chars"

# --- 8. daily sweep: old state and what earlier versions kept are removed, once a day
SW="$W/sweep"
mkdir -p "$SW/ledger" "$SW/sessions" "$SW/eval" "$SW/tune" "$SW/compact" "$SW/artifacts/old" "$SW/artifacts/cur" "$SW/artifacts/new" "$SW/log"
touch "$SW/eval/labelled.jsonl" "$SW/compact/new.json" "$SW/.swept-20200101"
touch -t 202001010000 "$SW/artifacts/old" "$SW/artifacts/cur"
cp "$SW/compact/new.json" "$SW/compact/old.json" && touch -t 202001010000 "$SW/compact/old.json"
JEV_HOME="$SW" bash -c '. "$1/lib.sh"; jev_sweep cur' _ "$J"
left=$(cd "$SW" && find . -mindepth 1 -maxdepth 2 ! -name '.swept-*' | sort | paste -sd' ' -)
[ "$left" = "./artifacts ./artifacts/cur ./artifacts/new ./compact ./compact/new.json ./log" ] && [ -e "$SW/.swept-$(date -u +%Y%m%d)" ] && [ ! -e "$SW/.swept-20200101" ] &&
  ok "sweep: v2 ledger/, sessions/, eval/, tune/ and state untouched for 30 days removed; the current session and fresh files kept" || bad "sweep left: $left"
mkdir -p "$SW/eval"
JEV_HOME="$SW" bash -c '. "$1/lib.sh"; jev_sweep' _ "$J"
[ -d "$SW/eval" ] && ok "sweep: runs once a day (stamp file)" || bad "sweep ran twice in a day"

# --- 9. log lines larger than an atomic append, written in parallel, stay whole
big=$(jq -cn '{status: "ok", answers: [range(0; 400) | {q: ., p: 0.123456}]}')
pids=()
for i in $(seq 1 12); do
  (JEV_HOOK="par$i" bash -c '. "$1/lib.sh"; jev_log par.jsonl "$2"' _ "$J" "$big") &
  pids+=($!)
done
wait "${pids[@]}" # not a bare wait: the fake Jev server is a background job too
[ "$(wc -l <"$JEV_HOME/log/par.jsonl" | tr -d ' ')" = 12 ] && jq -e -s 'length == 12' "$JEV_HOME/log/par.jsonl" >/dev/null 2>&1 &&
  ok "jev_log: 12 parallel $(printf '%s' "$big" | wc -c | tr -d ' ')-byte lines all parse" || bad "jev_log: interleaved lines"

echo "offline-hooks: $fails failure(s)"
[ "$fails" -eq 0 ]
