#!/usr/bin/env bash
# autotune.sh — re-tune route.sh's thresholds from outcome.sh records, safely.
#
#   autotune.sh [--force]        (ledger.sh starts it in the background from its daily sweep)
#
# Runs when at least JEV_AUTOTUNE_MIN (50) outcome records have arrived since the
# last run (--force skips that check). Tunes on the newest real eval results
# ($JEV_HOME/eval/results-*.jsonl) plus every outcome joined to its route call
# (test/tune.sh, two-fold task split, conservative combination). The result is
# APPLIED to $JEV_HOME/tune/thresholds.json, which route.sh reads, only if both:
#   (a) it under-routes nothing on the full real set and on its unanchored subset
#       (briefs that name no tier), both at the nominal Jev values and with every
#       value moved 0.1 toward the cheaper tier, and
#   (b) every threshold is a number and is the shipped default or stricter:
#       P(haiku), mechanical and confidence bars at or above the defaults;
#       ambiguity and P(opus) bars at or below them. The baseline is always the
#       shipped defaults, never the current file, so a loose file cannot drift
#       further (route.sh also clamps whatever the file says).
# Otherwise it writes $JEV_HOME/tune/proposal.json for a person to look at.
# Every apply, proposal or skip is logged to jev.jsonl. Never touches the
# security/review gate. Fails quietly: nothing changes unless all checks pass.
set -uo pipefail
JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=autotune
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MIN=${JEV_AUTOTUNE_MIN:-50}
TD="$JEV_HOME/tune"
mkdir -p "$TD" 2>/dev/null || exit 0
log() { jev_log jev.jsonl "$1"; }
jev_lock "$TD/.lock" 3600 || exit 0
trap 'jev_unlock "$TD/.lock"' EXIT

routelog="$JEV_HOME/log/route.jsonl"
outcomes=$(grep -c '"action":"outcome"' "$routelog" 2>/dev/null || true)
outcomes=${outcomes:-0}
seen=$(jq -r '.outcomes // 0' "$TD/last.json" 2>/dev/null || echo 0)
if [ "${1:-}" != --force ] && [ $((outcomes - seen)) -lt "$MIN" ]; then
  exit 0
fi
# shellcheck disable=SC2012 # timestamped names; newest by name
res=$(ls "$JEV_HOME"/eval/results-*.jsonl 2>/dev/null | sort | tail -n 1)
mark_seen() { jq -cn --argjson o "$outcomes" --arg at "$(jev_now)" --arg r "$1" '{outcomes: $o, at: $at, result: $r}' >"$TD/last.json"; }
if [ -z "$res" ]; then
  log "$(jq -cn --argjson o "$outcomes" '{status: "autotune_skipped", reason: "no real eval results in $JEV_HOME/eval", outcomes: $o}')"
  mark_seen skipped
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jev-autotune.XXXXXX")
trap 'rm -rf "$tmp"; jev_unlock "$TD/.lock"' EXIT
if ! JEV_TUNE_SPLIT=1 JEV_TUNE_JSON="$tmp/new.json" JEV_TUNE_ROUTE_LOG="$routelog" JEV_EVAL_DIR="$JEV_HOME/eval" \
  "$JEV_DIR/test/tune.sh" "$res" >"$tmp/tune.out" 2>&1 || [ ! -s "$tmp/new.json" ]; then
  log "$(jq -cn --argjson o "$outcomes" --arg tail "$(tail -n 3 "$tmp/tune.out" | tr '\n' ' ' | cut -c1-300)" '{status: "autotune_failed", outcomes: $o, tune: $tail}')"
  mark_seen failed
  exit 0
fi

