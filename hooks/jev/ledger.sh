#!/usr/bin/env bash
# ledger.sh — Stop hook: keep a per-session ledger of the facts that must
# survive compaction, one turn at a time.
#
#   ledger.sh                       Stop hook (JSON on stdin)
#   ledger.sh --flush               same, but waits for a running step instead of
#                                   skipping (compact-pre.sh uses this)
#   ledger.sh --add <session> <kind> <score> <text> [source] [supersede-match]
#                                   append one fact directly (artifact.sh); live
#                                   facts of the same kind whose text contains
#                                   supersede-match are marked superseded by it
#
# Each run reads only the transcript bytes after the cursor (complete lines
# only), extracts candidate facts with extract.jq (user statements, decisions,
# paths, URLs, branches, the failing command, open items), drops ones already
# in the ledger, and asks Jev in one round (split into parallel requests of at
# most JEV_LEDGER_PER_REQ questions) for:
#   - a score per candidate (irrelevant / nice / important / critical), and
#   - per candidate x recent live fact of the same family, whether the
#     candidate corrects it fully, partly or not at all (choice).
# A full correction marks the old fact superseded_by (it is never injected
# again); a partial one adds to its corrected_by (it stays live and is injected
# with the correction attached), so a multi-fact message is not lost because
# one of its facts changed.
# Candidates scored >= JEV_COMPACT_MIN_SCORE (important), and lower-scored ones
# that supersede an important live fact, are appended in transcript order to
#   ~/.local/state/jev/ledger/<session_id>.jsonl
#     {id, ts, kind, text, score, supersedes: [ids], corrects: [ids],
#      superseded_by, corrected_by: [ids], source_uuid}
# and the facts they supersede get superseded_by. The cursor lives next to it
# in <session_id>.meta.json {offset, last_uuid, next_id, ...}.
#
# First run on a session (no cursor): starts at the last compact boundary, as
# v1 extraction did, and keeps the facts an earlier (v1) compaction re-injected
# after it ("carried", kept whatever their score), so sessions that began
# before the ledger existed lose nothing. Jev failure: the cursor does not
# move, so the next turn retries. Idempotent (the cursor); a second Stop while
# one runs is skipped (lock). Candidates are deduplicated against LIVE facts
# only, so a statement that comes back after being superseded (A, B, A again)
# is a new live fact; open items are also deduplicated on normalised text.
# Housekeeping: superseded facts older than 7 days move to <session>.archive.jsonl;
# once a day the first run deletes ledger, snapshot, artifact and pointer files
# untouched for 30 days (JEV_RETAIN_DAYS), trims logs over 5 MB, and starts
# autotune.sh in the background (JEV_AUTOTUNE=0 turns that off).
# Never blocks, never prints. JEV_LEDGER=0 or JEV_DISABLED=1 turns it off.
# Safe as an async hook: a killed run releases its lock (TERM trap), and a
# lock whose holder is gone is broken at once.
set -euo pipefail
trap 'exit 0' EXIT
trap 'exit 0' TERM INT HUP

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=${JEV_HOOK:-ledger}
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MIN_SCORE=${JEV_COMPACT_MIN_SCORE:-1.5}
SUP_MIN=${JEV_LEDGER_SUPERSEDE_MIN:-0.6}
MAX_FACTS=${JEV_LEDGER_MAX_CANDIDATES:-${JEV_COMPACT_MAX_FACTS:-60}}
TAIL_CHARS=${JEV_LEDGER_TAIL_CHARS:-20000}
PER_REQ=${JEV_LEDGER_PER_REQ:-60}
MAX_PAIRS=${JEV_LEDGER_MAX_PAIRS:-120}
LOCK_WAIT=${JEV_LEDGER_LOCK_WAIT:-3}
RETAIN_DAYS=${JEV_RETAIN_DAYS:-30}
LDIR="$JEV_HOME/ledger"

[ "${JEV_LEDGER:-1}" = 0 ] && exit 0
jev_disabled && exit 0

# take_lock <session> <wait-seconds>
take_lock() {
  local i=0
  while ! jev_lock "$LDIR/$1.lock" 60; do
    [ "$i" -lt "$(($2 * 10))" ] || return 1
    sleep 0.1
    i=$((i + 1))
  done
}

