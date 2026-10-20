#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# compact-fixture.sh — end-to-end compaction test on a synthetic transcript
# (needs a Jev key; hits the live API).
#
# fixtures/transcript.jsonl plants facts after a compact boundary (and decoys
# before it); fixtures/summary.txt is a fake summary that omits three of them:
#   the migrations constraint, the staging database, the backfill TODO.
# Asserts, for both hook orders and for the no-coverage fallback:
#   - the 3 omitted facts appear in additionalContext
#   - at least 2 covered facts do not
#   - additionalContext < 9000 chars; output is valid SessionStart JSON
#   - pre-boundary decoys are never extracted; a second SessionStart without a
#     new PreCompact falls back to ranking the ledger and leaves the state consumed
set -uo pipefail
export JEV_MIGRATE=0 # tests never move this machine's real ~/.claude/jev
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J="$HERE/.."
FIX="$HERE/fixtures"
# Isolate from the session running the tests (its .orchestrator.md, its artifacts).
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID
JEV_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jev-cf.XXXXXX")
export JEV_HOME
cp "$FIX/transcript.jsonl" "$JEV_HOME/transcript.jsonl"
TP="$JEV_HOME/transcript.jsonl"
SUMMARY=$(cat "$FIX/summary.txt")
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

omitted=("priv/repo/migrations" "pg-staging-3" "backfill the consumer group offsets")
covered=("Redis Streams" "pull/2417" "Branch used this session: feat/event-fanout-streams" "async tests" "Elixir 1.18" "fanout_streams_enabled")

pre() { jq -cn --arg s "$1" --arg tp "$TP" '{session_id: $s, transcript_path: $tp, cwd: "/work/platform", hook_event_name: "PreCompact", trigger: "manual", custom_instructions: null}' | "$J/compact-pre.sh"; }
substop() { jq -cn --arg s "$1" --arg tp "$TP" --arg m "$SUMMARY" '{session_id: $s, transcript_path: $tp, hook_event_name: "SubagentStop", agent_id: "acompact", agent_type: "", stop_hook_active: false, last_assistant_message: $m}' | "$J/compact-post.sh"; }
postc() { jq -cn --arg s "$1" --arg tp "$TP" --arg m "$SUMMARY" '{session_id: $s, transcript_path: $tp, hook_event_name: "PostCompact", trigger: "manual", compact_summary: $m}' | "$J/compact-post.sh"; }
sess() { jq -cn --arg s "$1" --arg tp "$TP" '{session_id: $s, transcript_path: $tp, hook_event_name: "SessionStart", source: "compact", model: "claude-sonnet-5-5"}' | "$J/compact-session.sh"; }

check_ctx() { # <label> <hook-stdout> <expect-coverage:true|false>
  local label=$1 out=$2 ctx n_abs=0 s
  if ! ctx=$(jq -er '.hookSpecificOutput | select(.hookEventName == "SessionStart") | .additionalContext' <<<"$out" 2>/dev/null); then
    bad "$label: no valid SessionStart additionalContext (got: ${out:0:200})"
    return
  fi
  [ "${#ctx}" -lt 9000 ] && ok "$label: additionalContext is ${#ctx} chars (< 9000)" || bad "$label: ${#ctx} chars"
  for s in "${omitted[@]}"; do
    case $ctx in *"$s"*) ok "$label: omitted fact present: $s" ;; *) bad "$label: omitted fact missing: $s" ;; esac
  done
  if [ "$3" = true ]; then
    for s in "${covered[@]}"; do case $ctx in *"$s"*) ;; *) n_abs=$((n_abs + 1)) ;; esac; done
    [ "$n_abs" -ge 2 ] && ok "$label: $n_abs of ${#covered[@]} covered facts left out (>= 2)" || bad "$label: only $n_abs covered facts left out"
  fi
  printf '%s\n' "$ctx" >"$JEV_HOME/$label.context.txt"
}

# --- order observed on 2.1.302: PreCompact, SubagentStop(compaction agent), SessionStart(compact), PostCompact
S=fixture-a
o=$(pre $S); rc=$?
[ $rc -eq 0 ] && [ -z "$o" ] && ok "pre: exit 0, no stdout" || bad "pre: rc=$rc out=$o"
st="$JEV_HOME/compact/$S.json"
if jq -e '.jev_ok and (.facts | length) >= 8 and all(.facts[]; .score != null)' "$st" >/dev/null 2>&1; then
  ok "pre: state file has $(jq '.facts | length' "$st") scored facts (work_type=$(jq -r .work_type "$st"), mid_operation=$(jq -r .mid_operation "$st"))"
else bad "pre: state file missing or unscored"; fi
if jq -e '[.facts[].text] | any(test("pre-boundary|pull/1111|secret thoughts")) | not' "$st" >/dev/null 2>&1; then
  ok "pre: nothing extracted from before the compact boundary or from thinking blocks"
