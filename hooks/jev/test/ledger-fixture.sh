#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# ledger-fixture.sh — the long-session path end to end on a synthetic session
# (needs a Jev key; hits the live API). With JEV_LIVE=1 or JEV_EVIDENCE=1 it
# rewrites test/evidence/ledger-fixture.txt.
#
# fixtures/ledger-session.jsonl: 14 turns. Turn 3 says staging is pg-staging-3:6543,
# turn 9 corrects it to pg-staging-7:6544; turn 2 decides Redis Streams, turn 10
# switches to Oban Pro, and turn 14 restates turn 2 word for word (A, B, A).
# Turn 5 saves an artifact. Compaction 1 happens after turn 7 (boundary, summary
# and the re-injected context are appended the way Claude Code writes them);
# compaction 2 after turn 14, with a summary that drops three facts: the
# migrations rule and the flag default (live) and the pg-staging-3 statement
# (superseded).
#
# Asserts: after replaying Stop per turn the ledger has the live facts, both
# corrections mark the earlier facts superseded, the artifact is indexed, the
# cursor sits at the end of the transcript; a second replay changes nothing;
# the injection after compaction 2 has the 2 live dropped facts and not the
# superseded one, the artifact line, the live .orchestrator.md section and not
# the DONE/BLOCKED ones, in < 9000 chars.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures/ledger-session.jsonl"
EVID="$HERE/evidence/ledger-fixture.txt"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID
W=$(mktemp -d "${TMPDIR:-/tmp}/jev-lf.XXXXXX")
export JEV_HOME="$W/home"
S=ledger-fixture
TP="$W/transcript.jsonl"
PROJ="$W/project"
mkdir -p "$PROJ"
: >"$TP"
fails=0
log() { printf '%s\n' "$*" | tee -a "$W/evidence.txt"; }
ok() { log "ok   - $1"; }
bad() {
  log "FAIL - $1"
  fails=$((fails + 1))
}

cat >"$PROJ/.orchestrator.md" <<'EOF'
# Orchestrator log

## 2026-10-18 — event fan-out (OPS-4821)
- Brief: per-account ordered fan-out on Oban Pro ordered queues; PR title starts with OPS-4821
- Status: review round 1

## 2026-10-17 — flag documentation — DONE
- What: documented fanout_streams_enabled

## 2026-10-16 — staging data migration
- Status: BLOCKED on the DBA team
EOF
printf '# Review of the stream producer (round 1)\n\nBLOCKING: stream length is unbounded (no MAXLEN).\nBLOCKING: consumers never ack, so the group re-delivers forever.\n' >"$W/review.md"

