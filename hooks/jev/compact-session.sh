#!/usr/bin/env bash
# compact-session.sh — SessionStart hook (matcher "compact"). Re-injects what
# the summary may have lost, as additionalContext (<= JEV_COMPACT_MAX_CHARS, 9000):
#
#   (c) authored state: if $CLAUDE_PROJECT_DIR/.orchestrator.md (or <cwd>/...)
#       exists, the heading, first line and Status line of every section not
#       marked DONE or BLOCKED (orchestrator.awk); most recent sections win
#       when over JEV_COMPACT_ORCH_MAX (4500) chars
#   (b) the artifact index: one line per file in ~/.local/state/jev/artifacts/<session>/
#       (newest first when over JEV_COMPACT_ARTIFACT_MAX, 2000 chars)
#   (a) facts, only when compact-pre.sh left a scored state file: with coverage
#       (compact-post.sh ran), facts scored >= important that the summary did
#       not keep; without, the top-ranked facts. Chosen by score (highest first,
#       until the size cap), listed in transcript order, plus where the full list is.
# Priority when space runs out: (c) > (b) > (a).
#
# No Jev call. (c) and (b) need no state file, so they are injected in every
# session, Claudette or not, and when Jev is unreachable. Marks the state file
# consumed. Nothing to say -> no output.
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=compact-session
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MAX_CHARS=${JEV_COMPACT_MAX_CHARS:-9000}
MIN_SCORE=${JEV_COMPACT_MIN_SCORE:-1.5}
MAX_AGE=${JEV_COMPACT_MAX_AGE:-3600}
ORCH_MAX=${JEV_COMPACT_ORCH_MAX:-4500}
ART_MAX=${JEV_COMPACT_ARTIFACT_MAX:-2000}

jev_disabled && exit 0
payload=$(cat)
source=$(jq -r '.source // empty' <<<"$payload")
[ "$source" = compact ] || exit 0
# A subagent compacting its own context carries agent_id; the state belongs to the parent.
[ -z "$(jq -r '.agent_id // empty' <<<"$payload")" ] || exit 0
JEV_SESSION=$(jq -r '.session_id // empty' <<<"$payload")
export JEV_SESSION
case $JEV_SESSION in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
cwd=$(jq -r '.cwd // empty' <<<"$payload")
state="$JEV_HOME/compact/$JEV_SESSION.json"
adir="$JEV_HOME/artifacts/$JEV_SESSION"
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/jev-sess.XXXXXX")
trap 'rm -rf "$tmpd"; exit 0' EXIT

