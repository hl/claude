#!/usr/bin/env bash
# route.sh — pick haiku | sonnet | opus for a subagent task, using Jev.
#
#   route.sh "<task text>"     or     route.sh < brief.md
#
# Prints one JSON object:
#   {"model","confidence","probabilities","signals":{...},"policy","jev_model","prompt_tokens"}
# Exits non-zero on any failure (no key, network, timeout, bad answer) so the
# caller can fall back to its own judgement. Never prints the key.
#
# The tier definitions are Claudette's (agents/claudette.md, model-choice
# bullet), lightly adapted. This encodes her policy; it does not invent one.
# Policy after Jev:
#   confidence < JEV_ROUTE_MIN_CONF (0.6)                       -> one tier up
#   security_or_high_blast_radius or review_of_nontrivial_diff
#     >= JEV_ROUTE_SIGNAL_MIN (0.7)                             -> at least opus
set -euo pipefail

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JEV_HOOK=${JEV_HOOK:-route}
# shellcheck source=lib.sh
. "$JEV_DIR/lib.sh"

jev_disabled && exit 3

if [ $# -gt 0 ]; then task=$*; else task=$(cat); fi
[ -n "${task//[[:space:]]/}" ] || {
  echo "route.sh: empty task" >&2
  exit 2
}

# Briefs put goal and criteria first; keep the head if one is ever huge.
max=$(jev_state_budget_chars 2500)
task=${task:0:$max}

req=$(jq -n --arg task "$task" --arg model "$JEV_MODEL" '{
  model: $model,
  state: {task: $task},
  questions: {
    tier: {
      type: "choice",
      instructions: "`task` is a brief for a Claude subagent. Pick the lightest model tier that will get `task` right in one pass. A retry or escalation costs more than starting one tier up, so when in doubt pick the higher tier.",
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
    review_of_nontrivial_diff: {type: "noul", instructions: "`task` asks for a review of a non-trivial code change (a diff, branch or pull request)."}
  }
}')

resp=$(jev_call <<<"$req") || exit 1

jq -e -c \
  --argjson min_conf "${JEV_ROUTE_MIN_CONF:-0.6}" \
  --argjson sig_min "${JEV_ROUTE_SIGNAL_MIN:-0.7}" '
  def rank: {haiku: 0, sonnet: 1, opus: 2}[.];
  def name: ["haiku", "sonnet", "opus"][.];
  . as $r
  | .answers as $a
  | ($a.tier.choice | rank) as $base
  | ({ambiguous, needs_research, mechanical, cross_cutting,
      security_or_high_blast_radius, review_of_nontrivial_diff}
     | with_entries(.value = $a[.key].noul)) as $sig
  | (if $a.tier.confidence < $min_conf then [$base + 1, 2] | min else $base end) as $conf_r
  | (if ($sig.security_or_high_blast_radius >= $sig_min or $sig.review_of_nontrivial_diff >= $sig_min)
     then 2 else 0 end) as $floor
  | ([$conf_r, $floor] | max) as $final
  | {
      model: ($final | name),
      confidence: $a.tier.confidence,
      probabilities: $a.tier.probabilities,
      signals: $sig,
      policy: (if $final == $base then "as_is"
               elif $floor > $conf_r then "bumped_signal"
               else "bumped_low_confidence" end),
      jev_choice: $a.tier.choice,
      jev_model: $r.model,
      prompt_tokens: $r.usage.input_tokens
    }' <<<"$resp"
