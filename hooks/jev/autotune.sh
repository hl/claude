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
#       (briefs that name no tier), and
#   (b) every threshold it changes moves the conservative way or not at all:
#       P(haiku) bar, mechanical bar and confidence bar up; ambiguity bar and
#       P(opus) bar down.
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

# current thresholds: the tuned file if any, else route.sh's defaults
cur=$(jq -cn --slurpfile f <(cat "$TD/thresholds.json" 2>/dev/null || echo '{}') '
  {haiku_p: 0.6, haiku_mech: 0, haiku_amb: 0.9, sonnet_popus: 0.35, sonnet_conf: 0}
  + ($f[0] // {} | {haiku_p, haiku_mech, haiku_amb, sonnet_popus, sonnet_conf} | with_entries(select(.value | type == "number")))')
new=$(jq -c '{haiku_p, haiku_mech, haiku_amb, sonnet_popus, sonnet_conf}' "$tmp/new.json")

# (a) zero under-routing on the full set and the unanchored subset, at the new point
under=$(jq -s -c -L "$JEV_DIR" --argjson t "$(jq -c '. + {sec: 0.7, review: 0.7}' <<<"$new")" '
  include "policy";
  def rank: {haiku: 0, sonnet: 1, opus: 2}[.];
  [.[] | select(.model != "FAIL" and .probabilities != null)
   | . + {routed: (route_policy($t) | .model)} | select((.routed | rank) < (.label | rank))]
  | {all: length, unanchored: (map(select(.anchored == false)) | length)}' "$res")
# (b) every change conservative
dirs=$(jq -cn --argjson c "$cur" --argjson n "$new" '
  [ {k: "haiku_p", up: true}, {k: "haiku_mech", up: true}, {k: "sonnet_conf", up: true},
    {k: "haiku_amb", up: false}, {k: "sonnet_popus", up: false} ]
  | map(. as $x | {k: $x.k, from: $c[$x.k], to: $n[$x.k],
        ok: (if $x.up then $n[$x.k] >= $c[$x.k] else $n[$x.k] <= $c[$x.k] end)})')
safe=$(jq -n --argjson u "$under" --argjson d "$dirs" '$u.all == 0 and $u.unanchored == 0 and all($d[]; .ok)')
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
