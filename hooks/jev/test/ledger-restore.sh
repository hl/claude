#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# ledger-restore.sh — A, then B, then A again, against the live Jev API (needs a key).
#
# Jev tends to score a restated A as obsolete once the ledger holds B, so the
# ledger must not depend on that score: a statement whose normalised text
# matches a superseded fact is kept at the old score and retires the fact that
# had replaced it. Two probes, each run JEV_RESTORE_RUNS (3) times, must all pass:
#   aba       short restatement ("Use advisory locks for job dedupe.")
#   revexact  long restatement, word for word
# A third, paraphrased revert ("Back to advisory locks ...") is only reported:
# it relies on Jev calling it a full correction (no score floor then applies).
set -uo pipefail
export JEV_MIGRATE=0 # tests never move this machine's real ~/.claude/jev
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID
W=$(mktemp -d "${TMPDIR:-/tmp}/jev-restore.XXXXXX")
RUNS=${JEV_RESTORE_RUNS:-3}
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

# probe <name> <run> <A> <B> <A-again>: one Stop per turn; prints the live statements
probe() {
  local home="$W/$1-$2/home" tp="$W/$1-$2/t.jsonl" s="restore-$1-$2" i=0 t
  mkdir -p "$W/$1-$2"
  : >"$tp"
  shift 2
  for t in "$@"; do
    i=$((i + 1))
    jq -cn --arg u "u$i" --arg t "$t" '{type: "user", uuid: $u, promptSource: "typed", message: {role: "user", content: $t}}' >>"$tp"
    jq -cn --arg u "a$i" '{type: "assistant", uuid: $u, message: {role: "assistant", content: [{type: "text", text: "OK."}]}}' >>"$tp"
    jq -cn --arg s "$s" --arg tp "$tp" '{session_id: $s, transcript_path: $tp, hook_event_name: "Stop"}' | JEV_HOME="$home" "$J/ledger.sh"
  done
  echo "$home/ledger/$s.jsonl"
}
check() { # <ledger> <label> -> 0 if the last A is live and every B fact is superseded
  jq -e -s --arg a "$2" '
    ([.[] | select(.text | contains($a))] | last) as $last
    | ($last != null and $last.superseded_by == null)
      and all(.[] | select((.text | test("unique index")) and .id != $last.id); .superseded_by != null)' "$1" >/dev/null 2>&1
}

A1="Use advisory locks for job dedupe."
B1="Change of plan: use a unique index instead."
A2="Use Postgres advisory locks for the job dedupe."
B2="Change of plan: use a unique index on jobs.dedupe_key instead of advisory locks."
A3="Back to advisory locks for the job dedupe: the unique index breaks bulk imports."
for r in $(seq 1 "$RUNS"); do
  L=$(probe aba "$r" "$A1" "$B1" "$A1")
  check "$L" "$A1" && ok "aba run $r: restated A is live, B superseded ($(jq -r -s '[.[] | "\(.id)\(if .superseded_by then ">" + .superseded_by else "" end)"] | join(" ")' "$L"))" ||
    bad "aba run $r: $(jq -c '{id, score, superseded_by, restores, t: .text[0:50]}' "$L" | paste -sd' ' -)"
  L=$(probe revexact "$r" "$A2" "$B2" "$A2")
  check "$L" "$A2" && ok "revexact run $r: restated A is live, B superseded ($(jq -r -s '[.[] | "\(.id)\(if .superseded_by then ">" + .superseded_by else "" end)"] | join(" ")' "$L"))" ||
    bad "revexact run $r: $(jq -c '{id, score, superseded_by, restores, t: .text[0:50]}' "$L" | paste -sd' ' -)"
  L=$(probe revert "$r" "$A2" "$B2" "$A3")
  if check "$L" "Back to advisory locks"; then echo "note - paraphrased revert run $r: kept and B retired (Jev called it a full correction)"; else
    echo "note - paraphrased revert run $r: $(jq -r -s '[.[] | "\(.id)\(if .superseded_by then ">" + .superseded_by else "" end)\(if (.corrected_by // []) | length > 0 then " corrected by " + (.corrected_by | join(",")) else "" end)"] | join(" ")' "$L")"
  fi
done
echo "ledger-restore: $fails failure(s)"
[ "$fails" -eq 0 ]
