# policy.jq — the routing policy, shared by route.sh and test/tune.sh.
#
# Loss function: under-routing costs a full retry round (and the re-research
# that comes with it); over-routing costs nothing the user cares about. So the
# tier is opus unless Jev is confident a lower tier suffices.
#
# Input: {probabilities: {haiku, sonnet, opus}, confidence, signals: {...}, ctx: {...}}
#   ctx (all optional): attempt, prior_model, prior_outcome, kind, files (count),
#                       risky_paths ([paths that matched the high-blast-radius list])
# Arg $t: thresholds (see defaults below; route.sh passes the JEV_ROUTE_* knobs).
# Output: {model, reviewer_model, deepen, policy: [reasons], escalate_conf}

def tier_rank: {haiku: 0, sonnet: 1, opus: 2}[.] // null;
def tier_name: ["haiku", "sonnet", "opus"][.];
def r2: . * 100 | round / 100;

def default_thresholds: {
  haiku_p: 0.5, haiku_mech: 0, haiku_amb: 0.9,
  sonnet_popus: 0.4, sonnet_conf: 0,
  sec: 0.7, review: 0.7, reviewer_opus: 0.5, deepen: 0.6,
  files_no_haiku: 5, files_opus: 12
};

def route_policy($t0):
  (default_thresholds + ($t0 // {})) as $t
  | (.probabilities // {}) as $p
  | (.signals // {}) as $s
  | (.ctx // {}) as $c
  | ($c.kind // "") as $kind
  | (($c.risky_paths // []) | length > 0 and ($kind | IN("poll", "investigate") | not)) as $risky
  | ([$s.security_or_high_blast_radius // 0, (if $risky then 1 else 0 end)] | max) as $sec
  | ($s.review_of_nontrivial_diff // 0) as $rev
  | ([$rev, $s.nontrivial_change // 0] | max) as $change
  | ($c.files // 0) as $files
  # --- the lower tiers have to earn it
  | ((($p.haiku // 0) >= $t.haiku_p) and (($s.mechanical // 0) >= $t.haiku_mech)
     and (($s.ambiguous // 1) <= $t.haiku_amb) and ($sec < $t.sec) and ($rev < $t.review)) as $haiku_ok
  | ((($p.opus // 1) <= $t.sonnet_popus) and ((.confidence // 0) >= $t.sonnet_conf)
     and ($sec < $t.sec) and ($rev < $t.review)) as $sonnet_ok
  | (if $haiku_ok then 0 elif $sonnet_ok then 1 else 2 end) as $base
  | [ if $haiku_ok then "haiku: P(haiku) \($p.haiku | r2) >= \($t.haiku_p), mechanical \($s.mechanical | r2), ambiguous \($s.ambiguous | r2)"
      elif $sonnet_ok then "sonnet: P(opus) \($p.opus | r2) <= \($t.sonnet_popus), confidence \(.confidence | r2) >= \($t.sonnet_conf)"
      else "opus: " + ([
          (if ($p.opus // 1) > $t.sonnet_popus then "P(opus) \($p.opus | r2) > \($t.sonnet_popus)" else empty end),
          (if (.confidence // 0) < $t.sonnet_conf then "confidence \(.confidence | r2) < \($t.sonnet_conf)" else empty end),
          (if $sec >= $t.sec then "security/blast radius \($sec | r2)" else empty end),
          (if $rev >= $t.review then "non-trivial review \($rev | r2)" else empty end)] | join(", ")) end ] as $why
  # --- context floors
  | (if ($files >= $t.files_opus) and ($kind | IN("poll", "investigate") | not) then 2
     elif $files >= $t.files_no_haiku then 1 else 0 end) as $files_floor
  | (if $kind | IN("investigate", "fix-ci") then 1 else 0 end) as $kind_floor
  | ((($c.attempt // 1) >= 2) or ((($c.prior_outcome // "") | ascii_downcase | test("thin|wrong|fail|incomplete|redo|escalat"))))
      as $retry
  | (if $retry then ((($c.prior_model // "" | tier_rank) // $base) + 1 | [., 2] | min) else 0 end) as $retry_floor
  | ([$base, $files_floor, $kind_floor, $retry_floor] | max) as $final
  | ($why
     + (if $risky then ["high-blast-radius paths: " + ($c.risky_paths[0:3] | join(", "))] else [] end)
     + (if $files_floor > $base then ["\($files) files: at least \($files_floor | tier_name)"] else [] end)
     + (if $kind_floor > $base then ["kind \($kind): at least sonnet"] else [] end)
     + (if $retry and $retry_floor > ([$base, $files_floor, $kind_floor] | max)
        then ["retry (attempt \($c.attempt // 2)\(if ($c.prior_outcome // "") != "" then ", " + $c.prior_outcome else "" end)): one tier above \($c.prior_model // ($base | tier_name))"]
        elif $retry then ["retry: already at \($final | tier_name)"] else [] end)) as $policy
  # --- reviewer: at least the implementer, never haiku, opus for risky or non-trivial changes
  | (if ($change >= $t.reviewer_opus) or ($sec >= $t.reviewer_opus) then 2 else ([$final, 1] | max) end) as $rv
  # --- how sure Jev is that a cheaper tier would fall short (the Agent hook's escalation gate)
  | {
      model: ($final | tier_name),
      reviewer_model: ($rv | tier_name),
      deepen: ((($s.ambiguous // 0) >= $t.deepen) or (($s.needs_research // 0) >= $t.deepen)),
      policy: $policy,
      above: {
        haiku: ([(($p.sonnet // 0) + ($p.opus // 0)), $sec, $rev, (1 - ($s.mechanical // 0))] | max | r2),
        sonnet: ([($p.opus // 0), $sec, $rev] | max | r2)
      }
    };
