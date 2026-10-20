#!/usr/bin/env bash
# route.sh — pick haiku | sonnet | opus for a subagent task, using Jev.
#
#   route.sh [--context '<json>'] "<task text>"     or     route.sh [--context '<json>'] < brief.md
#
# --context (optional) describes the situation around the brief:
#   attempt        1 for a first try, 2+ for a retry
#   prior_model    the model the previous attempt ran on (haiku|sonnet|opus)
#   prior_outcome  e.g. "thin", "wrong", "review FAIL x2"
#   files_hint     number of files, or a list of them
#   paths          list of paths the work touches; auth, payments, migrations,
#                  infra, secrets, CI and hook paths count as high blast radius
#   kind           implement | review | investigate | fix-ci | address-comments | poll
#   diff_size      for reviews, e.g. "+1240/-380 in 23 files"
#
# Prints one JSON object:
#   {id, model, reviewer_model, deepen, policy: [reasons], confidence,
#    probabilities, signals, jev_choice, jev_model, prompt_tokens, above,
#    anchors_stripped (lines naming a tier that were removed first, see anchors.jq)}
# and logs it (with the context, without the task text) to route.jsonl so
# outcome.sh can attach the result later by id.
# Exits non-zero on any failure (no key, network, timeout, bad answer) so the
# caller can fall back to its own judgement (and should then pick opus).
#
# Policy (policy.jq): opus unless Jev is confident a lower tier suffices.
#   haiku   P(haiku) >= JEV_ROUTE_HAIKU_P (0.6), mechanical >= JEV_ROUTE_HAIKU_MECH (0),
#           ambiguous <= JEV_ROUTE_HAIKU_AMB (0.9), security/blast radius and
#           non-trivial review < JEV_ROUTE_SIGNAL_MIN (0.7)
#   sonnet  P(opus) <= JEV_ROUTE_SONNET_POPUS (0.35), confidence >= JEV_ROUTE_SONNET_CONF (0),
#           same two signals < JEV_ROUTE_SIGNAL_MIN
#   else    opus
# Then: retries go at least one tier above the previous attempt; investigate and
# fix-ci are at least sonnet; 5+ files rule out haiku and 12+ mean opus; risky
# paths count as security/blast radius 1.0. reviewer_model >= model, never
# haiku, opus when non-trivial change/review or security >= JEV_ROUTE_REVIEWER_OPUS
# (0.5). deepen = ambiguous or needs_research >= JEV_ROUTE_DEEPEN (0.6).
#
# JEV_ROUTE_SIGNAL_MIN (0.7) is a design choice, not tuned: security-sensitive or
# high-blast-radius work, and reviews of non-trivial diffs, go to opus. The other
# defaults are test/tune.sh's choice (2026-10-18) on the real labelled set (451
# Agent tasks from local transcripts, labelled blind by one opus agent, model-
# naming lines stripped as below), with a two-fold holdout split by task, in two
# independent sessions of 3 Jev runs per task. The folds chose P(haiku) 0.55 /
# 0.6 / 0.5 and P(opus) 0.35 / 0.6; the shipped point takes the most conservative
# value of each. In sample, on both sessions: 0 opus tasks under-routed and 0
# sonnet tasks sent to haiku, also with every Jev value moved 0.1 toward the
# cheaper tier and on the briefs that name no tier; 48% over-routed (43% on those
# briefs). Out of sample, the fold that chose 0.55 / 0.35 under-routed none of its
# unseen half; the fold that chose 0.5 / 0.6 under-routed 3 of 162 opus rows.
# Autotune (autotune.sh) may later move these, but only the conservative way.
# See test/evidence/route-eval-real.txt.
set -euo pipefail

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JEV_HOOK=${JEV_HOOK:-route}
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

jev_disabled && exit 3

ctx='{}'
if [ "${1:-}" = --context ]; then
  ctx=${2:-'{}'}
  shift 2 || shift $#
