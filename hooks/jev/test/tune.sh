#!/usr/bin/env bash
# tune.sh — sweep route.sh's policy thresholds over saved Jev answers (no API calls).
#
#   tune.sh [results.jsonl]      default: the newest $JEV_EVAL_DIR/results-*.jsonl (written by
#                                route-eval.sh on the real set; EVAL_RUNS=3 pools 3 samples per task)
#
# Inputs:
#   - eval rows: {id (the task), label, probabilities, confidence, signals, anchored} per task and run
#   - outcomes, when present: route.jsonl lines {action: "route", id, ...} joined
#     with {action: "outcome", id, escalated, verdict, final_model} from outcome.sh.
#     A route that was escalated or failed review says "at least one tier above
#     what was routed"; one that passed first time says "this tier was enough".
#
# The security/blast-radius and non-trivial-review gate is a design choice, not
# tuned: JEV_TUNE_SIGNAL (0.7, route.sh's JEV_ROUTE_SIGNAL_MIN) stays fixed. Swept:
# P(haiku), mechanical and ambiguity for haiku; P(opus) and confidence for sonnet.
#
# For every combination it counts, on the base-tier rule of policy.jq (context
# floors do not apply to these rows):
#   under_opus     opus-labelled rows routed lower          (must be 0)
#   under_sonnet   sonnet-labelled rows routed to haiku     (must be <= 2%)
#   over           rows routed above their label            (minimised)
# Under-routing is counted with every Jev value moved JEV_TUNE_MARGIN (0.1)
# toward the cheaper tier, so the chosen point is not balanced on a knife edge
# of a nondeterministic model. Over-routing is counted at the nominal values.
# Chosen: constraints met, fewest under-routed, then fewest over-routed.
#
# JEV_TUNE_SPLIT=1 adds a two-fold holdout split BY TASK (every run of a task on
# the same side): tune on one half, score the other half nominally and at the
# margin, both ways round. The shipped point is the per-threshold conservative
# combination of the two folds (higher P(haiku), mechanical and confidence bars,
# lower ambiguity and P(opus) bars), scored on the full set and on the
# unanchored subset (briefs that name no tier).
#
# JEV_TUNE_JSON=<file> also writes the chosen thresholds (the conservative
# combination with JEV_TUNE_SPLIT=1) as JSON; autotune.sh uses this.
set -euo pipefail
export JEV_MIGRATE=0 # tests never move this machine's real ~/.claude/jev
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
EVAL_DIR=${JEV_EVAL_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jev/eval}
# not migrated yet (the hooks move ~/.local/state/jev on their first run): read the old place
[ -n "${JEV_EVAL_DIR:-}" ] || [ -d "$EVAL_DIR" ] || [ ! -d "$HOME/.claude/jev/eval" ] || EVAL_DIR=$HOME/.claude/jev/eval
# shellcheck disable=SC2012 # timestamped names; newest by name
RES=${1:-$(ls "$EVAL_DIR"/results-*.jsonl 2>/dev/null | sort | tail -n 1)}
ROUTE_LOG=${JEV_TUNE_ROUTE_LOG:-${JEV_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/jev}/log/route.jsonl}
MARGIN=${JEV_TUNE_MARGIN:-0.1}
SIG=${JEV_TUNE_SIGNAL:-0.7}
MAX_SU=${EVAL_MAX_SONNET_UNDER:-0.02}
[ -n "$RES" ] && [ -f "$RES" ] || {
  echo "tune.sh: no results file (run route-eval.sh on the real set first, or pass one)" >&2
  exit 2
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jev-tune.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# rows <results.jsonl> -> TSV: kind lo hi ph po conf mech amb sec rev
#   eval:    lo = hi = label rank
#   outcome: escalated/failed -> lo = routed + 1, hi = 2; passed -> lo = 0, hi = routed
rows() {
  jq -r 'select(.model != "FAIL" and .probabilities != null)
    | ({haiku: 0, sonnet: 1, opus: 2}[.label]) as $l
    | ["eval", $l, $l, .probabilities.haiku, .probabilities.opus, .confidence, .signals.mechanical,
       .signals.ambiguous, .signals.security_or_high_blast_radius, .signals.review_of_nontrivial_diff] | @tsv' "$1"
  if [ "${2:-}" != no-outcomes ] && [ -f "$ROUTE_LOG" ]; then
    jq -s -r '
      (map(select(.action == "outcome")) | map({key: .id, value: .}) | from_entries) as $o
      | .[] | select(.action == "route" and $o[.id] != null and .probabilities != null) | $o[.id] as $x
      | ({haiku: 0, sonnet: 1, opus: 2}[.model]) as $m
      | ((($x.escalated // false) == true) or (($x.verdict // "") | test("fail|wrong|thin|redo"; "i"))) as $bad
      | ["outcome", (if $bad then [$m + 1, 2] | min else 0 end), (if $bad then 2 else $m end),
         .probabilities.haiku, .probabilities.opus, .confidence, .signals.mechanical, .signals.ambiguous,
         .signals.security_or_high_blast_radius, .signals.review_of_nontrivial_diff] | @tsv' "$ROUTE_LOG" 2>/dev/null || true
  fi
}

# sweep <rows.tsv> -> grid TSV: under_opus under_sonnet under_total over correct hp hm ha sp sc
sweep() {
  awk -F'\t' -v margin="$MARGIN" -v sg="$SIG" '
    function tier(ph, po, conf, mech, amb, sec, rev, hp, hm, ha, sp, sc) {
      if (ph >= hp && mech >= hm && amb <= ha && sec < sg && rev < sg) return 0
      if (po <= sp && conf >= sc && sec < sg && rev < sg) return 1
      return 2
    }
    { k[NR] = $1; lo[NR] = $2; hi[NR] = $3; ph[NR] = $4; po[NR] = $5; cf[NR] = $6; me[NR] = $7; am[NR] = $8; se[NR] = $9; rv[NR] = $10 }
    END {
      nhp = split("0.4 0.5 0.55 0.6 0.7 0.8 0.9", HP, " ")
      nhm = split("0 0.3 0.5 0.7", HM, " ")
      nha = split("0.5 0.7 0.9 1.01", HA, " ")
      nsp = split("0.1 0.15 0.2 0.25 0.3 0.35 0.4 0.45 0.5 0.6", SP, " ")
      nsc = split("0 0.5 0.6 0.7", SC, " ")
      for (a = 1; a <= nhp; a++) for (b = 1; b <= nhm; b++) for (c = 1; c <= nha; c++)
      for (d = 1; d <= nsp; d++) for (e = 1; e <= nsc; e++) {
        uo = 0; us = 0; ut = 0; ov = 0; ok = 0
        for (i = 1; i <= NR; i++) {
          t = tier(ph[i], po[i], cf[i], me[i], am[i], se[i], rv[i], HP[a], HM[b], HA[c], SP[d], SC[e])
          tm = tier(ph[i] + margin, po[i] - margin, cf[i] + margin, me[i] + margin, am[i] - margin, se[i] - margin, rv[i] - margin,
                    HP[a], HM[b], HA[c], SP[d], SC[e])
          if (tm < lo[i]) { ut++; if (k[i] == "eval" && lo[i] == 2) uo++; if (k[i] == "eval" && lo[i] == 1) us++ }
          if (t > hi[i]) ov++
          if (k[i] == "eval" && t == lo[i]) ok++
        }
        printf "%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", uo, us, ut, ov, ok, HP[a], HM[b], HA[c], SP[d], SC[e]
      }
    }' "$1"
}

# choose <grid.tsv> <n-sonnet-rows> -> the chosen grid line (empty if none meets the constraints).
# Ties go to the safer setting: higher haiku bars, lower P(opus) bar, higher confidence bar.
choose() {
  awk -F'\t' -v ns="$2" -v m="$MAX_SU" '$1 == 0 && (ns == 0 || $2 / ns <= m)' "$1" |
    sort -t$'\t' -k3,3n -k4,4n -k6,6nr -k7,7nr -k8,8n -k9,9n -k10,10nr | sed -n 1p
}
thresholds() { # <grid line> -> policy.jq thresholds JSON
  IFS=$'\t' read -r _ _ _ _ _ hp hm ha sp sc <<<"$1"
  echo "{\"haiku_p\":$hp,\"haiku_mech\":$hm,\"haiku_amb\":$ha,\"sonnet_popus\":$sp,\"sonnet_conf\":$sc,\"sec\":$SIG,\"review\":$SIG}"
}
knobs() { # <thresholds JSON> -> env-var line
  jq -r '"JEV_ROUTE_HAIKU_P=\(.haiku_p) JEV_ROUTE_HAIKU_MECH=\(.haiku_mech) JEV_ROUTE_HAIKU_AMB=\(.haiku_amb) JEV_ROUTE_SONNET_POPUS=\(.sonnet_popus) JEV_ROUTE_SONNET_CONF=\(.sonnet_conf) JEV_ROUTE_SIGNAL_MIN=\(.sec) (fixed)"' <<<"$1"
}
# score <results.jsonl> <thresholds JSON> <margin> -> eval-report.jq output, the
# Jev values moved <margin> toward the cheaper tier first (0 = nominal)
score() {
  jq -s -L "$J" --argjson t "$2" --argjson m "$3" '
    include "policy";
    def c: if . < 0 then 0 elif . > 1 then 1 else . end;
    map(select(.model != "FAIL" and .probabilities != null)
        | . + {probabilities: (.probabilities | .haiku = ((.haiku + $m) | c) | .opus = ((.opus - $m) | c)),
               confidence: ((.confidence + $m) | c),
               signals: (.signals | .mechanical = ((.mechanical + $m) | c) | .ambiguous = ((.ambiguous - $m) | c)
                         | .security_or_high_blast_radius = ((.security_or_high_blast_radius - $m) | c)
                         | .review_of_nontrivial_diff = ((.review_of_nontrivial_diff - $m) | c))}
        | . + {model: (route_policy($t) | .model)})' "$1" | jq -r -f "$HERE/eval-report.jq"
}
nsonnet() { awk -F'\t' '$1 == "eval" && $2 == 1' "$1" | wc -l | tr -d ' '; }

rows "$RES" >"$tmp/rows.tsv"
nrows=$(wc -l <"$tmp/rows.tsv" | tr -d ' ')
ntasks=$(jq -r '.id' "$RES" | sort -u | wc -l | tr -d ' ')
echo "rows: $(grep -c '^eval' "$tmp/rows.tsv") eval rows over $ntasks tasks (from $(basename "$RES")), $(grep -c '^outcome' "$tmp/rows.tsv" || true) outcome"
echo "security/blast-radius and non-trivial-review gate fixed at $SIG (design choice); margin $MARGIN; constraint: under_opus = 0, under_sonnet <= $MAX_SU"
sweep "$tmp/rows.tsv" >"$tmp/grid.tsv"
echo "grid points: $(wc -l <"$tmp/grid.tsv" | tr -d ' ')"
echo
echo "Pareto set over (under-routed at the margin, over-routed); best two per under-routing level:"
printf '%-6s %-7s %-6s %-6s %-6s | %-6s %-6s %-6s %-6s %-6s\n' under u_opus u_son over acc haikuP mech amb popus conf
sort -t$'\t' -k3,3n -k4,4n -k2,2n "$tmp/grid.tsv" | awk -F'\t' -v n="$nrows" '
  BEGIN { best = 1e9 }
  { if ($4 < best) { best = $4; shown = 0 } if ($4 == best && shown < 2) { shown++; printf "%-6d %-7d %-6d %-6d %-6.3f | %-6s %-6s %-6s %-6s %-6s\n", $3, $1, $2, $4, $5 / n, $6, $7, $8, $9, $10 } }'

chosen=$(choose "$tmp/grid.tsv" "$(nsonnet "$tmp/rows.tsv")")
[ -n "$chosen" ] || {
  echo "no grid point meets the constraints"
  exit 1
}
t_full=$(thresholds "$chosen")
echo
echo "chosen on the full set: $(knobs "$t_full")"
echo "        under (at margin $MARGIN): opus $(cut -f1 <<<"$chosen"), sonnet $(cut -f2 <<<"$chosen"), total $(cut -f3 <<<"$chosen"); over $(cut -f4 <<<"$chosen") of $nrows"

if [ "${JEV_TUNE_SPLIT:-0}" != 1 ]; then
  [ -z "${JEV_TUNE_JSON:-}" ] || printf '%s\n' "$t_full" >"$JEV_TUNE_JSON"
  echo
  echo "policy.jq at that point, nominal values:"
  score "$RES" "$t_full" 0
  exit 0
fi

# --- two-fold holdout, split by task: ids are "t" + md5 hex, the last digit's parity picks the fold
folds=()
for fold in 0 1; do
  jq -c --argjson f "$fold" 'select(((.id[-1:] | explode[0]) % 2) == $f)' "$RES" >"$tmp/train$fold.jsonl"
  jq -c --argjson f "$fold" 'select(((.id[-1:] | explode[0]) % 2) != $f)' "$RES" >"$tmp/test$fold.jsonl"
  rows "$tmp/train$fold.jsonl" no-outcomes >"$tmp/trainrows$fold.tsv"
  sweep "$tmp/trainrows$fold.tsv" >"$tmp/grid$fold.tsv"
  c=$(choose "$tmp/grid$fold.tsv" "$(nsonnet "$tmp/trainrows$fold.tsv")")
  echo
  echo "=== holdout fold $fold (by task): tuned on $(jq -r .id "$tmp/train$fold.jsonl" | sort -u | wc -l | tr -d ' ') tasks / $(wc -l <"$tmp/train$fold.jsonl" | tr -d ' ') rows, tested on $(jq -r .id "$tmp/test$fold.jsonl" | sort -u | wc -l | tr -d ' ') tasks / $(wc -l <"$tmp/test$fold.jsonl" | tr -d ' ') rows"
  if [ -z "$c" ]; then
    echo "no grid point meets the constraints on this training half"
    continue
  fi
  t=$(thresholds "$c")
  folds+=("$t")
  echo "fold $fold chose: $(knobs "$t")"
  echo "  test half, nominal:"
  score "$tmp/test$fold.jsonl" "$t" 0 | grep -E '^(N=|under-routed|over-routed|unanchored)' | sed 's/^/    /'
  echo "  test half, Jev values moved $MARGIN toward the cheaper tier:"
  score "$tmp/test$fold.jsonl" "$t" "$MARGIN" | grep -E '^(N=|under-routed)' | sed 's/^/    /'
done
[ "${#folds[@]}" = 2 ] || exit 1

# --- ship the per-threshold conservative combination of the two folds
t_ship=$(jq -s -c '{haiku_p: (map(.haiku_p) | max), haiku_mech: (map(.haiku_mech) | max), haiku_amb: (map(.haiku_amb) | min),
  sonnet_popus: (map(.sonnet_popus) | min), sonnet_conf: (map(.sonnet_conf) | max), sec: .[0].sec, review: .[0].review}' <<<"${folds[0]} ${folds[1]}")
[ -z "${JEV_TUNE_JSON:-}" ] || printf '%s\n' "$t_ship" >"$JEV_TUNE_JSON"
echo
echo "=== shipped: the conservative combination of the two folds"
knobs "$t_ship"
echo "  full set, nominal:"
score "$RES" "$t_ship" 0 | sed 's/^/    /'
echo "  full set, Jev values moved $MARGIN toward the cheaper tier:"
score "$RES" "$t_ship" "$MARGIN" | grep -E '^(N=|under-routed|unanchored)' | sed 's/^/    /'
for fold in 0 1; do
  echo "  fold $fold test half with the shipped point: nominal / at the margin:"
  score "$tmp/test$fold.jsonl" "$t_ship" 0 | grep -E '^under-routed' | sed 's/^/    nominal: /'
  score "$tmp/test$fold.jsonl" "$t_ship" "$MARGIN" | grep -E '^under-routed' | sed 's/^/    margin:  /'
done
