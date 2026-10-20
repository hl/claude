# policy.jq — the routing policy of route.sh: opus unless a lower tier is safe.
#
# Loss function: under-routing costs a full retry round (and the re-research
# that comes with it); a higher tier does not cost wasted tokens. So:
#   opus     by default, and always when the security/blast-radius or
#            non-trivial-review signal is >= 0.7
#   haiku    kind poll, fetch or lookup; or P(haiku) >= 0.85, mechanical >= 0.7
#            and security/blast radius < 0.5
#   sonnet   P(opus) <= 0.15 and neither signal reaches 0.5
# Haiku-keep (the Agent hook only: ctx.requested == "haiku", no Route: id): the
# requested haiku stays when P(haiku) >= 0.95 with security and non-trivial review
# both < 0.5, whatever `mechanical` says; or when the description or prompt opens
# (first 200 chars) with a poll/fetch verb (poll_verb, ctx.poll_verb) and
# P(haiku) >= 0.8 with security < 0.5 (review is not capped there: a poll brief
# that names a PR reads as one). The opus gate (a signal >= 0.7) still wins.
# Then floors that only ever raise: a retry goes one tier above the previous
# attempt; investigate and fix-ci are at least sonnet; 5+ files rule out haiku
# and 12+ mean opus (not for poll/fetch/lookup); paths under auth, payments,
# migrations, infra, CI, hooks and the like count as security 1.0 (not for
# poll/fetch/lookup/investigate). reviewer_model: at least the implementer and
# at least sonnet; opus when the change is non-trivial or security >= 0.5.
#
# Input: {probabilities: {haiku, sonnet, opus}, confidence, signals: {...}, ctx: {...}}
#   ctx (all optional): attempt, prior_model, prior_outcome, kind, files (count),
#                       risky_paths ([paths that matched the high-blast-radius list]),
#                       requested, poll_verb (set by the Agent hook, see hook_context)
# Output: {model, reviewer_model, policy: [reasons]}

def tier_rank: {haiku: 0, sonnet: 1, opus: 2}[.] // null;
def tier_name: ["haiku", "sonnet", "opus"][.];
def r2: . * 100 | round / 100;

def thresholds: {
  signal: 0.7,                              # security or review at/above: opus
  haiku_p: 0.85, haiku_mech: 0.7, haiku_sec: 0.5,
  sonnet_popus: 0.15, sonnet_signal: 0.5,
  reviewer_opus: 0.5, files_no_haiku: 5, files_opus: 12,
  keep_haiku_p: 0.95, keep_haiku_signal: 0.5, keep_poll_p: 0.8, poll_window: 200
};

# poll_verb: the text reads as polling or fetching (poll, watch, wait for, check
# CI/PR/status, fetch, download, tail), whole words, any case.
def poll_verb:
  test("\\b(poll(s|ed|ing)?|watch(es|ed|ing)?|wait(s|ed|ing)? for|check(s|ed|ing)? (the )?(ci|pr|prs|status)|fetch(es|ed|ing)?|download(s|ed|ing)?|tail(s|ed|ing)?)\\b"; "i");

