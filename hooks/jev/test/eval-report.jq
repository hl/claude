# eval-report.jq — `jq -r -f eval-report.jq results.json` (an array of route
# results, each with .label and .model; real-set rows also carry .chosen_tier
# and .under_routed). Used by route-eval.sh and tune.sh.
def rank: {haiku: 0, sonnet: 1, opus: 2, fable: 3}[.] // null;
def pct($a; $b): if $b == 0 then "n/a" else "\(($a * 1000 / $b | round) / 10)%" end;
. as $all
| [.[] | select(.model != "FAIL")] as $ok
| ($ok | length) as $n
| ($ok | map(select(.label == .model)) | length) as $correct
| ($ok | map(select((.model | rank) > (.label | rank)))) as $over
| ($ok | map(select((.model | rank) < (.label | rank)))) as $under
| [.[] | select(.under_routed == true and (.chosen_tier | rank) != null and .model != "FAIL")] as $weak
| "",
  "confusion (rows = label, cols = routed):",
  ("label/routed      haiku  sonnet    opus    FAIL"),
  (["haiku", "sonnet", "opus"][] as $l
   | "\($l | . + "          " | .[0:14])" + ([["haiku", "sonnet", "opus", "FAIL"][] as $m
       | [$all[] | select(.label == $l and .model == $m)] | length | tostring | "        " + . | .[-8:]] | join(""))),
  "",
  "N=\($n) correct=\($correct) accuracy=\(pct($correct; $n))",
  "under-routed: \($under | length) (\(pct($under | length; $n)))  by label: opus->lower=\([$under[] | select(.label == "opus")] | length) of \([$ok[] | select(.label == "opus")] | length), sonnet->haiku=\([$under[] | select(.label == "sonnet")] | length) of \([$ok[] | select(.label == "sonnet")] | length) (\(pct([$under[] | select(.label == "sonnet")] | length; [$ok[] | select(.label == "sonnet")] | length)))",
  "over-routed:  \($over | length) (\(pct($over | length; $n)))  haiku->sonnet=\([$over[] | select(.label == "haiku" and .model == "sonnet")] | length) haiku->opus=\([$over[] | select(.label == "haiku" and .model == "opus")] | length) sonnet->opus=\([$over[] | select(.label == "sonnet" and .model == "opus")] | length)",
  (if ($weak | length) > 0 then
     "weak under_routed labels (real run redone/escalated): \($weak | length); route.sh picked a higher tier than the one that ran for \([$weak[] | select((.model | rank) > (.chosen_tier | rank))] | length) (recall \(pct([$weak[] | select((.model | rank) > (.chosen_tier | rank))] | length; $weak | length))); already at opus or above when it ran: \([$weak[] | select((.chosen_tier | rank) >= 2)] | length)"
   else empty end),
  (if any(.[]; has("anchored")) then
     ([$ok[] | select(.anchored == false)]) as $u
     | "unanchored subset (no line naming a tier): N=\($u | length), opus->lower=\([$u[] | select(.label == "opus" and (.model | rank) < 2)] | length) of \([$u[] | select(.label == "opus")] | length), sonnet->haiku=\([$u[] | select(.label == "sonnet" and .model == "haiku")] | length) of \([$u[] | select(.label == "sonnet")] | length), over-routed \([$u[] | select((.model | rank) > (.label | rank))] | length) (\(pct([$u[] | select((.model | rank) > (.label | rank))] | length; $u | length))), accuracy \(pct([$u[] | select(.model == .label)] | length; $u | length))"
   else empty end),
  (if ([.[] | select(.chosen_tier != null)] | length) > 0 then
     "vs the tier that actually ran: route.sh higher on \([$ok[] | select((.chosen_tier | rank) != null and (.model | rank) > (.chosen_tier | rank))] | length), same on \([$ok[] | select((.model | rank) == (.chosen_tier | rank))] | length), lower on \([$ok[] | select((.chosen_tier | rank) != null and (.model | rank) < (.chosen_tier | rank))] | length); the tier that ran was below the label on \([$ok[] | select((.chosen_tier | rank) != null and (.chosen_tier | rank) < (.label | rank))] | length)"
   else empty end)
