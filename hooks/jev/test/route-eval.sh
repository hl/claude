#!/usr/bin/env bash
# route-eval.sh — labelled eval for route.sh (needs a Jev key; hits the live API).
#
# Asserts accuracy >= EVAL_MIN_ACC (0.80) and zero under-routing of opus-labelled
# tasks, and prints a confusion table. EVAL_RUNS=N repeats the set N times
# (Jev is slightly nondeterministic); the assertions apply to every run pooled.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROUTE="$HERE/../route.sh"
FIX=${EVAL_FIXTURE:-$HERE/fixtures/route-eval.jsonl}
RUNS=${EVAL_RUNS:-1}
MIN_ACC=${EVAL_MIN_ACC:-0.80}
out=$(mktemp -d "${TMPDIR:-/tmp}/jev-eval.XXXXXX")
export JEV_HOME="$out/home"

run_one() { # <run> <line-no>
  local line id label task res
  line=$(sed -n "${2}p" "$FIX")
  id=$(jq -r .id <<<"$line")
  label=$(jq -r .label <<<"$line")
  task=$(jq -r .task <<<"$line")
  if res=$("$ROUTE" "$task" 2>/dev/null); then
    jq -c --arg id "$id" --arg label "$label" --arg run "$1" '{run: $run, id: $id, label: $label} + .' <<<"$res"
  else
    jq -cn --arg id "$id" --arg label "$label" --arg run "$1" '{run: $run, id: $id, label: $label, model: "FAIL"}'
  fi >"$out/$1-$id.json"
}

n=$(wc -l <"$FIX" | tr -d ' ')
pids=()
for r in $(seq 1 "$RUNS"); do
  for i in $(seq 1 "$n"); do
    run_one "$r" "$i" &
    pids+=($!)
    # A little concurrency, not a burst.
    if [ $((${#pids[@]} % 8)) -eq 0 ]; then wait; fi
  done
done
wait

cat "$out"/*.json | jq -s '.' >"$out/all.json"

printf '\n%-6s %-7s %-7s %5s  %-22s %s\n' id label routed conf policy "jev_choice / signals>=0.7"
jq -r 'sort_by(.id, .run)[] |
  [.id, .label, .model, ((.confidence // 0) | tostring), (.policy // "-"),
   ((.jev_choice // "-") + " / " + ((.signals // {}) | to_entries | map(select(.value >= 0.7) | .key) | join(",")))]
  | @tsv' "$out/all.json" | awk -F'\t' '{ printf "%-6s %-7s %-7s %5s  %-22s %s\n", $1, $2, $3, $4, $5, $6 }'

echo
echo "confusion (rows = label, cols = routed):"
jq -r '
  def tiers: ["haiku", "sonnet", "opus", "FAIL"];
  . as $all
  | (["label\\routed"] + tiers | @tsv),
    (["haiku", "sonnet", "opus"][] as $l
     | [$l] + [tiers[] as $m | [$all[] | select(.label == $l and .model == $m)] | length | tostring] | @tsv)
' "$out/all.json" | awk -F'\t' '{ printf "%-14s %7s %7s %7s %7s\n", $1, $2, $3, $4, $5 }'

read -r total correct under fails < <(jq -r '
  [length,
   (map(select(.label == .model)) | length),
   (map(select(.label == "opus" and (.model == "haiku" or .model == "sonnet"))) | length),
   (map(select(.model == "FAIL")) | length)] | @tsv' "$out/all.json")
acc=$(awk -v c="$correct" -v t="$total" 'BEGIN { printf "%.3f", c / t }')
over=$(jq '[.[] | select(.model != "FAIL") | select(({haiku:0,sonnet:1,opus:2}[.model]) > ({haiku:0,sonnet:1,opus:2}[.label]))] | length' "$out/all.json")
lat=$(jq -s 'map(select(.status == "ok") | .ms) | sort | {n: length, p50: .[(length / 2 | floor)], max: max}' "$JEV_HOME/log/jev.jsonl" 2>/dev/null || echo '{}')
echo
echo "runs=$RUNS cases=$total correct=$correct accuracy=$acc over_routed=$over under_routed_opus=$under failures=$fails"
echo "jev latency ms: $lat"
echo "results: $out/all.json"

rc=0
awk -v a="$acc" -v m="$MIN_ACC" 'BEGIN { exit !(a >= m) }' || {
  echo "FAIL: accuracy $acc < $MIN_ACC"
  rc=1
}
[ "$under" -eq 0 ] || {
  echo "FAIL: $under opus-labelled task(s) routed below opus"
  rc=1
}
[ "$fails" -eq 0 ] || {
  echo "FAIL: $fails route.sh call(s) failed"
  rc=1
}
[ "$rc" -eq 0 ] && echo "PASS: route eval"
exit "$rc"
