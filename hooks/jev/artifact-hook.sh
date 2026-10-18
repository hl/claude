#!/usr/bin/env bash
# artifact-hook.sh — persist long subagent results as artifacts.
#
# Registered on two events, same script:
#   PostToolUse (matcher Agent)  a foreground Agent call finished: tool_response
#                                is {status: "completed", content: [{type: "text",
#                                text}], agentId, resolvedModel, ...}. If the
#                                result is longer than JEV_ARTIFACT_MIN_CHARS
#                                (2000), it is saved (unless SubagentStop already
#                                did) and the parent gets one line of
#                                additionalContext: "Subagent result (<description>)
#                                saved to <path>".
#   SubagentStop                 a background subagent finished (its id is in
#                                background_tasks): last_assistant_message is its
#                                final reply. Background agents (tool_response
#                                status "async_launched") have no PostToolUse
#                                result, so this is their only save; the parent
#                                is told nothing directly (SubagentStop output
#                                would go to the subagent), but the file is in
#                                the artifact index that compaction re-injects.
#                                Foreground agents stop before their PostToolUse
#                                fires and are left to it (it has the description).
# Files: ~/.claude/jev/artifacts/<session_id>/agent-<n>-<slug>.md, and an
# `artifact` fact in the ledger. The compaction agent (empty agent_type) and
# subagents' own nested state are skipped. Local only; fails open; never blocks.
# Verified on Claude Code 2.1.302 (test/evidence/payload-*.json).
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=artifact-hook
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MIN=${JEV_ARTIFACT_MIN_CHARS:-2000}
[ "${JEV_ARTIFACTS:-1}" = 0 ] && exit 0
jev_disabled && exit 0

payload=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$payload")
sid=$(jq -r '.session_id // empty' <<<"$payload")
case $sid in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
JEV_SESSION=$sid
export JEV_SESSION
dir="$JEV_HOME/artifacts/$sid"

case $event in
  PostToolUse)
    [ "$(jq -r '.tool_name // empty' <<<"$payload")" = Agent ] || exit 0
    # tool_response is an object for foreground agents; accept a JSON string too.
    resp=$(jq -c '.tool_response | if type == "string" then (fromjson? // {}) else . end' <<<"$payload")
    [ "$(jq -r '.status // empty' <<<"$resp")" = completed ] || exit 0
    agent=$(jq -r '.agentId // empty' <<<"$resp")
    text=$(jq -r '.content | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") elif type == "string" then . else "" end' <<<"$resp")
    desc=$(jq -r '.tool_input.description // empty' <<<"$payload")
    atype=$(jq -r '.tool_input.subagent_type // .agentType // empty' <<<"$payload")
    model=$(jq -r '.resolvedModel // empty' <<<"$resp")
    ;;
  SubagentStop)
    atype=$(jq -r '.agent_type // empty' <<<"$payload")
    [ -n "$atype" ] || exit 0 # the compaction agent and prompt suggestions
    agent=$(jq -r '.agent_id // empty' <<<"$payload")
    # Foreground agents are saved by their PostToolUse, which knows the description.
    jq -e --arg a "$agent" 'if has("background_tasks") then any(.background_tasks[]?; .id == $a) else true end' \
      <<<"$payload" >/dev/null || exit 0
    text=$(jq -r '.last_assistant_message // empty' <<<"$payload")
    desc=$(jq -r --arg a "$agent" '[.background_tasks[]? | select(.id == $a) | .description] | first // empty' <<<"$payload")
    model=""
    ;;
  *) exit 0 ;;
esac
case $agent in *[!A-Za-z0-9._-]*) exit 0 ;; esac
[ "${#text}" -gt "$MIN" ] || exit 0

mkdir -p "$dir/.agents"
mark="$dir/.agents/${agent:-none}"
path=""
if [ -n "$agent" ] && [ -f "$mark" ]; then
  path=$(cat "$mark")
  [ -f "$path" ] || path=""
fi
if [ -z "$path" ]; then
  n=$(($(find "$dir" -maxdepth 1 -name 'agent-*.md' | wc -l) + 1))
  slug=$(printf '%s' "${desc:-$atype}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-48)
  name="agent-$n-${slug:-result}"
  {
    printf '<!-- subagent %s (%s%s), %s, %s -->\n' "${agent:-?}" "${atype:-?}" "${model:+, $model}" "$(jev_now)" "${desc:-no description}"
    printf '%s\n' "$text"
  } >"$dir/$name.md.tmp" && mv "$dir/$name.md.tmp" "$dir/$name.md"
  path="$dir/$name.md"
  [ -n "$agent" ] && printf '%s\n' "$path" >"$mark"
  "$JEV_DIR/ledger.sh" --add "$sid" artifact 2.5 "Artifact $name: $path — subagent result: ${desc:-$atype}" "" >/dev/null 2>&1 || true
  jev_log artifact.jsonl "$(jq -cn --arg e "$event" --arg p "$path" --argjson c "${#text}" --arg a "$agent" '{event: $e, status: "saved", path: $p, chars: $c, agent_id: $a}')"
fi

if [ "$event" = PostToolUse ]; then
  jq -cn --arg p "$path" --arg d "$desc" '{hookSpecificOutput: {hookEventName: "PostToolUse",
    additionalContext: ("Subagent result" + (if $d == "" then "" else " (\($d))" end) + " saved to \($p)")}}'
fi