else bad "pre: extracted pre-boundary or thinking content"; fi
o=$(substop $S)
[ -z "$o" ] && jq -e '.coverage.source == "SubagentStop" and all(.facts[]; has("covered"))' "$st" >/dev/null 2>&1 &&
  ok "SubagentStop(compaction agent): coverage recorded (summary_quality=$(jq -r .coverage.summary_quality "$st"))" ||
  bad "SubagentStop: coverage not recorded"
o=$(sess $S)
check_ctx observed-order "$o" true
o=$(postc $S)
[ -z "$o" ] && tail -n 1 "$JEV_HOME/log/compact.jsonl" | jq -e '.status == "already_covered"' >/dev/null &&
  ok "PostCompact after SessionStart: same summary, no second Jev call" || bad "PostCompact dedup failed"
o=$(sess $S)
tail -n 1 "$JEV_HOME/log/compact.jsonl" | jq -e '.mode == "ledger-ranking"' >/dev/null && jq -e '.consumed_at != null' "$st" >/dev/null &&
  ok "second SessionStart(compact) without a new PreCompact: ranks the live ledger facts, state stays consumed" || bad "second SessionStart: $(tail -n 1 "$JEV_HOME/log/compact.jsonl")"

# --- the other order: PostCompact before SessionStart, no SubagentStop pass
S=fixture-b
pre $S >/dev/null
postc $S >/dev/null
jq -e '.coverage.source == "PostCompact"' "$JEV_HOME/compact/$S.json" >/dev/null 2>&1 &&
  ok "PostCompact-first: coverage recorded" || bad "PostCompact-first: no coverage"
check_ctx post-first "$(sess $S)" true

# --- v1 mode (JEV_LEDGER=0): extraction at PreCompact, no ledger
S=fixture-v1
JEV_LEDGER=0 pre $S >/dev/null
jq -e '.mode == "v1" and .jev_ok' "$JEV_HOME/compact/$S.json" >/dev/null 2>&1 && [ ! -e "$JEV_HOME/ledger/$S.jsonl" ] &&
  ok "JEV_LEDGER=0: v1 extraction path, no ledger written" || bad "JEV_LEDGER=0 did not take the v1 path"
substop $S >/dev/null
check_ctx v1-mode "$(sess $S)" true

# --- no coverage at all: ranking fallback
S=fixture-c
pre $S >/dev/null
o=$(sess $S)
check_ctx ranking-only "$o" false

# --- a non-compaction SubagentStop must not touch the state
S=fixture-d
pre $S >/dev/null
jq -cn --arg s $S --arg m "$SUMMARY" '{session_id: $s, hook_event_name: "SubagentStop", agent_type: "general-purpose", last_assistant_message: $m}' | "$J/compact-post.sh"
jq -e '.coverage == null' "$JEV_HOME/compact/$S.json" >/dev/null && ok "ordinary subagent stop ignored" || bad "ordinary subagent stop wrote coverage"

# --- background context the latest steps don't use (regression from a live run:
# a user-stated host/ticket ranked below threshold once the work moved on)
S=fixture-bg
cp "$FIX/transcript-background.jsonl" "$JEV_HOME/bg.jsonl"
jq -cn --arg s $S --arg tp "$JEV_HOME/bg.jsonl" '{session_id: $s, transcript_path: $tp, hook_event_name: "PreCompact", trigger: "manual"}' | "$J/compact-pre.sh"
jq -cn --arg s $S --arg m "$(cat "$FIX/summary-background.txt")" '{session_id: $s, hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: $m}' | "$J/compact-post.sh"
o=$(sess $S)
ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$o" 2>/dev/null)
case $ctx in *pg-staging-7*OPS-4821* | *OPS-4821*pg-staging-7*) ok "background: user-stated host and ticket re-injected after a summary that dropped them" ;; *) bad "background: host/ticket not injected (scores: $(jq -c '[.facts[] | {n, score}]' "$JEV_HOME/compact/$S.json"))" ;; esac
case $ctx in *notes.txt* | *nonexistent-jev-dir*) bad "background: finished one-off steps injected" ;; *) ok "background: finished one-off steps left out" ;; esac

# --- injected facts are listed in transcript order (chosen by score)
ctx=$(cat "$JEV_HOME/observed-order.context.txt" 2>/dev/null)
a=${ctx%%priv/repo/migrations*} b=${ctx%%pg-staging-3*} c=${ctx%%backfill the consumer*}
[ "${#a}" -lt "${#b}" ] && [ "${#b}" -lt "${#c}" ] && ok "injected facts appear in transcript order" || bad "injected facts not in transcript order"