stop() { jq -cn --arg s "$S" --arg tp "$TP" --arg cwd "$PROJ" '{session_id: $s, transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: false}' | "$J/ledger.sh"; }
pre() { jq -cn --arg s "$S" --arg tp "$TP" --arg cwd "$PROJ" '{session_id: $s, transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact", trigger: "auto"}' | "$J/compact-pre.sh"; }
substop() { jq -cn --arg s "$S" --arg m "$1" '{session_id: $s, hook_event_name: "SubagentStop", agent_type: "", agent_id: "acompact", last_assistant_message: $m}' | "$J/compact-post.sh"; }
sess() { jq -cn --arg s "$S" --arg tp "$TP" --arg cwd "$PROJ" '{session_id: $s, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}' | "$J/compact-session.sh"; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

summary1='<analysis>x</analysis><summary>The user is adding per-account ordered event fan-out to the platform app. Rule: never touch the migrations in priv/repo/migrations (the DBA team owns them). Decision: Redis Streams for the fan-out, because Oban cannot guarantee per-account ordering. Integration tests must run against pg-staging-3 on port 6543, not localhost; the last run failed with connection refused on pg-staging-3:6543. Branch feat/event-fanout-streams; the producer is lib/platform/events/stream_producer.ex (one stream per account). A reviewer found two blocking issues (saved as review-producer-r1). The feature flag fanout_streams_enabled defaults to off in every environment.</summary>'
summary2='<analysis>x</analysis><summary>Task: per-account ordered event fan-out in the platform app, ticket OPS-4821 (the PR title starts with it). The fan-out decision changed from Redis Streams to Oban Pro ordered queues, because the platform team already pays for Oban Pro. Integration tests target pg-staging-7 on port 6544. Branch feat/event-fanout-streams; the producer is lib/platform/events/stream_producer.ex; PR https://github.com/acme/platform/pull/2417 is open. Remaining: backfill the consumer group offsets for existing accounts before enabling the flag, then CI on the PR. The round-1 review (unbounded stream length, no consumer-group ack) is saved as review-producer-r1.</summary>'

append_compaction() { # <summary> <injected-context>: what Claude Code writes after a compaction
  local last
  last=$(tail -n 1 "$TP" | jq -r .uuid)
  {
    jq -cn --arg p "$last" '{type: "system", subtype: "compact_boundary", uuid: "B\($p)", parentUuid: null, logicalParentUuid: $p, content: "Conversation compacted", compactMetadata: {trigger: "auto"}}'
    jq -cn --arg p "$last" --arg m "$1" '{type: "user", uuid: "S\($p)", parentUuid: "B\($p)", isCompactSummary: true, isVisibleInTranscriptOnly: true, message: {role: "user", content: $m}}'
    jq -cn --arg p "$last" --arg c "$2" '{type: "attachment", uuid: "H\($p)", parentUuid: "S\($p)", attachment: {type: "hook_additional_context", hookEvent: "SessionStart", hookName: "SessionStart:compact", content: [$c]}}'
  } >>"$TP"
}

: >"$W/evidence.txt"
log "# ledger-fixture.sh — $(date -u +%Y-%m-%dT%H:%MZ), Jev $(JEV_HOME=$W/x "$J/route.sh" x 2>/dev/null | jq -r .jev_model)"
log "## replay: Stop after every turn (ms per ledger step, includes the Jev call)"
lat=""
for t in $(seq 1 14); do
  jq -c --argjson t "$t" 'select(._turn == $t)' "$FIX" >>"$TP"
  if [ "$t" = 5 ]; then
    p=$(cd "$PROJ" && "$J/artifact.sh" review-producer-r1 --from-file "$W/review.md" --session "$S")
    [ -f "$p" ] && ok "turn 5: artifact.sh saved $(basename "$p")" || bad "turn 5: artifact.sh failed"
  fi
  t0=$(now_ms)
  stop
  lat="$lat $(($(now_ms) - t0))"
  if [ "$t" = 7 ]; then
    pre
    substop "$summary1"
    ctx1=$(sess | jq -r '.hookSpecificOutput.additionalContext // empty')
    [ -n "$ctx1" ] && ok "compaction 1 (after turn 7): context injected (${#ctx1} chars)" || bad "compaction 1: nothing injected"
    append_compaction "$summary1" "$ctx1"
  fi
done
log "ledger step ms per turn:$lat"
log "## ledger after 14 turns"
jq -r '"\(.id) [\(.kind) \(.score)]\(if .superseded_by then " SUPERSEDED by \(.superseded_by)" else "" end)\(if (.supersedes | length) > 0 then " supersedes \(.supersedes | join(","))" else "" end): \(.text[0:150])"' \
  "$JEV_HOME/ledger/$S.jsonl" | sed "s#$W#<tmp>#g" | tee -a "$W/evidence.txt"

L="$JEV_HOME/ledger/$S.jsonl"
M="$JEV_HOME/ledger/$S.meta.json"
live() { jq -e -s --arg r "$1" 'any(.[]; .superseded_by == null and (.text | test($r)))' "$L" >/dev/null; }
dead() { jq -e -s --arg r "$1" 'any(.[]; .superseded_by != null and (.text | test($r))) and (any(.[]; .superseded_by == null and (.text | test($r))) | not)' "$L" >/dev/null; }
live 'priv/repo/migrations' && live 'fanout_streams_enabled' && live 'pg-staging-7' && live 'OPS-4821' && live 'pull/2417' &&
  ok "ledger: live facts include the migrations rule, the flag, pg-staging-7, OPS-4821, PR 2417" || bad "ledger: live facts missing"
dead 'staging database is pg-staging-3' && ok "correction 1: the pg-staging-3:6543 statement is superseded" || bad "correction 1: pg-staging-3 statement not superseded"
dead "^Decision: we.ll use Redis Streams" && ok "correction 2: the Redis Streams decision is superseded" || bad "correction 2: Redis Streams decision not superseded"
jq -e -s 'any(.[]; .kind == "artifact" and (.text | test("review-producer-r1")) and .superseded_by == null)' "$L" >/dev/null && ok "artifact indexed in the ledger" || bad "artifact fact missing"
# A, B, A: the restated turn-2 statement is a new live fact (deterministic: dedupe is
# against live facts only); whether it retires the Oban Pro facts is Jev's call.
a_txt="User said: Go with Redis Streams for the fan-out; Oban can't guarantee per-account ordering."
jq -e -s --arg t "$a_txt" '[.[] | select(.text == $t)] | length == 2 and (.[0].superseded_by != null) and (.[1].superseded_by == null)' "$L" >/dev/null &&
  ok "A, B, A: turn 2 restated after the switch is live again (the first copy stays superseded)" || bad "A, B, A: restated statement not live"
log "note - A, B, A: Oban Pro facts after the restatement: $(jq -r -s --arg t "$a_txt" '([.[] | select(.text == $t)] | last | .id) as $a
  | [.[] | select(.text | test("Oban Pro")) | "\(.id) " + (if .superseded_by == $a then "superseded by the restatement" elif ((.corrected_by // []) | index($a)) then "partly corrected by it" elif .superseded_by then "superseded by \(.superseded_by)" else "live" end)] | join("; ")' "$L")"
size=$(wc -c <"$TP" | tr -d ' ')
lastu=$(grep -o '"uuid":"[^"]*"' "$TP" | tail -n 1 | cut -d'"' -f4)
jq -e --argjson s "$size" --arg u "$lastu" '.offset == $s and .last_uuid == $u' "$M" >/dev/null &&
  ok "cursor: offset $size = transcript size, last_uuid $lastu" || bad "cursor wrong: $(jq -c '{offset, last_uuid}' "$M") vs size $size / $lastu"

# second replay: Stop again per turn on the full transcript -> no-op
before=$(cksum <"$L")
mbefore=$(jq -c '{offset, last_uuid, next_id}' "$M")
for _ in 1 2 3; do stop; done
[ "$(cksum <"$L")" = "$before" ] && [ "$(jq -c '{offset, last_uuid, next_id}' "$M")" = "$mbefore" ] &&
  ok "second replay is a no-op (ledger and cursor unchanged)" || bad "second replay changed the ledger"

# a Stop that arrives while another step holds the lock is skipped, not queued
mkdir "$JEV_HOME/ledger/$S.lock" && date +%s >"$JEV_HOME/ledger/$S.lock/at"
printf '%s\n' "$(jq -c --argjson t 99 '._turn = $t | .uuid = "L999" | .message.content = "late turn"' <(tail -n 1 "$FIX"))" >>"$TP"
t0=$(now_ms)
stop
ms=$(($(now_ms) - t0))
tail -n 1 "$JEV_HOME/log/ledger.jsonl" | jq -e '.status == "locked"' >/dev/null && [ "$ms" -lt 1000 ] &&
  ok "Stop during a running step: skipped in ${ms} ms (status locked)" || bad "locked Stop not skipped"
rm -rf "$JEV_HOME/ledger/$S.lock"

log "## compaction 2 (after turn 14): summary drops the migrations rule, the flag default and pg-staging-3"
pre
substop "$summary2"
out=$(sess)
ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out")
printf '%s\n' "$ctx" | sed "s#$W#<tmp>#g" | sed 's/^/    /' | tee -a "$W/evidence.txt" >/dev/null
[ -n "$ctx" ] && [ "${#ctx}" -lt 9000 ] && ok "injection is ${#ctx} chars (< 9000)" || bad "injection size ${#ctx}"
fl=$(printf '%s\n' "$ctx" | grep '^- ' || true)
case $fl in *priv/repo/migrations*) ok "dropped live fact injected: migrations rule" ;; *) bad "migrations rule not injected" ;; esac
case $fl in *fanout_streams_enabled*) ok "dropped live fact injected: flag default off" ;; *) bad "flag default not injected" ;; esac
case $fl in *"staging database is pg-staging-3"*) bad "superseded pg-staging-3 statement injected" ;; *) ok "superseded pg-staging-3 statement not injected" ;; esac
case $fl in *"Redis Streams for the event fan-out, because"*) bad "superseded Redis Streams decision injected" ;; *) ok "superseded Redis Streams decision not injected" ;; esac
case $ctx in *review-producer-r1.md*) ok "artifact index line present" ;; *) bad "artifact line missing" ;; esac
case $ctx in *"event fan-out (OPS-4821)"*) ok ".orchestrator.md live section present" ;; *) bad "live orchestrator section missing" ;; esac
case $ctx in *"flag documentation"* | *"staging data migration"*) bad "DONE/BLOCKED orchestrator section injected" ;; *) ok "DONE and BLOCKED orchestrator sections left out" ;; esac
a=${ctx%%Live sections*} b=${ctx%%Artifacts saved*} c=${ctx%%Facts preserved*}
[ "${#a}" -lt "${#b}" ] && [ "${#b}" -lt "${#c}" ] && ok "order: orchestrator, artifacts, facts" || bad "section order"
log "compact.jsonl: $(grep '"event":"post"' "$JEV_HOME/log/compact.jsonl" | tail -n 1 | jq -c '{covered: (.covered | length), missing}')"

log "ledger-fixture: $fails failure(s)"
if [ "${JEV_LIVE:-0}" = 1 ] || [ "${JEV_EVIDENCE:-0}" = 1 ]; then sed "s#$W#<tmp>#g; s#$HOME#~#g" "$W/evidence.txt" >"$EVID"; fi
[ "$fails" -eq 0 ]