# the baseline is the shipped defaults (route.sh's), not the current file
base='{"haiku_p":0.6,"haiku_mech":0,"haiku_amb":0.9,"sonnet_popus":0.35,"sonnet_conf":0}'
cur=$(jq -cn --argjson b "$base" --slurpfile f <(cat "$TD/thresholds.json" 2>/dev/null || echo '{}') '
  $b + ($f[0] // {} | if type == "object" then . else {} end
        | {haiku_p, haiku_mech, haiku_amb, sonnet_popus, sonnet_conf} | with_entries(select(.value | type == "number")))')
new=$(jq -c '{haiku_p, haiku_mech, haiku_amb, sonnet_popus, sonnet_conf}' "$tmp/new.json")

# (a) zero under-routing on the full set and the unanchored subset, at the new point,
#     nominal and with every Jev value moved 0.1 toward the cheaper tier
under=$(jq -s -c -L "$JEV_DIR" --argjson t "$(jq -c '. + {sec: 0.7, review: 0.7}' <<<"$new")" '
  include "policy";
  def rank: {haiku: 0, sonnet: 1, opus: 2}[.];
  def c: if . < 0 then 0 elif . > 1 then 1 else . end;
  def shifted($m): . + {probabilities: (.probabilities | .haiku = ((.haiku + $m) | c) | .opus = ((.opus - $m) | c)),
      confidence: ((.confidence + $m) | c),
      signals: (.signals | .mechanical = ((.mechanical + $m) | c) | .ambiguous = ((.ambiguous - $m) | c)
                | .security_or_high_blast_radius = ((.security_or_high_blast_radius - $m) | c)
                | .review_of_nontrivial_diff = ((.review_of_nontrivial_diff - $m) | c))};
  [.[] | select(.model != "FAIL" and .probabilities != null)] as $rows
  | def under($m): [$rows[] | shifted($m) | . + {routed: (route_policy($t) | .model)} | select((.routed | rank) < (.label | rank))];
  (under(0)) as $u0 | (under(0.1)) as $u1
  | {all: ($u0 | length), unanchored: ($u0 | map(select(.anchored == false)) | length),
     all_at_margin: ($u1 | length), unanchored_at_margin: ($u1 | map(select(.anchored == false)) | length)}' "$res")
# (b) every threshold a number, and the shipped default or stricter
dirs=$(jq -cn --argjson b "$base" --argjson c "$cur" --argjson n "$new" '
  [ {k: "haiku_p", up: true}, {k: "haiku_mech", up: true}, {k: "sonnet_conf", up: true},
    {k: "haiku_amb", up: false}, {k: "sonnet_popus", up: false} ]
  | map(. as $x | {k: $x.k, from: $c[$x.k], to: $n[$x.k], default: $b[$x.k],
        ok: (($n[$x.k] | type) == "number" and (if $x.up then $n[$x.k] >= $b[$x.k] else $n[$x.k] <= $b[$x.k] end))})')
safe=$(jq -n --argjson u "$under" --argjson d "$dirs" '[$u[]] | all(. == 0) and all($d[]; .ok)')
changed=$(jq -c '[.[] | select(.from != .to) | {k, from, to}]' <<<"$dirs")

entry=$(jq -cn --argjson n "$new" --argjson c "$cur" --argjson u "$under" --argjson ch "$changed" --argjson o "$outcomes" \
  --arg res "$(basename "$res")" --arg at "$(jev_now)" '{at: $at, thresholds: $n, previous: $c, changes: $ch,
  under_routed: $u, outcomes: $o, eval_results: $res}')
if [ "$safe" = true ]; then
  if [ "$changed" = "[]" ]; then
    log "$(jq -c '{status: "autotune_unchanged"} + .' <<<"$entry")"
  else
    # the thresholds at the top level (what route.sh reads), how they were chosen under provenance
    jq --argjson n "$new" '$n + {provenance: .}' <<<"$entry" >"$TD/thresholds.json.tmp" && mv "$TD/thresholds.json.tmp" "$TD/thresholds.json"
    log "$(jq -c '{status: "autotune_applied"} + .' <<<"$entry")"
  fi
  mark_seen applied
else
  jq --argjson d "$dirs" '. + {why_not_applied: {under_routed: .under_routed, not_conservative: [$d[] | select(.ok | not) | .k]}}' <<<"$entry" >"$TD/proposal.json"
  log "$(jq -c '{status: "autotune_proposal", file: "tune/proposal.json"} + .' <<<"$entry")"
  mark_seen proposal
fi
