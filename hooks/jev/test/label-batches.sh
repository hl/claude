#!/usr/bin/env bash
# label-batches.sh — pick the tasks to label from harvest.jsonl and write them
# as batch files for one blind labelling agent, then (with --merge) join the
# labels back into labelled.jsonl.
#
#   label-batches.sh [per-tier-counts]   default "haiku=120 sonnet=130 opus=150 fable=20"
#   label-batches.sh --merge
#
# Sample: every task with a weak under_routed label, plus a per-tier sample
# (by the tier that ran, so lightly routed work is not drowned out by the many
# opus calls), chosen by id order (ids are md5-based, so this is a fixed
# pseudo-random draw). Batch files show description, subagent_type and the
# prompt (head 1600 + tail 400 chars), never the model that ran, so labels are
# blind to past choices. Everything stays under ~/.claude/jev/eval (JEV_EVAL_DIR).
set -euo pipefail
DIR=${JEV_EVAL_DIR:-$HOME/.claude/jev/eval}
H="$DIR/harvest.jsonl"
SIZE=${JEV_LABEL_BATCH:-40}

if [ "${1:-}" = --merge ]; then
  cat "$DIR"/labels/batch-*.jsonl | jq -s -c 'map({key: .id, value: .}) | from_entries' >"$DIR/labels.json"
  jq -c --slurpfile l "$DIR/labels.json" '
    select($l[0][.id]) | . + {label: $l[0][.id].tier, label_reason: $l[0][.id].reason}
    | select(.label | IN("haiku", "sonnet", "opus"))' "$H" >"$DIR/labelled.jsonl"
  jq -s -r '"labelled: \(length)  " + (group_by(.label) | map("\(.[0].label)=\(length)") | join(" "))' "$DIR/labelled.jsonl"
  exit 0
fi

counts=${1:-haiku=120 sonnet=130 opus=150 fable=20}
quota=$(for c in $counts; do printf '{"%s":%s}' "${c%%=*}" "${c#*=}"; done | jq -s -c add)
mkdir -p "$DIR/batches" "$DIR/labels"
rm -f "$DIR"/batches/batch-*.md
jq -s -c --argjson q "$quota" '
  sort_by(.id)
  | ([.[] | select(.under_routed)]) as $weak
  | ([group_by(.chosen_tier)[] | .[0].chosen_tier as $t | [.[] | select(.under_routed | not)] | .[0:($q[$t // ""] // 0)][]]) as $rest
  | ($weak + $rest) | sort_by(.id)[]' "$H" >"$DIR/sample.jsonl"
total=$(wc -l <"$DIR/sample.jsonl" | tr -d ' ')
split -l "$SIZE" -a 2 "$DIR/sample.jsonl" "$DIR/batches/part-"
i=0
for p in "$DIR"/batches/part-*; do
  i=$((i + 1))
  b=$(printf '%s/batches/batch-%02d.md' "$DIR" "$i")
  jq -r '
    def cut: if length > 2000 then .[0:1600] + "\n[… " + ((length - 2000) | tostring) + " chars omitted …]\n" + .[-400:] else . end;
    "=== TASK \(.id)\ndescription: \(.description)\nsubagent_type: \(if .subagent_type == "" then "(none)" else .subagent_type end)\nprompt:\n\(.prompt | cut)\n"' "$p" >"$b"
  rm -f "$p"
done
echo "sample: $total tasks in $i batches under $DIR/batches"
