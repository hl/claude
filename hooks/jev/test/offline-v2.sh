#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# offline-v2.sh — v2 behaviour without the real API: the routing policy as
# code, and the ledger, artifacts and injection plumbing against a local fake
# Jev (fake-jev.py: every score "important", every supersession noul 0.1).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID JEV_ROUTE_MODE
W=$(mktemp -d "${TMPDIR:-/tmp}/jev-off2.XXXXXX")
export JEV_HOME="$W/home"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

# --- 1. policy.jq (pure jq, no API)
pol() { # <input-json> -> route_policy output with the default thresholds
  jq -c -n -L "$J" --argjson in "$1" 'include "policy"; $in | route_policy({})'
}
expect() { # <label> <input> <jq-condition>
  local o
  o=$(pol "$2")
  jq -e "$3" <<<"$o" >/dev/null 2>&1 && ok "policy: $1" || bad "policy: $1 -> $o"
}
easy='{"probabilities":{"haiku":0.95,"sonnet":0.05,"opus":0},"confidence":0.9,"signals":{"mechanical":0.9,"ambiguous":0.2,"needs_research":0.1,"security_or_high_blast_radius":0.05,"review_of_nontrivial_diff":0.02,"nontrivial_change":0.05}}'
mid='{"probabilities":{"haiku":0.02,"sonnet":0.9,"opus":0.08},"confidence":0.85,"signals":{"mechanical":0.3,"ambiguous":0.4,"needs_research":0.4,"security_or_high_blast_radius":0.2,"review_of_nontrivial_diff":0.05,"nontrivial_change":0.4}}'
expect "clear haiku task -> haiku, reviewer sonnet, no deepen" "$easy" '.model == "haiku" and .reviewer_model == "sonnet" and .deepen == false'
expect "haiku task of kind investigate -> at least sonnet" "$(jq -c '.ctx = {kind: "investigate"}' <<<"$easy")" '.model == "sonnet" and any(.policy[]; test("kind investigate"))'
expect "routine task -> sonnet" "$mid" '.model == "sonnet"'
expect "P(opus) 0.45 -> opus" "$(jq -c '.probabilities = {haiku: 0, sonnet: 0.55, opus: 0.45}' <<<"$mid")" '.model == "opus" and (.policy[0] | test("P\\(opus\\) 0.45"))'
expect "security signal 0.8 -> opus, reviewer opus" "$(jq -c '.signals.security_or_high_blast_radius = 0.8' <<<"$mid")" '.model == "opus" and .reviewer_model == "opus"'
expect "retry (attempt 2 after sonnet) -> opus" "$(jq -c '.ctx = {attempt: 2, prior_model: "sonnet", prior_outcome: "thin"}' <<<"$mid")" '.model == "opus" and any(.policy[]; test("retry"))'
expect "retry after haiku -> sonnet at least" "$(jq -c '.ctx = {attempt: 2, prior_model: "haiku"}' <<<"$easy")" '.model == "sonnet"'
expect "prior_outcome \"review FAIL x2\" without attempt counts as a retry" "$(jq -c '.ctx = {prior_outcome: "review FAIL x2", prior_model: "sonnet"}' <<<"$mid")" '.model == "opus"'
expect "risky path on an implement task -> opus" "$(jq -c '.ctx = {kind: "implement", risky_paths: ["priv/repo/migrations/1_add.exs"]}' <<<"$mid")" '.model == "opus" and any(.policy[]; test("high-blast-radius"))'
expect "risky path on a poll task -> no bump" "$(jq -c '.ctx = {kind: "poll", risky_paths: [".github/workflows/ci.yml"]}' <<<"$easy")" '.model == "haiku"'
expect "6 files rule out haiku" "$(jq -c '.ctx = {files: 6}' <<<"$easy")" '.model == "sonnet"'
expect "12 files mean opus" "$(jq -c '.ctx = {files: 12}' <<<"$mid")" '.model == "opus"'
expect "non-trivial change -> reviewer opus over a sonnet implementer" "$(jq -c '.signals.nontrivial_change = 0.7' <<<"$mid")" '.model == "sonnet" and .reviewer_model == "opus"'
expect "ambiguous 0.7 -> deepen" "$(jq -c '.signals.ambiguous = 0.7' <<<"$mid")" '.deepen == true'
expect "above: how sure a cheaper tier falls short" "$mid" '.above.haiku >= 0.7 and .above.sonnet <= 0.2'