# hook_context: the --context the Agent hook gives route.sh for an explicit model
# with no Route: id. Input: the Agent tool_input. route.sh does not send these
# two fields to Jev; only route_policy reads them.
def hook_context:
  thresholds.poll_window as $w
  | {requested: (.model // null),
     poll_verb: ([(.description // ""), (.prompt // "")] | any(.[0:$w] | poll_verb))}
  | with_entries(select(.value != null));

def route_policy:
  thresholds as $t
  | (.probabilities // {}) as $p
  | (.signals // {}) as $s
  | (.ctx // {}) as $c
  | ($c.kind // "") as $kind
  | ($kind | IN("poll", "fetch", "lookup")) as $quick
  | (($c.risky_paths // []) | length > 0 and ($quick or $kind == "investigate" | not)) as $risky
  | ([$s.security_or_high_blast_radius // 0, (if $risky then 1 else 0 end)] | max) as $sec
  | ($s.review_of_nontrivial_diff // 0) as $rev
  | ([$rev, $s.nontrivial_change // 0] | max) as $change
  | ($c.files // 0) as $files
  | (($sec >= $t.signal) or ($rev >= $t.signal)) as $gate
  | ((($p.haiku // 0) >= $t.haiku_p) and (($s.mechanical // 0) >= $t.haiku_mech) and ($sec < $t.haiku_sec)) as $haiku_jev
  | ((($p.opus // 1) <= $t.sonnet_popus) and ($sec < $t.sonnet_signal) and ($rev < $t.sonnet_signal)) as $sonnet_ok
  # haiku-keep: an explicitly requested haiku that Jev is sure about, or a poll/fetch brief
  | (($c.requested // "") == "haiku") as $req_haiku
  | ($req_haiku and (($p.haiku // 0) >= $t.keep_haiku_p) and ($sec < $t.keep_haiku_signal) and ($rev < $t.keep_haiku_signal)) as $keep_sure
  | ($req_haiku and ($c.poll_verb == true) and (($p.haiku // 0) >= $t.keep_poll_p) and ($sec < $t.keep_haiku_signal)) as $keep_poll
  | (if $gate then 2 elif $quick or $haiku_jev or $keep_sure or $keep_poll then 0 elif $sonnet_ok then 1 else 2 end) as $base
  | [ if $gate then "opus: " + ([
          (if $sec >= $t.signal then "security/blast radius \($sec | r2)" else empty end),
          (if $rev >= $t.signal then "non-trivial review \($rev | r2)" else empty end)] | join(", "))
      elif $quick then "haiku: kind \($kind)"
      elif $haiku_jev then "haiku: P(haiku) \($p.haiku | r2) >= \($t.haiku_p), mechanical \($s.mechanical | r2)"
      elif $keep_sure then "haiku: requested haiku kept, P(haiku) \($p.haiku | r2) >= \($t.keep_haiku_p), security \($sec | r2), review \($rev | r2)"
      elif $keep_poll then "haiku: requested haiku kept, poll/fetch brief, P(haiku) \($p.haiku | r2) >= \($t.keep_poll_p), security \($sec | r2)"
      elif $sonnet_ok then "sonnet: P(opus) \($p.opus | r2) <= \($t.sonnet_popus)"
      else "opus: default (P(opus) \(($p.opus // 1) | r2))" end ] as $why
  # --- floors (only ever raise)
  | (if $quick then 0 elif $files >= $t.files_opus and $kind != "investigate" then 2
     elif $files >= $t.files_no_haiku then 1 else 0 end) as $files_floor
  | (if $kind | IN("investigate", "fix-ci") then 1 else 0 end) as $kind_floor
  # a prior outcome that reads as a failure ("thin", "wrong", "review FAIL x2"), whole words
  # only, and not a negated one ("PASS, no failures")
  | ((($c.attempt // 1) >= 2)
     or (($c.prior_outcome // "") | ascii_downcase
         | test("\\b(thin|wrong|fail|failed|fails|failure|failures|incomplete|redo|re-do|escalated?|escalation)\\b")
           and (test("\\b(no|zero|0|without) (fail|failed|fails|failure|failures)\\b") | not)))
      as $retry
  | (if $retry then ((($c.prior_model // "" | tier_rank) // $base) + 1 | [., 2] | min) else 0 end) as $retry_floor
  | ([$base, $files_floor, $kind_floor, $retry_floor] | max) as $final
  | {
      model: ($final | tier_name),
      reviewer_model: ((if ($change >= $t.reviewer_opus) or ($sec >= $t.reviewer_opus) then 2 else ([$final, 1] | max) end) | tier_name),
      policy: ($why
        + (if $risky then ["high-blast-radius paths: " + ($c.risky_paths[0:3] | join(", "))] else [] end)
        + (if $files_floor > $base then ["\($files) files: at least \($files_floor | tier_name)"] else [] end)
        + (if $kind_floor > $base then ["kind \($kind): at least sonnet"] else [] end)
        + (if $retry and $retry_floor > ([$base, $files_floor, $kind_floor] | max)
           then ["retry (attempt \($c.attempt // 2)\(if ($c.prior_outcome // "") != "" then ", " + $c.prior_outcome else "" end)): one tier above \($c.prior_model // ($base | tier_name))"]
           elif $retry then ["retry: already at \($final | tier_name)"] else [] end))
    };
