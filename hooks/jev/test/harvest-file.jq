# harvest-file.jq — `jq -s -c -f harvest-file.jq` over one file's slim records.
# One line per Agent call: the inputs, the tier that ran (the alias given, or the
# parent's model when none was given), and the text that followed the result
# (the parent's next words and the user's next prompt), for weak outcome labels.
def tier: if . == null then null
  elif test("haiku"; "i") then "haiku" elif test("sonnet"; "i") then "sonnet"
  elif test("opus"; "i") then "opus" elif test("fable"; "i") then "fable" else null end;
. as $r
| [range(0; length) as $i | $r[$i] | select(.k == "a") | .uses[] as $u | {i: $i, a: $r[$i], u: $u}]
| map(
    . as $c
    | ([range($c.i + 1; $r | length) | select($r[.].k == "r" and ($r[.].ids | index($c.u.id)))] | first) as $j
    | (if $j == null then [] else
        [range($j + 1; [$j + 12, ($r | length)] | min) as $x | $r[$x]]
        | (map((.uses // []) | length > 0) | index(true)) as $stop
        | (if $stop == null then . else .[0:$stop] end)
        | [.[] | select(.k == "a" or .k == "u") | {k, text}] end) as $after
    | {
        ts: $c.a.ts, session: $c.a.sid, in_subagent: ($c.a.ag != null), cwd: $c.a.cwd,
        tool_use_id: $c.u.id,
        description: ($c.u.in.description // ""), prompt: ($c.u.in.prompt // ""),
        subagent_type: ($c.u.in.subagent_type // ""), model: ($c.u.in.model // ""),
        parent_model: $c.a.m,
        chosen_tier: (if ($c.u.in.model // "") != "" then ($c.u.in.model | tier) else ($c.a.m | tier) end),
        has_result: ($j != null),
        after_parent: ([$after[] | select(.k == "a") | .text] | join("\n") | .[0:1500]),
        after_user: ([$after[] | select(.k == "u") | .text] | first // "" | .[0:800])
      })
| .[]
