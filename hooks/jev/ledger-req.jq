# ledger-req.jq — build the Jev request(s) for one ledger step.
# Input: {cands: [{n, kind, text}], live: [{id, kind, text}] (oldest first), tail}
# Args: $model, $tail_max, $per_req (questions per request), $max_pairs, $per_kind (20)
# Output: an array of request bodies. Questions:
#   s<N>          score: how much candidate N must survive (v1 rubric)
#   x<N>_<id>     choice unrelated / partly / fully: does candidate N correct
#                 ledger fact <id> (partly: the older fact also says other
#                 things that stay true; fully: nothing in it stays current)
#   x<N>_c<K>     the same against earlier candidate K of this slice
# Supersession is only asked within a family (statements = user/decision/todo,
# errors, branches; a statement may also retire an error, e.g. "that host is
# gone"): against the $per_kind live facts of that family with the most word
# overlap (all of them ranked, the more recent first on a tie), plus earlier
# candidates of this slice; at most $max_pairs pairs in total. Not asked: an
# assistant line that restates a statement (over 80% of its words in it and no
# new values: numbers, paths, names with . / _ -).

def family: if IN("user", "decision", "todo", "carried") then "statement"
  elif . == "error" then "error" elif . == "branch" then "branch" else null end;
def words: ascii_downcase | [scan("[a-z0-9][a-z0-9._/-]{2,}")] | unique;
def overlap($a; $b): ($a - ($a - $b)) | length;
def targets($f): if $f == "statement" then ["statement", "error"] else [$f] end;
def vals: map(select(test("[0-9/._-]")));
# content words: no "User said:"/"Decision:" prefix, no filler words
def cw: sub("^(User said|Decision|Open item|Carried): *"; "") | words
  - ["the", "and", "for", "with", "this", "that", "will", "we'll", "i'll", "are", "was", "from", "into",
     "our", "you", "your", "use", "using", "only", "must", "should", "not", "never", "always", "ok", "okay"];
# $x restates $t: an assistant line mostly made of $t's content words, adding no value of its own
def restates($x; $t): $x.kind == "decision" and ($x.cw | length) > 0
  and (overlap($x.cw; $t.cw) / ($x.cw | length)) > 0.8 and (($x.w | vals) - $t.w | length) == 0;

. as $in
# The checkout's current branch is context, not a decision: it never retires a branch fact.
| [.cands[] | . + {fam: (if (.text | startswith("Git branch of the session directory")) then null else (.kind | family) end), w: (.text | words), cw: (.text | cw)}] as $c
| [.live[] | . + {fam: (.kind | family), w: (.text | words), cw: (.text | cw)}] as $live
| [
    $c[] | select(.fam != null) | . as $x
    | (([$live | to_entries[] | .value + {r: .key} | select(.fam | IN(targets($x.fam)[]))]
         | map(. + {o: overlap($x.w; .w)}) | sort_by(-.o, -.r) | .[0:$per_kind]
         | map({t: .id, kind, text, w, cw, o, r}))
       + [$c[] | select((.fam | IN(targets($x.fam)[])) and .n < $x.n)
          | {t: "c\(.n)", kind, text, w, cw, o: overlap($x.w; .w), r: (1000000 + .n)}])
    | .[] | select(restates($x; .) | not)
    | {n: $x.n, ntext: $x.text, t: .t, ttext: .text, o: .o, r: .r}
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
      type: "choice",
      instructions: ("Candidate \(.n) in `candidates` (newer): \"\(.ntext)\". " +
        (if (.t | startswith("c")) then "Candidate \(.t[1:])" else "Fact \(.t) in `ledger`" end) + " (older): \"\(.ttext)\". " +
        "Does the newer statement give a newer value, decision or status for something the older one says, so that the older statement is no longer fully current?"),
      criteria: {
        unrelated: "No: they are about different things, or both stay fully true",
        partly: "It corrects or updates part of the older statement; the older statement also says other things that stay true",
        fully: "It replaces, corrects, reverses or completes everything in the older statement that still matters"
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
