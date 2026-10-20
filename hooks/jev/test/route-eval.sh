#!/usr/bin/env bash
# route-eval.sh — labelled eval for route.sh (needs a Jev key; hits the live API).
#
#   route-eval.sh                                committed fixture (36 sanitised real tasks)
#   JEV_EVAL_SET=<labelled.jsonl> route-eval.sh  a local labelled set (never committed)
#
# Reports: accuracy, confusion table, under-routing per label, over-routing,
# and recall on the weak under_routed labels (tasks whose real run was redone
# or escalated: did route.sh pick a higher tier than the one that ran?).
# Asserts: zero under-routing of opus-labelled tasks, sonnet-labelled tasks
# under-routed <= EVAL_MAX_SONNET_UNDER (0.02), no route.sh failures.
# EVAL_RUNS=N repeats the set (Jev is slightly nondeterministic); assertions
# apply to all runs pooled. Raw results stay in a temp directory.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROUTE="$HERE/../route.sh"
if [ -n "${JEV_EVAL_SET:-}" ] && [ "$JEV_EVAL_SET" != none ]; then
  SET=$JEV_EVAL_SET
  real=true
else
  SET=${EVAL_FIXTURE:-$HERE/fixtures/route-eval-real.jsonl}
  real=false
fi
RUNS=${EVAL_RUNS:-1}
PAR=${EVAL_PARALLEL:-8}
MAX_SU=${EVAL_MAX_SONNET_UNDER:-0.02}
out=$(mktemp -d "${TMPDIR:-/tmp}/jev-eval.XXXXXX")
export JEV_HOME="$out/home" JEV_ROUTE_NO_LOG=1
echo "eval set: $([ "$real" = true ] && echo "local real set" || echo "committed fixture") ($(wc -l <"$SET" | tr -d ' ') tasks, $(basename "$SET")), runs=$RUNS"

# The text route.sh sees is what the Agent hook would send: description,
# subagent_type, prompt. Fixture lines may carry a ready-made .task instead.
# anchored: the brief names a tier ("Model: sonnet — ..."); route.sh strips those
# lines, but the blind labeller saw them, so the unanchored subset is reported apart.
jq -c -L "$HERE/.." 'include "anchors";
  {id, label, chosen_tier: (.chosen_tier // null), under_routed: (.under_routed // false), weak: (.weak // []),
        task: (.task // ([(.description // ""), (if (.subagent_type // "") != "" then "subagent_type: " + .subagent_type else empty end), (.prompt // "")]
                         | map(select(. != "")) | join("\n\n"))),
        context: (.context // null)}
  | . + {anchored: (.task | anchored)}' "$SET" >"$out/set.jsonl"

run_one() { # <run> <line-no>
  local line id res ctx
  line=$(sed -n "${2}p" "$out/set.jsonl")
  id=$(jq -r .id <<<"$line")
  ctx=$(jq -c '.context // {}' <<<"$line")
  if res=$(jq -r .task <<<"$line" | "$ROUTE" --context "$ctx" 2>/dev/null); then
    jq -c --argjson t "$line" --arg run "$1" '{run: $run} + del(.id) + {route_id: .id} + ($t | del(.task))' <<<"$res"
  else
    jq -c --argjson t "$line" --arg run "$1" '{run: $run} + ($t | del(.task)) + {model: "FAIL"}' <<<"{}"
  fi >"$out/$1-$id.json"
}

n=$(wc -l <"$out/set.jsonl" | tr -d ' ')
running=0
for r in $(seq 1 "$RUNS"); do
  for i in $(seq 1 "$n"); do
    run_one "$r" "$i" &
    running=$((running + 1))
    if [ "$running" -ge "$PAR" ]; then
      wait
      running=0
    fi
  done
done
wait

cat "$out"/[0-9]*-*.json | jq -s '.' >"$out/all.json"

if [ "${EVAL_VERBOSE:-0}" = 1 ] || [ "$real" = false ]; then
  printf '\n%-12s %-7s %-7s %5s  %s\n' id label routed conf policy
  jq -r 'sort_by(.id, .run)[] | [.id, .label, .model, ((.confidence // 0) | tostring), ((.policy // []) | join("; "))] | @tsv' "$out/all.json" |
    awk -F'\t' '{ printf "%-12s %-7s %-7s %5s  %s\n", $1, $2, $3, $4, substr($5, 1, 110) }'
fi

jq -r -f "$HERE/eval-report.jq" "$out/all.json"
read -r under_opus under_sonnet n_sonnet fails < <(jq -r '
  [(map(select(.label == "opus" and (.model == "haiku" or .model == "sonnet"))) | length),
   (map(select(.label == "sonnet" and .model == "haiku")) | length),
   (map(select(.label == "sonnet")) | length),
   (map(select(.model == "FAIL")) | length)] | @tsv' "$out/all.json")
lat=$(jq -s -c 'map(select(.status == "ok") | .ms) | sort | {n: length, p50: .[(length / 2 | floor)], p95: .[(length * 0.95 | floor)], max: max}' "$JEV_HOME/log/jev.jsonl" 2>/dev/null || echo '{}')
echo "jev latency ms: $lat"
echo "results: $out/all.json"

rc=0
[ "$under_opus" -eq 0 ] || {
  echo "FAIL: $under_opus opus-labelled task(s) routed below opus"
  rc=1
}
awk -v u="$under_sonnet" -v n="$n_sonnet" -v m="$MAX_SU" 'BEGIN { exit !(n == 0 || u / n <= m) }' || {
  echo "FAIL: $under_sonnet of $n_sonnet sonnet-labelled tasks routed to haiku (> $MAX_SU)"
  rc=1
}
[ "$fails" -eq 0 ] || {
  echo "FAIL: $fails route.sh call(s) failed"
  rc=1
}
[ "$rc" -eq 0 ] && echo "PASS: route eval"
exit "$rc"