# --- (a) facts from the state file (coverage or ranking)
facts_mode=none
echo '{"mode":"none","facts":[]}' >"$tmpd/facts.json"
if [ -f "$state" ] && jq -e '(.consumed_at // null) == null' "$state" >/dev/null 2>&1; then
  age=$(($(date +%s) - $(jq -r '.extracted_epoch // 0' "$state")))
  if [ "$age" -le "$MAX_AGE" ] && jq -e '.jev_ok == true' "$state" >/dev/null; then
    jq -c --argjson min "$MIN_SCORE" '(.coverage != null) as $cov
      | {mode: (if $cov then "coverage" else "ranking" end), mid_operation,
         facts: [.facts[] | select((.score // 0) >= $min) | select(if $cov then (.covered | not) else true end)]}' "$state" >"$tmpd/facts.json"
    facts_mode=$(jq -r .mode "$tmpd/facts.json")
  fi
  s=$(jq -c --arg at "$(jev_now)" '.consumed_at = $at | .phase = "consumed"' "$state") &&
    printf '%s\n' "$s" >"$state.tmp" && mv "$state.tmp" "$state"
fi

# --- (c) live .orchestrator.md sections
orch=""
for d in "${CLAUDE_PROJECT_DIR:-}" "$cwd"; do
  if [ -n "$d" ] && [ -f "$d/.orchestrator.md" ]; then
    orch="$d/.orchestrator.md"
    break
  fi
done
: >"$tmpd/orch.tsv"
[ -z "$orch" ] || awk -f "$JEV_DIR/orchestrator.awk" "$orch" >"$tmpd/orch.tsv" 2>/dev/null || true

# --- (b) artifact index, newest first
: >"$tmpd/art.tsv"
if [ -d "$adir" ]; then
  # shellcheck disable=SC2010,SC2012 # names are ours (sanitised); ls -t gives mtime order portably
  ls -t "$adir" 2>/dev/null | grep '\.md$' | while IFS= read -r f; do
    t=$(grep -m 1 -v -e '^[[:space:]]*$' "$adir/$f" 2>/dev/null | sed -e 's/^<!-- *//' -e 's/ *-->$//' -e 's/^#* *//' | cut -c1-140 || true)
    printf '%s\t%s\n' "$adir/$f" "$t"
  done >"$tmpd/art.tsv"
fi

ctx=$(jq -n -r --slurpfile fa "$tmpd/facts.json" --rawfile orch "$tmpd/orch.tsv" --rawfile art "$tmpd/art.tsv" \
  --arg orch_path "$orch" --arg state "$state" --argjson max "$MAX_CHARS" --argjson omax "$ORCH_MAX" --argjson amax "$ART_MAX" '
  def lines: split("\n") | map(select(length > 0) | split("\t"));
  # keep_last($cap): the longest suffix of an array of strings that fits in $cap chars
  def keep_last($cap): reduce (reverse[]) as $l ({out: [], len: 0};
      if .len + ($l | length) + 1 <= $cap then .out = [$l] + .out | .len += ($l | length) + 1 else . end) | .out;
  $fa[0] as $f
  # (c)
  | ([$orch | lines[] | "## " + (.[0] | sub("^#+ *"; ""))
       + (if (.[1] // "") != "" then "\n  " + .[1] else "" end)
       + (if (.[2] // "") != "" and (.[2] != .[1]) then "\n  " + .[2] else "" end)]
     | keep_last($omax)) as $osec
  | (if ($osec | length) > 0
     then ["Live sections of \($orch_path) (sections marked DONE or BLOCKED left out; the file is authoritative):"] + $osec
     else [] end) as $c
  # (b)
  | ([$art | lines[] | "* " + .[0] + (if (.[1] // "") != "" then " — " + .[1] else "" end)] | .[0:200]) as $alines
  | (reduce $alines[] as $l ({out: [], len: 0}; if .len + ($l | length) + 1 <= $amax then .out += [$l] | .len += ($l | length) + 1 else . end) | .out) as $afit
  | (if ($afit | length) > 0
     then ["Artifacts saved this session (read the file instead of redoing the work)" + (if ($afit | length) < ($alines | length) then ", newest \($afit | length) of \($alines | length):" else ":" end)] + $afit
     else [] end) as $b
  # (a) whatever room is left
  | "The full ranked fact list is in \($state)." as $d
  | (([$c[], $b[], $d] | map(length + 1) | add) // 0) as $used
  | "Facts preserved across compaction by the Jev hook (in transcript order; the summary did not include these or they were critical; a fact that conflicts with the summary may be stale, so check the file or PR):" as $head
  | ($f.facts | sort_by(-.score, -.n) | map({n, l: "- \(.text)"})) as $cand
  | (if ($f.mid_operation // 0) >= 0.6
     then ["Before compaction the last turn was probably mid-operation (p=\($f.mid_operation)): an edit, command or review whose result had not been recorded yet."]
     else [] end) as $session
  | (reduce $cand[] as $x ({out: [], len: ($used + ($head | length) + 1 + ([$session[] | length + 1] | add // 0) + 2)};
       if .len + ($x.l | length) + 1 <= $max then .out += [$x] | .len += ($x.l | length) + 1 else . end)
     | .out | sort_by(.n) | map(.l)) as $afacts
  | (if ($afacts | length) > 0 then [$head] + $afacts + $session + [$d] else [] end) as $a
  | if ($c | length) + ($b | length) + ($a | length) == 0 then ""
    else ($c + (if ($c | length) > 0 and ($b | length) + ($a | length) > 0 then [""] else [] end)
          + $b + (if ($b | length) > 0 and ($a | length) > 0 then [""] else [] end) + $a) | join("\n") end
')
[ "${#ctx}" -le "$MAX_CHARS" ] || ctx=${ctx:0:$MAX_CHARS}

nf=$(printf '%s\n' "$ctx" | grep -c '^- ' || true)
no=$(wc -l <"$tmpd/orch.tsv" | tr -d ' ')
na=$(wc -l <"$tmpd/art.tsv" | tr -d ' ')
jev_log compact.jsonl "$(jq -cn --argjson n "$nf" --argjson c "${#ctx}" --arg m "$facts_mode" --argjson o "$no" --argjson a "$na" \
  '{event: "session", status: "ok", mode: $m, injected: $n, orchestrator_sections: $o, artifacts: $a, chars: $c}')"
[ -n "$ctx" ] || exit 0
jq -cn --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