fi
ctx=$(jq -c 'if type == "object" then . else {} end' <<<"$ctx" 2>/dev/null) || {
  echo "route.sh: --context is not a JSON object" >&2
  exit 2
}
if [ $# -gt 0 ]; then task=$*; else task=$(cat); fi
[ -n "${task//[[:space:]]/}" ] || {
  echo "route.sh: empty task" >&2
  exit 2
}

# Lines that already name a tier ("Model: sonnet — ...", "jev: opus/opus ...",
# "— opus because ...") anchor Jev on the author's guess: drop them (anchors.jq).
# This covers the Agent hook too, which pipes the prompt through here.
st=$(jq -Rs -c -L "$JEV_DIR" 'include "anchors"; strip_anchors' <<<"$task")
task=$(jq -r '.text' <<<"$st")
anchors=$(jq '.stripped' <<<"$st")
[ -n "${task//[[:space:]]/}" ] || {
  echo "route.sh: task is empty once model-naming lines are removed" >&2
  exit 2
}

# Briefs put goal and criteria first; keep the head if one is ever huge.
max=$(jev_state_budget_chars 3000)
task=${task:0:$max}

# Normalise the context: files count, high-blast-radius paths.
ctx=$(jq -c '
  def risky: test("(^|/)(auth|oauth|login|session|sessions|permission|permissions|acl|rbac|iam|crypto|secrets?|credentials?|keys?|tokens?|payments?|billing|invoices?|stripe|migrations?|priv/repo|schema\\.rb|infra|terraform|k8s|kubernetes|helm|deploy|deployment|\\.github/workflows|\\.gitlab-ci|ci|hooks?|\\.claude)(/|\\.|$|_)|settings\\.json$|Dockerfile|\\.tf$|\\.env"; "i");
  . + {files: (if (.files_hint | type) == "array" then (.files_hint | length)
               elif (.files_hint | type) == "number" then .files_hint
               elif (.files_hint | type) == "string" then (.files_hint | tonumber? // null)
               else null end)}
  | . + {risky_paths: [(.paths // []) + (if (.files_hint | type) == "array" then .files_hint else [] end) | .[] | strings | select(risky)] | unique}
  | with_entries(select(.value != null))' <<<"$ctx")

req=$(jq -n --arg task "$task" --argjson ctx "$ctx" --arg model "$JEV_MODEL" '{
  model: $model,
  state: {task: $task, context: ($ctx | del(.risky_paths))},
  questions: {
    tier: {
      type: "choice",
      instructions: "`task` is a brief for a Claude subagent; `context` (possibly empty) says which attempt this is, how earlier attempts went, what kind of work it is and which files or paths it touches. Pick the lightest model tier that will get `task` right in one pass. A retry or escalation costs more than starting one tier up, so when in doubt pick the higher tier.",
      criteria: {
        haiku: "Mechanical, well-specified, low-risk work: polling CI or PR status, fetching or extracting log output without diagnosing it, simple lookups, trivial edits (typos, version bumps, renames with exact instructions).",
        sonnet: "Routine, well-scoped implementation and fixes with clear acceptance criteria, straightforward investigation or diagnosis, addressing simple PR comments.",
        opus: "Ambiguous or cross-cutting changes, design decisions, tricky debugging, security-sensitive or high-blast-radius code, first-round reviews of non-trivial diffs, and anything where sonnet cannot confidently be predicted to succeed."
      }
    },
    ambiguous: {type: "noul", instructions: "`task` leaves important requirements unstated or open to interpretation."},
    needs_research: {type: "noul", instructions: "`task` requires investigating unfamiliar code, systems or documentation before acting."},
    mechanical: {type: "noul", instructions: "`task` is mechanical: its exact result is fully determined by the description."},
    cross_cutting: {type: "noul", instructions: "`task` changes several components, files or layers that must stay consistent with each other."},
    security_or_high_blast_radius: {type: "noul", instructions: "`task` changes or reviews security-sensitive code (auth, secrets, permissions, crypto, payments) or code where a mistake would break production, corrupt data or affect many users. Read-only lookups and reports do not count."},
    review_of_nontrivial_diff: {type: "noul", instructions: "`task` asks for a review of a non-trivial code change (a diff, branch or pull request)."},
    nontrivial_change: {type: "noul", instructions: "Carrying out `task` produces a code or configuration change that is non-trivial to review: more than a few lines of logic, or several files."}
  }
}')

resp=$(jev_call <<<"$req") || exit 1

# Thresholds: the defaults below, then $JEV_HOME/tune/thresholds.json if autotune
# applied one (only ever a more conservative point, see autotune.sh), then any
# JEV_ROUTE_* variable. The security/review gate is never tuned.
tuned='{}'
tf="$JEV_HOME/tune/thresholds.json"
if [ -f "$tf" ]; then
  tuned=$(jq -c '{haiku_p, haiku_mech, haiku_amb, sonnet_popus, sonnet_conf} | with_entries(select(.value | type == "number"))' "$tf" 2>/dev/null) || tuned='{}'
fi
thresholds=$(jq -cn --argjson t "$tuned" \
  --arg hp "${JEV_ROUTE_HAIKU_P:-}" --arg hm "${JEV_ROUTE_HAIKU_MECH:-}" --arg ha "${JEV_ROUTE_HAIKU_AMB:-}" \
  --arg sp "${JEV_ROUTE_SONNET_POPUS:-}" --arg sc "${JEV_ROUTE_SONNET_CONF:-}" --arg sig "${JEV_ROUTE_SIGNAL_MIN:-}" \
  --arg rv "${JEV_ROUTE_REVIEWER_OPUS:-}" --arg dp "${JEV_ROUTE_DEEPEN:-}" '
  {haiku_p: 0.6, haiku_mech: 0, haiku_amb: 0.9, sonnet_popus: 0.35, sonnet_conf: 0,
   sec: 0.7, review: 0.7, reviewer_opus: 0.5, deepen: 0.6}
  + $t
  + ({haiku_p: $hp, haiku_mech: $hm, haiku_amb: $ha, sonnet_popus: $sp, sonnet_conf: $sc,
      sec: $sig, review: $sig, reviewer_opus: $rv, deepen: $dp} | with_entries(select(.value != "") | .value |= tonumber))')
id="r$(date +%s)-$$-$RANDOM"

out=$(jq -e -c -L "$JEV_DIR" --argjson ctx "$ctx" --argjson t "$thresholds" --arg id "$id" --argjson anchors "$anchors" --argjson tuned "$tuned" '
  include "policy";
  . as $r
  | .answers as $a
  | {probabilities: $a.tier.probabilities, confidence: $a.tier.confidence,
     signals: ({ambiguous, needs_research, mechanical, cross_cutting, security_or_high_blast_radius,
                review_of_nontrivial_diff, nontrivial_change} | with_entries(.value = $a[.key].noul)),
     ctx: $ctx} as $in
  | ($in | route_policy($t)) as $d
  | {id: $id, model: $d.model, reviewer_model: $d.reviewer_model, deepen: $d.deepen, policy: $d.policy,
     confidence: $in.confidence, probabilities: $in.probabilities, signals: $in.signals,
     jev_choice: $a.tier.choice, jev_model: $r.model, prompt_tokens: $r.usage.input_tokens,
     above: $d.above, anchors_stripped: $anchors, tuned: ($tuned != {})}' <<<"$resp") || exit 1

if [ "${JEV_ROUTE_NO_LOG:-0}" != 1 ]; then
  jev_log route.jsonl "$(jq -c --argjson ctx "$ctx" '{action: "route", context: $ctx} + .' <<<"$out")"
fi
printf '%s\n' "$out"