# --- fake Jev for everything below
port=$((20000 + RANDOM % 20000))
FAKE_JEV_FULLY='Change of plan' FAKE_JEV_LOW='Pin the base image to debian' python3 -I "$HERE/fake-jev.py" "$port" "$W/cap" >"$W/fake.out" 2>&1 &
fpid=$!
trap 'kill $fpid 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q ready "$W/fake.out" 2>/dev/null && break; sleep 0.1; done
export TYPESAFE_BASE_URL="http://127.0.0.1:$port" TYPESAFE_API_KEY=apikFAKEOFFLINE

# --- 2. route.sh plumbing
"$J/route.sh" --context 'not json' "x" >/dev/null 2>&1
[ $? -eq 2 ] && ok "route.sh: bad --context exits 2" || bad "route.sh: bad --context"
o=$("$J/route.sh" --context '{"kind":"implement","paths":["lib/app/auth/session.ex","README.md"],"files_hint":["a.ex","b.ex"]}' "Add a field.")
jq -e '(.id | test("^r[0-9]+-")) and .model == "opus" and (.policy | type == "array") and has("reviewer_model") and has("deepen")' <<<"$o" >/dev/null &&
  ok "route.sh: id, policy array, reviewer_model, deepen; auth path -> opus" || bad "route.sh output: $o"
tail -n 1 "$JEV_HOME/log/route.jsonl" | jq -e --arg id "$(jq -r .id <<<"$o")" '.action == "route" and .id == $id and .context.files == 2 and .context.risky_paths == ["lib/app/auth/session.ex"] and (has("task") | not)' >/dev/null &&
  ok "route.sh: logged with id and normalised context, no task text" || bad "route.sh log: $(tail -n 1 "$JEV_HOME/log/route.jsonl")"
jq -e '.state.context.kind == "implement" and (.state.context | has("risky_paths") | not)' "$(find "$W/cap" -name 'body-*.json' | sort | tail -n 1)" >/dev/null &&
  ok "route.sh: Jev state carries {task, context}" || bad "route.sh: context not in the Jev state"

# --- 3. outcome.sh and tune.sh's use of it
id=$(jq -r .id <<<"$o")
"$J/outcome.sh" "$id" '{"rounds":2,"escalated":true,"verdict":"PASS","final_model":"opus"}' >/dev/null &&
  tail -n 1 "$JEV_HOME/log/route.jsonl" | jq -e --arg id "$id" '.action == "outcome" and .id == $id and .escalated == true' >/dev/null &&
  ok "outcome.sh: appended to route.jsonl by id" || bad "outcome.sh"
"$J/outcome.sh" "$id" 'nope' >/dev/null 2>&1
[ $? -eq 2 ] && ok "outcome.sh: bad JSON exits 2" || bad "outcome.sh bad JSON"
jq -c '{id: "x1", label: "opus", model: "opus"} + .' <<<"$o" >"$W/res.jsonl"
tout=$(JEV_TUNE_ROUTE_LOG="$JEV_HOME/log/route.jsonl" "$HERE/tune.sh" "$W/res.jsonl" 2>/dev/null)
grep -q '1 eval rows over 1 tasks (from res.jsonl), 1 outcome' <<<"$tout" &&
  ok "tune.sh: reads outcome.sh records as labels" || bad "tune.sh did not read outcomes"

# --- 4. ledger.sh: cursor, idempotence, partial lines, lock, add, failure
S="off-ledger"
TP="$W/t.jsonl"
cp "$FIX/transcript.jsonl" "$TP"
stop() { jq -cn --arg s "${2:-$S}" --arg tp "$TP" '{session_id: $s, transcript_path: $tp, hook_event_name: "Stop", stop_hook_active: false}' | env "${@:3}" "$J/ledger.sh" ${1:+"$1"}; }
L="$JEV_HOME/ledger/$S.jsonl"
M="$JEV_HOME/ledger/$S.meta.json"
stop ""
size=$(wc -c <"$TP" | tr -d ' ')
jq -e -s 'length >= 8' "$L" >/dev/null && jq -e --argjson s "$size" '.offset == $s and .last_uuid == "u10" and .next_id > 8' "$M" >/dev/null &&
  ok "ledger: first run starts at the compact boundary, appends $(wc -l <"$L" | tr -d ' ') facts, cursor at end ($size bytes, last uuid u10)" || bad "ledger first run: $(cat "$M")"