if [ "${1:-}" = --add ]; then
  sid=${2:?} kind=${3:?} score=${4:?} text=${5:?} src=${6:-} match=${7:-}
  mkdir -p "$LDIR"
  take_lock "$sid" 5 || exit 0
  trap 'jev_unlock "$LDIR/$sid.lock"; exit 0' EXIT
  meta="$LDIR/$sid.meta.json"
  next=$(jq -r '.next_id // 1' "$meta" 2>/dev/null || echo 1)
  if [ -n "$match" ] && [ -s "$LDIR/$sid.jsonl" ]; then
    jq -c --arg k "$kind" --arg m "$match" --arg id "f$next" '
      if .superseded_by == null and .kind == $k and (.text | contains($m)) then .superseded_by = $id else . end' \
      "$LDIR/$sid.jsonl" >"$LDIR/$sid.jsonl.tmp" && mv "$LDIR/$sid.jsonl.tmp" "$LDIR/$sid.jsonl"
  fi
  jq -cn --arg id "f$next" --arg ts "$(jev_now)" --arg k "$kind" --arg t "$text" --argjson s "$score" --arg src "$src" \
    '{id: $id, ts: $ts, kind: $k, text: $t, score: $s, supersedes: [], corrects: [], superseded_by: null, corrected_by: [],
      source_uuid: (if $src == "" then null else $src end)}' >>"$LDIR/$sid.jsonl"
  m=$(jq -c --argjson n "$((next + 1))" '.next_id = $n' "$meta" 2>/dev/null || jq -cn --argjson n "$((next + 1))" '{next_id: $n}')
  printf '%s\n' "$m" >"$meta.tmp" && mv "$meta.tmp" "$meta"
  exit 0
fi

flush=false
[ "${1:-}" = --flush ] && flush=true
payload=$(cat)
IFS=$'\t' read -r sid tp agent cwd < <(jq -r '[.session_id // "-", .transcript_path // "-", .agent_id // "-", .cwd // "-"] | @tsv' <<<"$payload") || exit 0
[ "$agent" = - ] || exit 0 # subagents and teammates keep no ledger of their own
[ "$sid" != - ] && [ "$tp" != - ] && [ -f "$tp" ] || exit 0
JEV_SESSION=$sid
export JEV_SESSION
mkdir -p "$LDIR" "$JEV_HOME/sessions"

# Pointers for artifact.sh when $CLAUDE_CODE_SESSION_ID is not exported.
[ -n "${CLAUDE_PID:-}" ] && printf '%s\n' "$sid" >"$JEV_HOME/sessions/pid-$CLAUDE_PID"
# Keyed by the physical path, so /tmp and /private/tmp, or a // in $TMPDIR, agree.
if [ "$cwd" != - ]; then
  phys=$(cd "$cwd" 2>/dev/null && pwd -P) || phys=$cwd
  printf '%s\n' "$sid" >"$JEV_HOME/sessions/cwd-$(printf '%s' "$phys" | cksum | cut -d' ' -f1)"
fi

if [ "$flush" = true ]; then take_lock "$sid" "$LOCK_WAIT" || exit 0; else take_lock "$sid" 0 || {
  jev_log ledger.jsonl '{"event":"step","status":"locked"}'
  exit 0
}; fi
# Temp files live next to the ledger, so every mv is a same-volume rename.
tmpd=$(mktemp -d "$LDIR/.tmp.XXXXXX")
trap 'rm -rf "$tmpd"; jev_unlock "$LDIR/$sid.lock"; exit 0' EXIT

