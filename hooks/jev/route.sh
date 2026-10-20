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
#   kind           implement | review | investigate | fix-ci | address-comments |
#                  poll | fetch | lookup (the last three go to haiku)
#   diff_size      for reviews, e.g. "+1240/-380 in 23 files"
#   requested, poll_verb  set by the Agent hook (policy.jq hook_context) for the
#                  haiku-keep rule; never sent to Jev
#
# Prints one JSON object {id, model, reviewer_model, confidence, probabilities,
# policy: [reasons]} and logs it, with the context and without the brief, to
# $JEV_HOME/log/route.jsonl. Put the id in the brief: the Agent hook then takes
# this answer instead of scoring the brief again. Exits non-zero on any failure
# (no key, network, timeout, bad answer) so the caller can fall back to opus.
#
# The policy is opus-first (policy.jq): haiku only for poll/fetch/lookup, when
# Jev is sure the task is mechanical and safe, or (Agent hook) to keep a requested
# haiku Jev is sure about or that reads as a poll; sonnet only when P(opus) <= 0.15
# with no security or review signal. One Jev request, about 2k tokens.
#
# The session is logged from $CLAUDE_CODE_SESSION_ID when the caller has it
# (Claude Code exports it to Bash tool commands).
set -euo pipefail

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JEV_HOOK=${JEV_HOOK:-route}
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"
# a CLI run from Claude's Bash tool: attribute its records to that session
[ -n "$JEV_SESSION" ] || JEV_SESSION=${CLAUDE_CODE_SESSION_ID:-}
case $JEV_SESSION in *[!A-Za-z0-9._-]*) JEV_SESSION= ;; esac

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
st=$(jq -Rs -c -L "$JEV_DIR" 'include "anchors"; strip_anchors' <<<"$task")
task=$(jq -r '.text' <<<"$st")
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
  state: {task: $task, context: ($ctx | del(.risky_paths, .requested, .poll_verb))},
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
    mechanical: {type: "noul", instructions: "`task` is mechanical: its exact result is fully determined by the description."},
    security_or_high_blast_radius: {type: "noul", instructions: "`task` changes or reviews security-sensitive code (auth, secrets, permissions, crypto, payments) or code where a mistake would break production, corrupt data or affect many users. Read-only lookups and reports do not count."},
    review_of_nontrivial_diff: {type: "noul", instructions: "`task` asks for a review of a non-trivial code change (a diff, branch or pull request)."},
    nontrivial_change: {type: "noul", instructions: "Carrying out `task` produces a code or configuration change that is non-trivial to review: more than a few lines of logic, or several files."}
  }
}')

resp=$(jev_call <<<"$req") || exit 1

id="r$(date +%s)-$$-$RANDOM"
out=$(jq -e -c -L "$JEV_DIR" --argjson ctx "$ctx" --arg id "$id" '
  include "policy";
  .answers as $a
  | ({probabilities: $a.tier.probabilities, confidence: $a.tier.confidence, ctx: $ctx,
      signals: ({mechanical, security_or_high_blast_radius, review_of_nontrivial_diff, nontrivial_change}
                | with_entries(.value = $a[.key].noul))} | route_policy) as $d
  | {id: $id, model: $d.model, reviewer_model: $d.reviewer_model,
     confidence: $a.tier.confidence, probabilities: $a.tier.probabilities, policy: $d.policy}' <<<"$resp") || exit 1

if [ "${JEV_ROUTE_NO_LOG:-0}" != 1 ]; then
  jev_log route.jsonl "$(jq -c --argjson ctx "$ctx" '{action: "route", context: $ctx} + .' <<<"$out")"
fi
printf '%s\n' "$out"