grep -q 'pre-boundary\|pull/1111' "$L" && bad "ledger: took facts from before the boundary" || ok "ledger: nothing from before the compact boundary"
jq -e -s 'all(.[]; has("id") and has("ts") and has("kind") and has("text") and has("score") and has("supersedes") and has("source_uuid"))' "$L" >/dev/null &&
  ok "ledger: facts carry {id, ts, kind, text, score, supersedes, source_uuid}" || bad "ledger fact shape"
c1=$(cksum <"$L")
nb=$(find "$W/cap" -name 'body-*' | wc -l)
stop ""
[ "$(cksum <"$L")" = "$c1" ] && [ "$(find "$W/cap" -name 'body-*' | wc -l)" = "$nb" ] && ok "ledger: re-run is a no-op (no API call, ledger unchanged)" || bad "ledger re-run changed something"
# a half-written line is left for the next run
printf '%s' '{"type":"user","uuid":"p1","promptSource":"typed","message":{"role":"user","content":"The deploy window is Tuesday 14:00 UTC only."}' >>"$TP"
stop ""
jq -e --argjson s "$size" '.offset == $s' "$M" >/dev/null && ! grep -q 'deploy window' "$L" && ok "ledger: a partial last line is not consumed" || bad "ledger consumed a partial line"
printf '}\n' >>"$TP"
stop ""
grep -q 'deploy window' "$L" && jq -e '.last_uuid == "p1"' "$M" >/dev/null && ok "ledger: completed line processed on the next run" || bad "ledger missed the completed line"
# lock held by a live step: skip fast; stale lock: broken
mkdir -p "$JEV_HOME/ledger/$S.lock" && date +%s >"$JEV_HOME/ledger/$S.lock/at"
printf '%s\n' '{"type":"user","uuid":"p2","promptSource":"typed","message":{"role":"user","content":"Release freeze starts Friday."}}' >>"$TP"
stop ""
tail -n 1 "$JEV_HOME/log/ledger.jsonl" | jq -e '.status == "locked"' >/dev/null && ! grep -q 'Release freeze' "$L" && ok "ledger: Stop while a step holds the lock is skipped" || bad "ledger lock not honoured"
echo 1 >"$JEV_HOME/ledger/$S.lock/at"
stop ""
grep -q 'Release freeze' "$L" && ok "ledger: a stale lock (older than 60 s) is broken" || bad "ledger stale lock kept"
# Jev down: cursor stays, next run catches up
printf '%s\n' '{"type":"user","uuid":"p3","promptSource":"typed","message":{"role":"user","content":"Use the eu-west region for the new bucket."}}' >>"$TP"
off=$(jq .offset "$M")
stop "" "$S" TYPESAFE_BASE_URL=http://127.0.0.1:9 JEV_COOLDOWN=0
[ "$(jq .offset "$M")" = "$off" ] && tail -n 1 "$JEV_HOME/log/ledger.jsonl" | jq -e '.status == "jev_failed"' >/dev/null && ok "ledger: Jev down -> cursor does not move" || bad "ledger moved the cursor on failure"
rm -f "$JEV_HOME/cooldown.compact" # the refused connection started a cooldown
stop ""
grep -q 'eu-west' "$L" && ok "ledger: next run with Jev back catches up" || bad "ledger did not catch up"
# --add
before=$(wc -l <"$L")
"$J/ledger.sh" --add "$S" artifact 2.5 "Artifact x: /tmp/x.md" "" >/dev/null
[ $(($(wc -l <"$L") - before)) -eq 1 ] && tail -n 1 "$L" | jq -e --argjson n "$(($(jq .next_id "$M") - 1))" '.kind == "artifact" and .id == "f\($n)"' >/dev/null &&
  ok "ledger --add: appended with the next id" || bad "ledger --add"
# subagent / teammate stops keep no ledger
jq -cn --arg tp "$TP" '{session_id: "sub-x", agent_id: "a1", transcript_path: $tp, hook_event_name: "Stop"}' | "$J/ledger.sh"
[ ! -e "$JEV_HOME/ledger/sub-x.jsonl" ] && ok "ledger: payload with agent_id is skipped" || bad "ledger ran for an agent_id payload"
JEV_LEDGER=0 stop "" off-disabled
[ ! -e "$JEV_HOME/ledger/off-disabled.jsonl" ] && ok "ledger: JEV_LEDGER=0 does nothing" || bad "JEV_LEDGER=0 ignored"

