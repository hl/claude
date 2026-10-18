# ledger-req.jq — build the Jev request(s) for one ledger step.
# Input: {cands: [{n, kind, text}], live: [{id, kind, text}] (oldest first), tail}
# Args: $model, $tail_max, $per_req (questions per request), $max_pairs, $per_kind (20)
# Output: an array of request bodies. Questions:
#   s<N>          score: how much candidate N must survive (v1 rubric)
#   x<N>_<id>     noul: candidate N supersedes or corrects ledger fact <id>
#   x<N>_c<K>     noul: candidate N supersedes or corrects earlier candidate K
# Supersession is only asked within a family (statements = user/decision/todo,
# errors, branches; a statement may also retire an error, e.g. "that host is
# gone"), against the $per_kind most recent live facts of that family, ranked
# by word overlap; at most $max_pairs pairs in total.

def family: if IN("user", "decision", "todo", "carried") then "statement"
  elif . == "error" then "error" elif . == "branch" then "branch" else null end;
def words: ascii_downcase | [scan("[a-z0-9][a-z0-9._/-]{2,}")] | unique;
def overlap($a; $b): ($a - ($a - $b)) | length;
def targets($f): if $f == "statement" then ["statement", "error"] else [$f] end;

. as $in
| [.cands[] | . + {fam: (.kind | family), w: (.text | words)}] as $c
| [.live[] | . + {fam: (.kind | family), w: (.text | words)}] as $live
| [
    $c[] | select(.fam != null) | . as $x
    | (([$live[] | select(.fam | IN(targets($x.fam)[]))] | .[-$per_kind:] | map({t: .id, text, w}))
       + [$c[] | select((.fam | IN(targets($x.fam)[])) and .n < $x.n) | {t: "c\(.n)", text, w}])
    | to_entries[]
    | {n: $x.n, ntext: $x.text, t: .value.t, ttext: .value.text, o: overlap($x.w; .value.w), r: .key}
  ]
| sort_by(-.o, -.r) | .[0:$max_pairs] | sort_by(.n, .t) as $pairs
| ([$c[] | {key: "s\(.n)", value: {
      type: "score",
      instructions: "Candidate \(.n) in `candidates`: \"\(.text)\". This is a long-running session; its context will be compacted into a short summary several times, and work continues from that summary. How much must candidate \(.n) survive for the rest of the session to go correctly? Constraints and context the user stated (names, hosts, ports, tickets, branches, rules), decisions, open items, pull requests opened or reviewed in this session and files it changed keep mattering for the whole session even when the latest step does not use them. Finished one-off steps, routine file reads and tool noise do not.",
      criteria: [
        "Irrelevant: not needed to continue the work, or already obsolete",
        "Nice to have: useful background; the work continues correctly without it",
        "Important: needed to continue correctly; losing it means re-discovering it",
        "Critical: losing it causes rework, a wrong decision or a repeated mistake"
      ]}}]
   + [$pairs[] | {key: "x\(.n)_\(.t)", value: {
      type: "noul",
      instructions: ("Candidate \(.n) in `candidates`: \"\(.ntext)\". " +
        (if (.t | startswith("c")) then "Candidate \(.t[1:])" else "Fact \(.t) in `ledger`" end) + ": \"\(.ttext)\". " +
        "Candidate \(.n) supersedes or corrects it: it gives a newer value, decision or status for the same thing, so the older statement is no longer current."),
      criteria: {
        true: "The newer statement replaces, corrects, reverses or completes the older one about the same subject",
        false: "They are about different things, or both stay true"
      }}}]) as $qs
| [range(0; $qs | length; $per_req) as $i | $qs[$i:$i + $per_req] | from_entries] as $chunks
| [$chunks[] | {
    model: $model,
    state: {
      ledger: [$in.live[-40:][] | "\(.id). \(.text)"],
      candidates: [$in.cands[] | "\(.n). \(.text)"],
      recent_turns: (if ($in.tail | length) > $tail_max then $in.tail[-$tail_max:] else $in.tail end)
    },
    questions: .
  }]