# --- second compaction: facts re-injected by the first are carried forward.
# The session has no ledger yet (it began before the ledger, or a compaction fell
# back to v1), so the first ledger run starts at the boundary and must keep the
# facts that compaction re-injected, whatever Jev scores them. The assertions are
# on the carried facts themselves; whether the summary "covers" them is Jev's
# call, so the injection is only reported.
S=fixture-carried
cp "$FIX/transcript-carried.jsonl" "$JEV_HOME/carried.jsonl"
jq -cn --arg s $S --arg tp "$JEV_HOME/carried.jsonl" '{session_id: $s, transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}' | "$J/compact-pre.sh"
jq -e -s '[.[] | select(.kind == "carried" and .superseded_by == null and .score >= 1.5)] | length == 2 and (.[0].text | test("pg-staging-7"))' "$JEV_HOME/ledger/$S.jsonl" >/dev/null 2>&1 &&
  ok "round 2 (first ledger run): both facts the v1 compaction re-injected are live ledger facts (kind carried, kept at >= 1.5)" ||
  bad "round 2: carried facts not in the ledger: $(jq -c -s '[.[] | {kind, score, superseded_by, t: .text[0:40]}]' "$JEV_HOME/ledger/$S.jsonl" 2>/dev/null)"
jq -e '.mode == "ledger" and ([.facts[] | select(.kind == "carried")] | length == 2)' "$JEV_HOME/compact/$S.json" >/dev/null 2>&1 &&
  ok "round 2: the compaction snapshot holds both carried facts" || bad "round 2: carried facts missing from the snapshot"
jq -cn --arg s $S --arg m "$(cat "$FIX/summary-carried.txt")" '{session_id: $s, hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: $m}' | "$J/compact-post.sh"
ctx=$(sess $S | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
case $ctx in *pg-staging-7*) echo "note - round 2: the round-1 fact was re-injected (coverage said the summary dropped it)" ;; *) echo "note - round 2: coverage judged the round-1 fact kept by the summary: $(jq -c '[.facts[] | {n, kind, covered_p}]' "$JEV_HOME/compact/$S.json")" ;; esac
# v1 mode, same transcript: carried facts are extracted deterministically
S=fixture-carried-v1
JEV_LEDGER=0 jq -cn --arg s $S --arg tp "$JEV_HOME/carried.jsonl" '{session_id: $s, transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}' | JEV_LEDGER=0 "$J/compact-pre.sh"
jq -e '.mode == "v1" and ([.facts[] | select(.kind == "carried")] | length == 2)' "$JEV_HOME/compact/$S.json" >/dev/null 2>&1 &&
  ok "round 2, v1 mode: both carried facts are candidates" || bad "round 2, v1 mode: carried facts not extracted"

# --- a subagent compacting its own context (agent_id set) must not touch the parent's state
S=fixture-sub
jq -cn --arg s $S --arg tp "$TP" '{session_id: $s, agent_id: "asub1", agent_type: "general-purpose", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}' | "$J/compact-pre.sh"
[ ! -e "$JEV_HOME/compact/$S.json" ] && ok "subagent PreCompact (agent_id set): no state written" || bad "subagent PreCompact wrote state"
pre $S >/dev/null
o=$(jq -cn --arg s $S '{session_id: $s, agent_id: "asub1", hook_event_name: "SessionStart", source: "compact"}' | "$J/compact-session.sh")
jq -cn --arg s $S --arg m "$SUMMARY" '{session_id: $s, agent_id: "asub1", hook_event_name: "PostCompact", trigger: "auto", compact_summary: $m}' | "$J/compact-post.sh"
[ -z "$o" ] && jq -e '.consumed_at == null and .coverage == null' "$JEV_HOME/compact/$S.json" >/dev/null &&
  ok "subagent SessionStart/PostCompact (agent_id set): parent state untouched" || bad "subagent hooks touched parent state"

# --- optional guard: blocks one auto-compaction per session, then never again
S=fixture-e
gpre() { jq -cn --arg s $S --arg tp "$TP" --arg t "$1" '{session_id: $s, transcript_path: $tp, hook_event_name: "PreCompact", trigger: $t}' |
  JEV_COMPACT_GUARD=1 JEV_COMPACT_GUARD_MIN=0 "$J/compact-pre.sh"; }
gpre manual >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "guard: never blocks a manual /compact" || bad "guard: blocked manual (rc=$rc)"
err=$(gpre auto 2>&1 >/dev/null); rc=$?
[ $rc -eq 2 ] && [ -n "$err" ] && ok "guard: first auto compaction mid-operation blocked (exit 2: ${err:0:60}...)" || bad "guard: rc=$rc err=$err"
gpre auto >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "guard: second auto compaction in the same session allowed" || bad "guard: blocked twice (rc=$rc)"
jq -cn --arg s $S --arg tp "$TP" '{session_id: $s, transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}' | "$J/compact-pre.sh"; rc=$?
[ $rc -eq 0 ] && ok "guard: off by default" || bad "guard: blocked with guard off"

echo
echo "--- additionalContext (observed order) ---"
cat "$JEV_HOME/observed-order.context.txt" 2>/dev/null
echo "---"
echo "compact-fixture: $fails failure(s)   (artifacts: $JEV_HOME)"
[ "$fails" -eq 0 ]