# A -> B -> A: the third turn restates A word for word; A must be live again
# (dedupe is against live facts only) and B superseded by it. The fake Jev
# answers "fully" for any correction question that involves B.
S2="off-aba"
TP2="$W/aba.jsonl"
: >"$TP2"
turn() { # <uuid> <text>
  jq -cn --arg u "$1" --arg t "$2" '{type: "user", uuid: $u, promptSource: "typed", message: {role: "user", content: $t}}' >>"$TP2"
  jq -cn --arg tp "$TP2" --arg s "$S2" '{session_id: $s, transcript_path: $tp, hook_event_name: "Stop"}' | "$J/ledger.sh"
}
turn a1 "Use advisory locks for the job queue."
turn b1 "Change of plan: use a unique index on jobs instead of advisory locks."
turn a2 "Use advisory locks for the job queue."
L2="$JEV_HOME/ledger/$S2.jsonl"
jq -e -s '[.[] | select(.text == "User said: Use advisory locks for the job queue.")] as $a
  | ($a | length) == 2 and ($a[0].superseded_by != null) and ($a[1].superseded_by == null)
  and any(.[]; (.text | test("Change of plan")) and .superseded_by == $a[1].id)' "$L2" >/dev/null &&
  ok "ledger: A, B, A again -> the restated A is live and supersedes B" || bad "ledger A-B-A: $(jq -c '{id, superseded_by, t: .text[0:40]}' "$L2" | paste -sd' ' -)"
# Restoration does not depend on Jev: A (superseded by B) is said again, Jev scores
# it irrelevant and does not call it a correction, yet it is kept at A's score and
# B is retired.
S4="off-restore"
L4="$JEV_HOME/ledger/$S4.jsonl"
TP4="$W/restore.jsonl"
mkdir -p "$JEV_HOME/ledger"
jq -cn '{id: "f1", ts: "2026-10-18T10:00:00Z", kind: "user", text: "User said: Pin the base image to debian bookworm.", score: 2.6, supersedes: [], corrects: [], superseded_by: "f2", corrected_by: [], source_uuid: "r1"},
  {id: "f2", ts: "2026-10-18T10:01:00Z", kind: "user", text: "User said: Use alpine for the base image.", score: 2.4, supersedes: ["f1"], corrects: [], superseded_by: null, corrected_by: [], source_uuid: "r2"}' >"$L4"
jq -cn '{type: "user", uuid: "r1", promptSource: "typed", message: {role: "user", content: "Pin the base image to debian bookworm."}},
  {type: "user", uuid: "r2", promptSource: "typed", message: {role: "user", content: "Use alpine for the base image."}}' >"$TP4"
jq -cn --argjson o "$(wc -c <"$TP4" | tr -d ' ')" '{offset: $o, last_uuid: "r2", next_id: 3}' >"$JEV_HOME/ledger/$S4.meta.json"
jq -cn '{type: "user", uuid: "r3", promptSource: "typed", message: {role: "user", content: "Pin the base image to debian bookworm."}}' >>"$TP4"
jq -cn --arg tp "$TP4" --arg s "$S4" '{session_id: $s, transcript_path: $tp, hook_event_name: "Stop"}' | "$J/ledger.sh"
jq -e -s 'any(.[]; .id == "f3" and .restores == "f1" and .superseded_by == null and .score == 2.6)
  and any(.[]; .id == "f2" and .superseded_by == "f3")' "$L4" >/dev/null &&
  ok "ledger: a superseded statement said again is kept at its old score (Jev scored it 0) and retires what replaced it" ||
  bad "ledger restore: $(jq -c '{id, score, superseded_by, restores}' "$L4" | paste -sd' ' -)"

# open items: the same item as a user line, an "Open item:" line and a checkbox -> one fact
S3="off-todo"
TP3="$W/todo.jsonl"
jq -cn '{type: "user", uuid: "t1", promptSource: "typed", message: {role: "user", content: "Open item: backfill the consumer offsets before enabling the flag."}},
  {type: "assistant", uuid: "t2", message: {role: "assistant", content: [{type: "text", text: "- [ ] backfill the consumer offsets before enabling the flag"}]}}' >"$TP3"
