#!/usr/bin/env bash
# harvest.sh — build the real routing eval set from this machine's transcripts.
#
#   hooks/jev/test/harvest.sh [projects-dir]     (default ~/.claude/projects)
#
# Every Agent tool_use in every transcript (subagents/ included) becomes one
# task: description, prompt, model, subagent_type, session, timestamp, the tier
# that ran, and weak outcome labels:
#   dup_higher_tier   the same session later spawned a near-duplicate
#                     description (word Jaccard >= 0.5) on a higher tier
#   parent_redo       the parent's next words call the result thin/wrong or
#                     re-run/escalate it
#   user_redo         the user's next prompt does
# Any of them sets under_routed: true. Tasks are deduplicated on description +
# the first 400 chars of the prompt. Scratch test sessions (/tmp/jev-*, /tmp/rv-*)
# are skipped.
#
# Output stays local: ~/.claude/jev/eval/harvest.jsonl (JEV_EVAL_DIR). It holds
# real prompts — never commit it. ~/.claude/.gitignore ignores jev/.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${1:-$HOME/.claude/projects}
OUT=${JEV_EVAL_DIR:-$HOME/.claude/jev/eval}
mkdir -p "$OUT"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jev-harvest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Only files that contain an Agent tool_use are parsed.
find "$SRC" -name '*.jsonl' -print0 | xargs -0 grep -l '"type":"tool_use","id":"[^"]*","name":"Agent"' >"$tmp/files" 2>/dev/null || true
n=0
while IFS= read -r f; do
  jq -cR -f "$HERE/harvest-slim.jq" "$f" 2>/dev/null | jq -s -c -f "$HERE/harvest-file.jq" 2>/dev/null >>"$tmp/raw.jsonl" || true
  n=$((n + 1))
done <"$tmp/files"

jq -s -c '
  def words: ascii_downcase | [scan("[a-z0-9]{3,}")] | unique;
  def jacc($a; $b): if ($a + $b | unique | length) == 0 then 0
    else ($a - ($a - $b) | length) / ($a + $b | unique | length) end;
  def rank: {haiku: 0, sonnet: 1, opus: 2, fable: 3}[. // ""];
  # The parent judging the subagent output poor, or redoing it.
  def parent_redo: test("\\b((too|was|is|looks|came back|came out) thin|thin (output|report|review|answer|result)|escalat(e|ing|ed) (to|it|this|the)|one tier up|(answer|report|result|output|conclusion|diagnosis|review|agent) (is|was) (wrong|incorrect|incomplete|shallow)|got it wrong|didn.t (actually )?(follow|answer|do what)|not what I asked|missed the point|redo (it|the|this))\\b"; "i");
  def user_redo: test("\\b(wrong|re-?do|try again|not what I|that.s not|thin|you missed|incorrect|doesn.t work|didn.t work|still (broken|failing))\\b"; "i");
  [.[] | select(.prompt != "")
       | select((.cwd // "") | test("^(/private)?/tmp/(jev|rv)-") | not)]
  | map(. + {w: (.description | words)})
  | group_by(.session)
  | map(. as $all | map(. as $t
      | ([$all[] | select(.ts > $t.ts and ((.chosen_tier | rank) // -1) > (($t.chosen_tier | rank) // 9)
                          and jacc(.w; $t.w) >= 0.5)] | length > 0) as $dup
      | (.after_parent | parent_redo) as $pr
      | (.after_user | user_redo) as $ur
      | del(.w) + {weak: ([if $dup then "dup_higher_tier" else empty end, if $pr then "parent_redo" else empty end,
                           if $ur then "user_redo" else empty end])})) | add
  | group_by(.description + "\u0000" + .prompt[0:400])
  | map(sort_by(.ts) | .[0] + {seen: length, weak: (map(.weak[]) | unique)} | . + {under_routed: (.weak | length > 0)})
  | sort_by(.ts)[]
' "$tmp/raw.jsonl" >"$tmp/dedup.jsonl"

# Stable ids (md5 of the dedup key) so labels survive a re-harvest.
perl -MDigest::MD5=md5_hex -MJSON::PP -ne '
  my $j = JSON::PP->new->utf8->canonical;
  my $t = $j->decode($_);
  $t->{id} = "t" . substr(md5_hex(Encode::encode_utf8($t->{description} . "\0" . substr($t->{prompt}, 0, 400))), 0, 10);
  print $j->encode($t), "\n";' -MEncode "$tmp/dedup.jsonl" >"$OUT/harvest.jsonl"

jq -s -r --arg files "$n" '
  "files parsed: \($files)", "unique tasks: \(length)",
  "by tier that ran: \(group_by(.chosen_tier) | map("\(.[0].chosen_tier // "unknown")=\(length)") | join(" "))",
  "weak under_routed: \(map(select(.under_routed)) | length) (\(map(.weak[]) | group_by(.) | map("\(.[0])=\(length)") | join(" ")))"' "$OUT/harvest.jsonl"
echo "wrote $OUT/harvest.jsonl"
