#!/usr/bin/env bash
# tune.sh — sweep route.sh's policy thresholds over saved Jev answers (no API calls).
#
#   tune.sh [results.jsonl]      default $JEV_EVAL_DIR/results.jsonl (written by
#                                route-eval.sh on the real set; EVAL_RUNS=3 pools 3 samples per task)
#
# Inputs:
#   - eval rows: {label, probabilities, confidence, signals} per task and run
#   - outcomes, when present: route.jsonl lines {action: "route", id, ...} joined
#     with {action: "outcome", id, escalated, verdict, final_model} from outcome.sh.
#     A route that was escalated or failed review says "at least one tier above
#     what was routed"; one that passed first time says "this tier was enough".
#
# For every threshold combination it counts, on the base-tier rule of policy.jq
# (context floors do not apply to these rows):
#   under_opus     opus-labelled rows routed lower          (must be 0)
#   under_sonnet   sonnet-labelled rows routed to haiku     (must be <= 2%)
#   over           rows routed above their label            (minimised)
# Under-routing is counted with every Jev value moved JEV_TUNE_MARGIN (0.1)
# toward the cheaper tier, so the chosen point is not balanced on a knife edge
# of a nondeterministic model. Over-routing is counted at the nominal values.
#
# Prints the Pareto set (fewest under-routed first, then fewest over-routed) and
# the chosen point, then re-applies policy.jq (the real code) at that point.
#
# JEV_TUNE_SPLIT=1 adds a two-fold holdout check: tune on half the tasks (split
# by id), report the chosen point on the other half, and the other way round.
# Both runs of the same task stay in the same half.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
EVAL_DIR=${JEV_EVAL_DIR:-$HOME/.claude/jev/eval}
RES=${1:-$EVAL_DIR/results.jsonl}
ROUTE_LOG=${JEV_TUNE_ROUTE_LOG:-${JEV_HOME:-$HOME/.claude/jev}/log/route.jsonl}
MARGIN=${JEV_TUNE_MARGIN:-0.1}
MAX_SU=${EVAL_MAX_SONNET_UNDER:-0.02}
[ -f "$RES" ] || {
  echo "tune.sh: no results at $RES (run route-eval.sh on the real set first)" >&2
  exit 2
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jev-tune.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# rows: kind lo hi ph po conf mech amb sec rev
#   eval:    lo = hi = label rank
#   outcome: escalated/failed -> lo = routed + 1, hi = 2; passed -> lo = 0, hi = routed
jq -r 'select(.model != "FAIL" and .probabilities != null)
  | ({haiku: 0, sonnet: 1, opus: 2}[.label]) as $l
  | ["eval", $l, $l, .probabilities.haiku, .probabilities.opus, .confidence, .signals.mechanical,
     .signals.ambiguous, .signals.security_or_high_blast_radius, .signals.review_of_nontrivial_diff] | @tsv' "$RES" >"$tmp/rows.tsv"
n_out=0
if [ -f "$ROUTE_LOG" ]; then
  jq -s -r '
    (map(select(.action == "outcome")) | map({key: .id, value: .}) | from_entries) as $o
    | .[] | select(.action == "route" and $o[.id] != null and .probabilities != null) | . as $r | $o[.id] as $x
    | ({haiku: 0, sonnet: 1, opus: 2}[.model]) as $m
    | ((($x.escalated // false) == true) or (($x.verdict // "") | test("fail|wrong|thin|redo"; "i"))) as $bad
    | ["outcome", (if $bad then [$m + 1, 2] | min else 0 end), (if $bad then 2 else $m end),
       .probabilities.haiku, .probabilities.opus, .confidence, .signals.mechanical, .signals.ambiguous,
       .signals.security_or_high_blast_radius, .signals.review_of_nontrivial_diff] | @tsv' "$ROUTE_LOG" >>"$tmp/rows.tsv" 2>/dev/null || true
  n_out=$(grep -c '^outcome' "$tmp/rows.tsv" || true)
fi
echo "rows: $(grep -c '^eval' "$tmp/rows.tsv") eval (from $(basename "$RES")), $n_out outcome"

awk -F'\t' -v margin="$MARGIN" -v max_su="$MAX_SU" '
  function tier(ph, po, conf, mech, amb, sec, rev, hp, hm, ha, sp, sc, sg) {
    if (ph >= hp && mech >= hm && amb <= ha && sec < sg && rev < sg) return 0
    if (po <= sp && conf >= sc && sec < sg && rev < sg) return 1
    return 2
  }
  { k[NR] = $1; lo[NR] = $2; hi[NR] = $3; ph[NR] = $4; po[NR] = $5; cf[NR] = $6; me[NR] = $7; am[NR] = $8; se[NR] = $9; rv[NR] = $10
    if ($1 == "eval" && $2 == 1) nsonnet++ }
  END {
    nhp = split("0.4 0.5 0.6 0.7 0.8 0.85 0.9 0.95", HP, " ")
    nhm = split("0 0.3 0.5 0.7 0.8", HM, " ")
    nha = split("0.3 0.5 0.7 0.9 1.01", HA, " ")
    nsp = split("0.1 0.15 0.2 0.3 0.4 0.5 0.6 0.7 0.8", SP, " ")
    nsc = split("0 0.5 0.6 0.7 0.8", SC, " ")
    nsg = split("0.5 0.6 0.7 0.8 0.9 1.01", SG, " ")
    for (a = 1; a <= nhp; a++) for (b = 1; b <= nhm; b++) for (c = 1; c <= nha; c++)
    for (d = 1; d <= nsp; d++) for (e = 1; e <= nsc; e++) for (f = 1; f <= nsg; f++) {
      uo = 0; us = 0; ut = 0; ov = 0; ok = 0; n = 0
      for (i = 1; i <= NR; i++) {
        t = tier(ph[i], po[i], cf[i], me[i], am[i], se[i], rv[i], HP[a], HM[b], HA[c], SP[d], SC[e], SG[f])
        tm = tier(ph[i] + margin, po[i] - margin, cf[i] + margin, me[i] + margin, am[i] - margin, se[i] - margin, rv[i] - margin,
                  HP[a], HM[b], HA[c], SP[d], SC[e], SG[f])
        n++
        if (tm < lo[i]) { ut++; if (k[i] == "eval" && lo[i] == 2) uo++; if (k[i] == "eval" && lo[i] == 1) us++ }
        if (t > hi[i]) ov++
        if (k[i] == "eval" && t == lo[i]) ok++
      }
      printf "%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", uo, us, ut, ov, ok, HP[a], HM[b], HA[c], SP[d], SC[e], SG[f]
    }
  }' "$tmp/rows.tsv" >"$tmp/grid.tsv"

nrows=$(wc -l <"$tmp/rows.tsv" | tr -d ' ')
nsonnet=$(awk -F'\t' '$1 == "eval" && $2 == 1' "$tmp/rows.tsv" | wc -l | tr -d ' ')
echo "grid points: $(wc -l <"$tmp/grid.tsv" | tr -d ' '); margin $MARGIN; constraint: under_opus = 0, under_sonnet <= $MAX_SU of $nsonnet"
echo
echo "Pareto set over (under-routed, over-routed); best few per under-routing level:"
printf '%-6s %-7s %-6s %-6s %-6s | %-6s %-6s %-6s %-6s %-6s %-6s\n' under u_opus u_son over acc haikuP mech amb popus conf signal
# Sort by total under, then over; keep points not dominated on (under, over).
sort -t$'\t' -k3,3n -k4,4n -k2,2n "$tmp/grid.tsv" | awk -F'\t' -v n="$nrows" '
  BEGIN { best = 1e9 }
  { if ($4 < best) { best = $4; shown = 0 } if ($4 == best && shown < 2) { shown++; printf "%-6d %-7d %-6d %-6d %-6.3f | %-6s %-6s %-6s %-6s %-6s %-6s\n", $3, $1, $2, $4, $5 / n, $6, $7, $8, $9, $10, $11 } }' 

# Chosen: constraints met, fewest under-routed, then fewest over-routed; ties go
# to the safer setting
# (higher haiku bar, lower P(opus) bar, higher confidence bar, lower signal bar).
chosen=$(awk -F'\t' -v ns="$nsonnet" -v m="$MAX_SU" '$1 == 0 && (ns == 0 || $2 / ns <= m)' "$tmp/grid.tsv" |
  sort -t$'\t' -k3,3n -k4,4n -k6,6nr -k7,7nr -k8,8n -k9,9n -k10,10nr -k11,11n | sed -n 1p)
[ -n "$chosen" ] || {
  echo "no grid point meets the constraints"
  exit 1
}
IFS=$'\t' read -r uo us ut ov _ hp hm ha sp sc sg <<<"$chosen"
echo
echo "chosen: JEV_ROUTE_HAIKU_P=$hp JEV_ROUTE_HAIKU_MECH=$hm JEV_ROUTE_HAIKU_AMB=$ha JEV_ROUTE_SONNET_POPUS=$sp JEV_ROUTE_SONNET_CONF=$sc JEV_ROUTE_SIGNAL_MIN=$sg"
echo "        under (at margin $MARGIN): opus $uo, sonnet $us, total $ut; over $ov of $nrows"
echo
echo "policy.jq at the chosen point, nominal values (eval rows only):"
jq -s -L "$J" --argjson t "{\"haiku_p\":$hp,\"haiku_mech\":$hm,\"haiku_amb\":$ha,\"sonnet_popus\":$sp,\"sonnet_conf\":$sc,\"sec\":$sg,\"review\":$sg}" '
  include "policy";
  map(select(.model != "FAIL" and .probabilities != null) | . + {model: (route_policy($t) | .model)})' "$RES" |
  jq -r -f "$HERE/eval-report.jq"

if [ "${JEV_TUNE_SPLIT:-0}" = 1 ]; then
  for fold in 0 1; do
    # ids are md5-based ("t" + 10 hex chars): split on the parity of the last digit
    jq -c --argjson f "$fold" 'select(((.id[-1:] | explode[0]) % 2) == $f)' "$RES" >"$tmp/train.jsonl"
    jq -c --argjson f "$fold" 'select(((.id[-1:] | explode[0]) % 2) != $f)' "$RES" >"$tmp/test.jsonl"
    line=$(JEV_TUNE_SPLIT=0 JEV_TUNE_ROUTE_LOG=/dev/null "$0" "$tmp/train.jsonl" | grep '^chosen:') || {
      echo "fold $fold: no grid point meets the constraints on the training half"
      continue
    }
    t=$(tr ' ' '\n' <<<"${line#chosen: }" | jq -R -s -c '
      split("\n") | map(select(test("=")) | split("=") | {key: .[0], value: (.[1] | tonumber)}) | from_entries
      | {haiku_p: .JEV_ROUTE_HAIKU_P, haiku_mech: .JEV_ROUTE_HAIKU_MECH, haiku_amb: .JEV_ROUTE_HAIKU_AMB,
         sonnet_popus: .JEV_ROUTE_SONNET_POPUS, sonnet_conf: .JEV_ROUTE_SONNET_CONF,
         sec: .JEV_ROUTE_SIGNAL_MIN, review: .JEV_ROUTE_SIGNAL_MIN}')
    echo
    echo "=== holdout fold $fold: tuned on $(wc -l <"$tmp/train.jsonl" | tr -d ' ') rows, tested on $(wc -l <"$tmp/test.jsonl" | tr -d ' ') rows"
    echo "train $line"
    jq -s -L "$J" --argjson t "$t" 'include "policy";
      map(select(.model != "FAIL" and .probabilities != null) | . + {model: (route_policy($t) | .model)})' "$tmp/test.jsonl" |
      jq -r -f "$HERE/eval-report.jq" | grep -E '^(N=|under-routed|over-routed)'
  done
fi