jq -cn --arg tp "$TP3" --arg s "$S3" '{session_id: $s, transcript_path: $tp, hook_event_name: "Stop"}' | "$J/ledger.sh"
[ "$(jq -s '[.[] | select(.text | test("backfill the consumer offsets"))] | length' "$JEV_HOME/ledger/$S3.jsonl")" = 1 ] &&
  ok "ledger: one open item stated three ways is stored once" || bad "ledger todo dedupe: $(jq -c '.text' "$JEV_HOME/ledger/$S3.jsonl" | paste -sd' ' -)"
# housekeeping: a superseded fact older than 7 days moves to the archive
jq -c 'if .superseded_by != null then .ts = "2020-01-01T00:00:00Z" else . end' "$L2" >"$L2.t" && mv "$L2.t" "$L2"
turn a3 "Also: the queue table is jobs_v2."
jq -e -s 'all(.[]; .superseded_by == null)' "$L2" >/dev/null && [ -s "$JEV_HOME/ledger/$S2.archive.jsonl" ] &&
  ok "ledger: superseded facts older than 7 days move to <session>.archive.jsonl" || bad "ledger archive"

# --- 5. artifact.sh
P="$W/proj"
mkdir -p "$P"
p=$(cd "$P" && printf '# Findings\nall good\n' | CLAUDE_CODE_SESSION_ID=sA "$J/artifact.sh" "review r1")
[ "$p" = "$JEV_HOME/artifacts/sA/review-r1.md" ] && [ -f "$p" ] && ok "artifact.sh: session from \$CLAUDE_CODE_SESSION_ID, name sanitised -> review-r1.md" || bad "artifact.sh path: $p"
jq -e -s 'any(.[]; .kind == "artifact" and (.text | test("review-r1.md — Findings")))' "$JEV_HOME/ledger/sA.jsonl" >/dev/null && ok "artifact.sh: indexed in the ledger with its title" || bad "artifact not in ledger"
printf 'round two\n' | CLAUDE_CODE_SESSION_ID=sA "$J/artifact.sh" "review r1" >/dev/null
jq -e -s '[.[] | select(.kind == "artifact" and (.text | test("review-r1.md")))] | length == 2 and (.[0].superseded_by == .[1].id) and .[1].superseded_by == null' "$JEV_HOME/ledger/sA.jsonl" >/dev/null &&
  ok "artifact.sh: saving the same name again supersedes the old index fact" || bad "artifact re-save"
jq -cn --arg tp "$TP" --arg cwd "$P" '{session_id: "sP", transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop"}' | CLAUDE_PID=4242 "$J/ledger.sh"
p=$(printf 'x\n' | CLAUDE_PID=4242 "$J/artifact.sh" notes)
[ "$p" = "$JEV_HOME/artifacts/sP/notes.md" ] && ok "artifact.sh: falls back to the CLAUDE_PID pointer the Stop hook wrote" || bad "pid pointer: $p"
p=$(cd "$P" && printf 'x\n' | "$J/artifact.sh" notes2)
[ "$p" = "$JEV_HOME/artifacts/sP/notes2.md" ] && ok "artifact.sh: falls back to the per-directory pointer" || bad "cwd pointer: $p"
(cd "$W" && printf 'x\n' | "$J/artifact.sh" nothing >/dev/null 2>&1)
[ $? -eq 2 ] && ok "artifact.sh: no session id anywhere -> exit 2" || bad "artifact.sh without session"
p=$(printf 'x\n' | "$J/artifact.sh" "../../etc/evil name" --session sA)
[ "$p" = "$JEV_HOME/artifacts/sA/etc-evil-name.md" ] && ok "artifact.sh: path characters stripped from names" || bad "name sanitising: $p"

# --- 6. artifact-hook.sh (PostToolUse Agent + SubagentStop)
long=$(printf 'Finding line %s with enough words to make the result long.\n' $(seq 1 60))
post() { jq -cn --arg t "$1" --arg a "$2" --arg st "${3:-completed}" '{session_id: "sH", hook_event_name: "PostToolUse", tool_name: "Agent", tool_use_id: ("toolu_" + $a),
  tool_input: {description: "Review the auth plug", subagent_type: "general-purpose", model: "opus"},
  tool_response: {status: $st, agentId: $a, resolvedModel: "claude-opus-5-5", content: [{type: "text", text: $t}]}}' | "$J/artifact-hook.sh"; }