# Once a day: drop state nobody has touched for RETAIN_DAYS.
stamp="$JEV_HOME/.swept-$(date -u +%Y%m%d)"
if [ ! -e "$stamp" ]; then
  : >"$stamp" 2>/dev/null || true
  find "$JEV_HOME" -maxdepth 1 -name '.swept-*' ! -name "$(basename "$stamp")" -delete 2>/dev/null || true
  for d in ledger compact sessions; do
    find "$JEV_HOME/$d" -maxdepth 1 -type f -mtime +"$RETAIN_DAYS" ! -name "$sid.*" -delete 2>/dev/null || true
  done
  find "$JEV_HOME/artifacts" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETAIN_DAYS" ! -name "$sid" -exec rm -rf {} + 2>/dev/null || true
  find "$LDIR" "$JEV_HOME/artifacts" -maxdepth 2 -name '.tmp.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  # logs over 5 MB keep their last 20,000 lines
  for lf in "$JEV_HOME"/log/*.jsonl; do
    [ -f "$lf" ] && [ "$(wc -c <"$lf" | tr -d ' ')" -gt 5242880 ] || continue
    tail -n 20000 "$lf" >"$lf.tmp" 2>/dev/null && mv "$lf.tmp" "$lf"
  done
  # re-tune from outcome.sh records when enough have arrived (autotune.sh decides; detached)
  if [ "${JEV_AUTOTUNE:-1}" != 0 ]; then
    if [ "${JEV_AUTOTUNE_SYNC:-0}" = 1 ]; then "$JEV_DIR/autotune.sh" >/dev/null 2>&1 || true
    else (nohup "$JEV_DIR/autotune.sh" >/dev/null 2>&1 &) ; fi
  fi
fi

facts="$LDIR/$sid.jsonl"
meta="$LDIR/$sid.meta.json"
[ -f "$meta" ] || echo '{}' >"$meta"
size=$(wc -c <"$tp" | tr -d ' ')
IFS=$'\t' read -r offset last_uuid next_id < <(jq -r '[.offset // "-", .last_uuid // "-", .next_id // 1] | @tsv' "$meta")

# Cursor: byte offset of the first unprocessed line, checked against the uuid
# of the last processed record. No cursor: start at the last compact boundary.
if [ "$offset" != - ] && [ "$offset" -le "$size" ] && [ "$last_uuid" != - ]; then
  w=$((offset > 4096 ? 4096 : offset))
  { tail -c +$((offset - w + 1)) "$tp" | head -c "$w" >"$tmpd/before"; } 2>/dev/null || true
  if ! grep -qF "\"uuid\":\"$last_uuid\"" "$tmpd/before"; then
    # The file changed under us: find the record again, else start over.
    hit=$(grep -bF "\"uuid\":\"$last_uuid\"" "$tp" | tail -n 1 | cut -d: -f1 || true)
    if [ -n "$hit" ]; then
      { tail -c +$((hit + 1)) "$tp" | head -n 1 >"$tmpd/line"; } 2>/dev/null || true
      offset=$((hit + $(wc -c <"$tmpd/line")))
    else offset=-; fi
  fi
else
  [ "$offset" != - ] && [ "$offset" -le "$size" ] || offset=-
fi
first=false
if [ "$offset" = - ]; then
  first=true
  offset=$(grep -b '"subtype":"compact_boundary"' "$tp" | tail -n 1 | cut -d: -f1 || true)
  offset=${offset:-0}
fi
[ "$offset" -lt "$size" ] || exit 0

# Complete lines after the cursor only: the transcript is written as we read.
tail -c +$((offset + 1)) "$tp" >"$tmpd/raw"
n=$(wc -c <"$tmpd/raw" | tr -d ' ')
if [ "$(tail -c 1 "$tmpd/raw" | od -An -c | tr -d ' ')" != '\n' ]; then
  n=$((n - $(tail -n 1 "$tmpd/raw" | wc -c | tr -d ' ')))
fi
[ "$n" -gt 0 ] || exit 0
head -c "$n" "$tmpd/raw" >"$tmpd/slice"
new_offset=$((offset + n))
new_uuid=$(grep -o '"uuid":"[^"]*"' "$tmpd/slice" | tail -n 1 | cut -d'"' -f4 || true)
new_uuid=${new_uuid:-$last_uuid}

save_meta() { # <status> [next_id]
  jq -c --argjson o "$new_offset" --arg u "$new_uuid" --arg tp "$tp" --arg at "$(jev_now)" --arg st "$1" \
    --argjson next "${2:-$next_id}" \
    '. + {offset: $o, last_uuid: (if $u == "-" then null else $u end), transcript_path: $tp,
          next_id: $next, updated_at: $at, last_status: $st, runs: ((.runs // 0) + 1)}' "$meta" >"$meta.tmp" &&
    mv "$meta.tmp" "$meta"
}

jq -cR -f "$JEV_DIR/slim.jq" "$tmpd/slice" |
  jq -s -c --argjson max "$MAX_FACTS" --argjson tail_chars "$TAIL_CHARS" --argjson ledger true \
    --argjson carried "$first" -f "$JEV_DIR/extract.jq" >"$tmpd/ex.json" 2>/dev/null || {
  save_meta extract_failed
  exit 0
}
[ -f "$facts" ] || : >"$facts"
# New candidates only, renumbered. A text that is already a LIVE fact is
# skipped; one that was superseded is a candidate again (A, B, A restores A).
# Open items whose normalised text matches a live fact or another candidate
# (the same item as a user line, an "Open item:" line and a checkbox) are dropped.
jq -c --slurpfile f "$facts" '
  def norm: ascii_downcase | gsub("^(user said: |open item: |carried: )+"; "")
    | gsub("^(- \\[ \\] |\\[ \\] |remaining: |todo:? |next:? )+"; "") | gsub("[^a-z0-9]+"; " ") | gsub("^ | $"; "");
  [$f[] | select(.superseded_by == null)] as $live
  | ($f | map({key: .id, value: .}) | from_entries) as $byid
  # the live end of a supersession chain: A -> B -> C gives C
  | def live_end($id; $n): ($byid[$id] // null) as $x
      | if $x == null or $n > 50 then null elif $x.superseded_by == null then $id else live_end($x.superseded_by; $n + 1) end;
  ([$f[] | select(.superseded_by != null) | {k: (.text | norm), id, score}] | group_by(.k) | map({key: .[0].k, value: last}) | from_entries) as $dead
  | ([$live[] | .text]) as $known
  | ([$live[] | .text | norm]) as $known_norm
  | [.facts[] | select(.text as $t | $known | index($t) | not)] as $c0
  | ([$c0[] | select(.kind != "todo") | .text | norm]) as $stmt_norm
  | (reduce $c0[] as $x ([];
       if $x.kind == "todo" and (($x.text | norm) as $k | ($known_norm | index($k)) or ($stmt_norm | index($k)) or (map(select(.kind == "todo") | .text | norm) | index($k)))
       then . else . + [$x] end)) as $cands
  # A statement that comes back after it was superseded restores it: kept whatever
  # Jev scores it, at the score of the old fact, and it retires what had replaced it.
  | ($cands | map(. as $c | ($dead[$c.text | norm] // null) as $d
      | if $d == null then . else . + {restores: $d.id, restore_score: $d.score,
          restore_targets: ([live_end($d.id; 0)] | map(select(. != null and . != $d.id)))} end)) as $cands
  | {cands: ($cands | to_entries | map(.value + {n: (.key + 1)})), live: $live, tail}' "$tmpd/ex.json" >"$tmpd/in.json"
nc=$(jq '.cands | length' "$tmpd/in.json")
if [ "$nc" -eq 0 ]; then
  save_meta no_candidates
  jev_log ledger.jsonl "$(jq -cn --argjson b "$n" --arg first "$first" '{event: "step", status: "no_candidates", slice_bytes: $b, first_run: ($first == "true")}')"
  exit 0
fi

budget=$(jev_state_budget_chars 1500)
used=$(jq '[.cands[].text, .live[-40:][].text | length + 8] | add // 0' "$tmpd/in.json")
tail_max=$((budget - used))
[ "$tail_max" -lt "$TAIL_CHARS" ] || tail_max=$TAIL_CHARS
[ "$tail_max" -gt 0 ] || tail_max=0
jq -c --arg model "$JEV_MODEL" --argjson tail_max "$tail_max" --argjson per_req "$PER_REQ" \
  --argjson max_pairs "$MAX_PAIRS" --argjson per_kind 20 -f "$JEV_DIR/ledger-req.jq" "$tmpd/in.json" >"$tmpd/reqs.json"
nreq=$(jq length "$tmpd/reqs.json")
nq=$(jq '[.[].questions | length] | add' "$tmpd/reqs.json")

i=0
while [ "$i" -lt "$nreq" ]; do
  { jq -c ".[$i]" "$tmpd/reqs.json" | JEV_TIMEOUT=${JEV_LEDGER_TIMEOUT:-6} jev_call >"$tmpd/resp-$i.json" || : >"$tmpd/resp-$i.json"; } &
  i=$((i + 1))
done
wait

answers=$(cat "$tmpd"/resp-*.json | jq -s -c 'if length == 0 then null else (map(.answers) | add) end' 2>/dev/null || echo null)
if [ "$answers" = null ] || ! jq -e --slurpfile q "$tmpd/reqs.json" '. as $a | [$q[0][].questions | keys[]] | all(. as $k | $a | has($k))' <<<"$answers" >/dev/null 2>&1; then
  # Cursor stays put: the next turn (or the compaction flush) retries this slice.
  jev_log ledger.jsonl "$(jq -cn --argjson c "$nc" --argjson b "$n" '{event: "step", status: "jev_failed", candidates: $c, slice_bytes: $b}')"
  exit 0
fi

# Decide, number and write. Targets: ledger facts by id, or earlier candidates
# of this slice (if they are kept themselves). P(fully) >= SUP_MIN supersedes;
# P(partly) + P(fully) >= SUP_MIN corrects.
jq -c --argjson a "$answers" --argjson min "$MIN_SCORE" --argjson sup "$SUP_MIN" --argjson next "$next_id" \
  --arg ts "$(jev_now)" '
  .live as $live
  | [.cands[] | . as $c
     # A pull request link is how the session finds its own work again: never below important.
     | ($a["s\(.n)"].score // 0 | if $c.kind == "url" and ($c.text | startswith("Pull request:")) then ([., $min] | max) else . end) as $score
     | [$a | to_entries[] | select(.key | startswith("x\($c.n)_")) | {t: (.key | sub("^x[0-9]+_"; "")), p: (.value.probabilities // {})}] as $pairs
     | (([$pairs[] | select((.p.fully // 0) >= $sup) | .t]) + ($c.restore_targets // []) | unique) as $sup_t
     | ([$pairs[] | select((.p.fully // 0) < $sup and ((.p.fully // 0) + (.p.partly // 0)) >= $sup) | .t] - $sup_t) as $cor_t
     | ([$sup_t[] | select(startswith("f")) as $t | $live[] | select(.id == $t) | .score] | max // 0) as $full_score
     | ([$cor_t[] | select(startswith("f")) as $t | $live[] | select(.id == $t) | .score] | max // 0) as $part_score
     | (if $c.restores then ([$score, $c.restore_score // 0] | max) else $score end) as $score
     | {n, kind, text, src, score: ($score * 100 | round / 100), sup_t: $sup_t, cor_t: $cor_t, restores: ($c.restores // null),
        # carried: re-injected by an earlier compaction, so already judged important;
        # restores: a superseded statement made again; a full replacement of an important
        # fact is itself important whatever its own score; a partial one needs some weight
        keep: ($score >= $min or $c.kind == "carried" or $c.restores != null or $full_score >= $min
               or ($part_score >= $min and $score >= 0.75))}]
  | [.[] | select(.keep)] as $kept
  | ($kept | to_entries | map({key: "c\(.value.n)", value: "f\($next + .key)"}) | from_entries) as $cid
  | [$kept[] | {id: $cid["c\(.n)"], ts: $ts, kind, text,
                score: (if .score < $min then $min else .score end),
                supersedes: [.sup_t[] | if startswith("c") then ($cid[.] // empty) else . end],
                corrects: [.cor_t[] | if startswith("c") then ($cid[.] // empty) else . end],
                superseded_by: null, corrected_by: [], source_uuid: .src}
              + (if .restores then {restores: .restores} else {} end)] as $new
  | {new: $new, marks: ([$new[] | .id as $by | .supersedes[] | {key: ., value: $by}] | from_entries),
     cmarks: ([$new[] | .id as $by | .corrects[] | {k: ., v: $by}] | group_by(.k) | map({key: .[0].k, value: map(.v)}) | from_entries),
     scored: length, next: ($next + ($new | length))}' "$tmpd/in.json" >"$tmpd/decided.json"

# shellcheck disable=SC2016 # a jq program, expanded by jq
mark='.superseded_by = (if .superseded_by == null then ($d.marks[.id] // null) else .superseded_by end)
  | .corrected_by = ((.corrected_by // []) + ($d.cmarks[.id] // []))'
jq -c --slurpfile dd "$tmpd/decided.json" "\$dd[0] as \$d | $mark" "$facts" >"$tmpd/facts.jsonl"
# New facts can themselves be superseded or corrected by later ones from the same slice.
jq -c ". as \$d | .new[] | $mark" "$tmpd/decided.json" >>"$tmpd/facts.jsonl"
# Superseded facts older than 7 days leave the live file for the archive.
jq -c '(now - 7 * 86400 | todate) as $cut | select(.superseded_by != null and .ts < $cut)' "$tmpd/facts.jsonl" >>"$LDIR/$sid.archive.jsonl" 2>/dev/null || true
[ -s "$LDIR/$sid.archive.jsonl" ] || rm -f "$LDIR/$sid.archive.jsonl"
jq -c '(now - 7 * 86400 | todate) as $cut | select((.superseded_by != null and .ts < $cut) | not)' "$tmpd/facts.jsonl" >"$tmpd/facts.live.jsonl"
mv "$tmpd/facts.live.jsonl" "$facts"
next_new=$(jq -r .next "$tmpd/decided.json")
save_meta ok "$next_new"
jev_log ledger.jsonl "$(jq -c --argjson b "$n" --arg first "$first" --argjson nreq "$nreq" --argjson nq "$nq" '{event: "step", status: "ok",
  slice_bytes: $b, first_run: ($first == "true"), requests: $nreq, questions: $nq, candidates: .scored,
  appended: (.new | length), superseded: (.marks | length), corrected: (.cmarks | length), kinds: [.new[].kind]}' "$tmpd/decided.json")"