o=$(post "$long" ag1)
f=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$o" | sed 's/^Subagent result (Review the auth plug) saved to //')
jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$o" >/dev/null && [ -f "$f" ] && grep -q 'Finding line 60' "$f" && case $f in */artifacts/sH/agent-1-review-the-auth-plug-ag1.md) true ;; *) false ;; esac &&
  ok "artifact-hook: long foreground result saved as agent-1-review-the-auth-plug-ag1.md, parent told the path" || bad "artifact-hook PostToolUse: $o"
[ -z "$(post "short answer" ag2)" ] && ok "artifact-hook: short result -> nothing" || bad "artifact-hook short"
o=$(jq -cn '{session_id: "sH", hook_event_name: "PostToolUse", tool_name: "Agent", tool_input: {description: "bg"},
  tool_response: "{\"isAsync\":true,\"status\":\"async_launched\",\"agentId\":\"ag3\"}"}' | "$J/artifact-hook.sh")
[ -z "$o" ] && ok "artifact-hook: background launch (async_launched, string tool_response) -> nothing" || bad "artifact-hook async: $o"
jq -cn --arg t "$long" '{session_id: "sH", hook_event_name: "SubagentStop", agent_id: "ag4", agent_type: "general-purpose", last_assistant_message: $t,
  background_tasks: [{id: "ag4", description: "Survey retry logic", agent_type: "general-purpose", status: "running"}]}' | "$J/artifact-hook.sh"
f4=$(find "$JEV_HOME/artifacts/sH" -name 'agent-*-survey-retry-logic-ag4.md')
[ -n "$f4" ] && ok "artifact-hook: background agent saved on SubagentStop ($(basename "$f4"))" || bad "artifact-hook SubagentStop"
o=$(post "$long" ag4)
[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$o")" = "Subagent result (Review the auth plug) saved to $f4" ] && [ "$(find "$JEV_HOME/artifacts/sH" -name 'agent-*.md' | wc -l | tr -d ' ')" = 2 ] &&
  ok "artifact-hook: SubagentStop then PostToolUse for the same agent -> one file, same path" || bad "artifact-hook dedupe: $o"
jq -cn --arg t "<summary>$long</summary>" '{session_id: "sH", hook_event_name: "SubagentStop", agent_id: "acmp", agent_type: "", last_assistant_message: $t}' | "$J/artifact-hook.sh"
[ "$(find "$JEV_HOME/artifacts/sH" -name 'agent-*.md' | wc -l | tr -d ' ')" = 2 ] && ok "artifact-hook: the compaction agent (empty agent_type) is skipped" || bad "artifact-hook saved the compaction summary"
jq -cn --arg t "$long" '{session_id: "sH", hook_event_name: "SubagentStop", agent_id: "ag5", agent_type: "general-purpose", last_assistant_message: $t, background_tasks: []}' | "$J/artifact-hook.sh"
[ "$(find "$JEV_HOME/artifacts/sH" -name 'agent-*.md' | wc -l | tr -d ' ')" = 2 ] && ok "artifact-hook: a foreground agent's SubagentStop is left to its PostToolUse" || bad "artifact-hook saved a foreground agent on SubagentStop"

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
  p=$(jq -r '.hookSpecificOutput.additionalContext // empty' "$W/ctx-$a.json" | sed 's/^Subagent result (Review the auth plug) saved to //')
  [ -f "$p" ] && grep -q "RESULT-OF-$a " "$p" && good=$((good + 1))
done; done
[ "$good" = 6 ] && [ "$(find "$JEV_HOME/artifacts/sH" -name 'agent-*-par*.md' | wc -l | tr -d ' ')" = 6 ] &&
  ok "artifact-hook: 3 x 2 same-description agents finishing together -> 6 files, each parent pointed at its own result" ||
  bad "artifact-hook concurrency: $good of 6 correct, $(find "$JEV_HOME/artifacts/sH" -name 'agent-*-par*.md' | wc -l | tr -d ' ') files"
# the model that ran is logged for every Agent call, joined by tool_use_id
jq -e -s '[.[] | select(.action == "ran")] | length >= 8 and all(.[]; .resolved_model == "claude-opus-5-5" or .status == "async_launched")
  and any(.[]; .tool_use_id == "toolu_ag1" and .agent_id == "ag1")' "$JEV_HOME/log/route.jsonl" >/dev/null &&
  ok "artifact-hook: every PostToolUse(Agent) logs action ran with resolved_model and tool_use_id to route.jsonl" || bad "ran records missing"
# per-artifact cap
big=$(head -c 700000 /dev/zero | tr '\0' 'x')
post "$big" agbig >/dev/null
fb=$(find "$JEV_HOME/artifacts/sH" -name 'agent-*-agbig.md')
[ -n "$fb" ] && [ "$(wc -c <"$fb" | tr -d ' ')" -lt 530000 ] && tail -n 1 "$fb" | grep -q 'truncated by the Jev artifact hook' &&
  ok "artifact-hook: a 700 KB result is cut to 512 KB with a note" || bad "artifact cap"

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
ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$o")
case $ctx in *"live change A"*"change D"*) ok "session: live .orchestrator.md sections injected without any Jev call" ;; *) bad "session: live sections missing: $ctx" ;; esac
case $ctx in *"finished change B"* | *"stuck change C"*) bad "session: DONE/BLOCKED section injected" ;; *) ok "session: DONE and BLOCKED sections left out" ;; esac
case $ctx in *"| merged thing"*) bad "session: DONE table row used as a first line" ;; *) ok "session: table rows marked DONE are not used as a section's first line" ;; esac
case $ctx in *"$JEV_HOME/artifacts/sA/review-r1.md"*) ok "session: artifact index injected" ;; *) bad "session: artifact index missing" ;; esac
# size: 200 live sections and a long ledger still fit, authored state first
for i in $(seq 1 200); do printf '## 2026-10-%02d — live change number %s with a long descriptive heading\n- Brief: %s\n- Status: implementing\n' $((i % 28 + 1)) "$i" "$(printf 'x%.0s' $(seq 1 150))"; done >"$P/.orchestrator.md"
for i in $(seq 1 300); do jq -cn --argjson i "$i" '{id: "f\($i)", kind: "user", text: ("User said: fact number \($i) " + ("y" * 120)), score: 2.5, supersedes: [], superseded_by: null}'; done >"$JEV_HOME/ledger/sBig.jsonl"
o=$(jq -cn --arg cwd "$P" '{session_id: "sBig", cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}' | "$J/compact-session.sh")
ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$o")
[ "${#ctx}" -le 9000 ] && [ "${#ctx}" -gt 7000 ] && case $ctx in *"live change number 200"*"fact number"*) true ;; *) false ;; esac &&
  ok "session: 200 sections + 300 facts -> ${#ctx} chars (<= 9000), newest sections kept, facts fill the rest" || bad "session budget: ${#ctx} chars"

# --- 7b. the mkdir lock
lk="$W/lk"
lockt() { bash -c '. "$1/lib.sh"; jev_lock "$2" 60' _ "$J" "$lk"; }
mkdir "$lk" # a holder between mkdir and writing `at`
lockt && bad "lock: a fresh lock without its at file was broken" || ok "lock: a fresh lock without its at file is respected (judged by the directory's mtime)"
touch -t 202001010000 "$lk"
lockt && ok "lock: an old lock without its at file is broken" || bad "lock: old lock without at kept"
rm -rf "$lk"; mkdir "$lk"; printf '%s %s\n' "$(date +%s)" 999999 >"$lk/at" # holder pid gone
lockt && ok "lock: a lock whose holder process is gone is broken at once" || bad "lock: dead holder kept"
rm -rf "$lk"; mkdir "$lk"; printf '%s %s\n' "$(date +%s)" "$$" >"$lk/at" # holder alive
lockt && bad "lock: a live holder's lock was broken" || ok "lock: a live holder's fresh lock is respected"
rm -rf "$lk"

# --- 8. log lines larger than an atomic append, written in parallel, stay whole
big=$(jq -cn '{status: "ok", answers: [range(0; 400) | {q: ., p: 0.123456}]}')
pids=()
for i in $(seq 1 12); do
  (JEV_HOOK="par$i" bash -c '. "$1/lib.sh"; jev_log par.jsonl "$2"' _ "$J" "$big") &
  pids+=($!)
done
wait "${pids[@]}" # not a bare wait: the fake Jev server is a background job too
[ "$(wc -l <"$JEV_HOME/log/par.jsonl" | tr -d ' ')" = 12 ] && jq -e -s 'length == 12' "$JEV_HOME/log/par.jsonl" >/dev/null 2>&1 &&
  ok "jev_log: 12 parallel $(printf '%s' "$big" | wc -c | tr -d ' ')-byte lines all parse" || bad "jev_log: interleaved lines"

echo "offline-v2: $fails failure(s)"
[ "$fails" -eq 0 ]
