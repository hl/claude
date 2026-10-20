#!/usr/bin/env bash
# artifact-hook.sh — tell the parent which model a subagent ran on, and persist
# subagent deliverables and long results as artifacts. Local only: no Jev call,
# in any session.
#
# Registered on two events, same script:
#   PostToolUse (matcher Agent)  an Agent call returned. tool_response is
#                                {status: "completed", agentId, resolvedModel,
#                                content: [{type: "text", text}], ...} for a
#                                foreground agent (from Claude Code 2.1.304 the
#                                report is in handbackReport.text), or
#                                {status: "async_launched", agentId, resolvedModel}
#                                for a background one. The parent gets
#                                additionalContext: "Subagent ran on <resolvedModel>."
#                                (plus "raised from <model> by the Jev Agent hook"
#                                when agent-route.sh changed it), and, when the
#                                result was saved, "Subagent result (<description>)
#                                saved to <path>".
#   SubagentStop                 a background subagent finished (its id is in
#                                background_tasks): its final reply is
#                                last_assistant_message (2.1.302) or, when that is
#                                absent (2.1.304), the last SubagentHandback message
#                                or assistant text in agent_transcript_path. This is
#                                its only save; the parent is told nothing directly
#                                (SubagentStop output would go to the subagent), but
#                                the file is in the artifact index that compaction
#                                re-injects. Foreground agents stop before their
#                                PostToolUse fires and are left to it.
#
# What is saved:
#   - a reply whose first non-empty line is "Artifact: <name>", whatever its
#     length, as <name>.md (<name>-<agentId>.md if another agent already used it);
#   - any other reply longer than JEV_ARTIFACT_MIN_CHARS (2000), as
#     agent-<n>-<slug>-<agentId>.md (the agent id, or the tool_use_id, keeps two
#     same-described agents that finish together apart).
# Files go to $JEV_HOME/artifacts/<session_id>/ via a mktemp file in the same
# directory and a rename, capped at JEV_ARTIFACT_MAX_BYTES (512 KB, cut on a
# character boundary, with a note).
#
# Every PostToolUse(Agent) also logs {action: "ran", tool_use_id, agent_id,
# resolved_model, status, input_model} to route.jsonl. The compaction agent
# (empty agent_type) is skipped. Runs the daily state sweep (lib.sh). Fails
# open; never blocks. JEV_ARTIFACTS=0 turns saving off (the ran line stays).
set -euo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=artifact-hook
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

MIN=${JEV_ARTIFACT_MIN_CHARS:-2000}
CAP=${JEV_ARTIFACT_MAX_BYTES:-524288}
jev_disabled && exit 0

# jq_last_reply <agent transcript>: the agent's last SubagentHandback message, else its last assistant text
jq_last_reply() {
  jq -cR 'fromjson? | select(.type == "assistant") | .message.content[]?
    | if .type == "tool_use" and .name == "SubagentHandback" then {h: (.input.message // "")}
      elif .type == "text" then {t: .text} else empty end' "$1" 2>/dev/null |
    jq -s -r '(map(select(.h)) | last | .h) // (map(select(.t)) | last | .t) // empty' 2>/dev/null || true
}

payload=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$payload")
sid=$(jq -r '.session_id // empty' <<<"$payload")
case $sid in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
JEV_SESSION=$sid
export JEV_SESSION
dir="$JEV_HOME/artifacts/$sid"
jev_sweep "$sid"

# finish [saved-path]: on PostToolUse, tell the parent the model and the path; then exit.
ran=""
finish() {
  if [ "$event" = PostToolUse ] && { [ -n "$ran" ] || [ -n "${1:-}" ]; }; then
    jq -cn --arg r "$ran" --arg p "${1:-}" --arg d "${desc:-}" '{hookSpecificOutput: {hookEventName: "PostToolUse",
      additionalContext: ([if $r != "" then $r else empty end,
        if $p != "" then "Subagent result" + (if $d == "" then "" else " (\($d))" end) + " saved to \($p)" else empty end] | join("\n"))}}'
  fi
  exit 0
}

case $event in
  PostToolUse)
    [ "$(jq -r '.tool_name // empty' <<<"$payload")" = Agent ] || exit 0
    # tool_response is an object for foreground agents; accept a JSON string too.
    resp=$(jq -c '.tool_response | if type == "string" then (fromjson? // {}) else . end | if type == "object" then . else {} end' <<<"$payload")
    tuid=$(jq -r '.tool_use_id // empty' <<<"$payload")
    status=$(jq -r '.status // empty' <<<"$resp")
    agent=$(jq -r '.agentId // empty' <<<"$resp")
    model=$(jq -r '.resolvedModel // empty' <<<"$resp")
    desc=$(jq -r '.tool_input.description // empty' <<<"$payload")
    atype=$(jq -r '.tool_input.subagent_type // .agentType // empty' <<<"$payload")
    # The model that actually ran, for every Agent call, before anything can bail out.
    JEV_HOOK=agent-ran jev_log route.jsonl "$(jq -c '
      (.tool_response | if type == "string" then (fromjson? // {}) else . end | if type == "object" then . else {} end) as $r
      | {action: "ran", tool_use_id: (.tool_use_id // null), agent_id: ($r.agentId // null),
       resolved_model: ($r.resolvedModel // null), status: ($r.status // null),
       subagent_type: (.tool_input.subagent_type // null), input_model: (.tool_input.model // null),
       description: ((.tool_input.description // "")[0:120])}' <<<"$payload")"
    if [ -n "$model" ]; then
      if [ "$status" = async_launched ]; then ran="Background subagent running on $model."; else ran="Subagent ran on $model."; fi
      if [ -n "$tuid" ]; then
        from=$(grep -F "\"tool_use_id\":\"$tuid\"" "$JEV_LOG_DIR/route.jsonl" 2>/dev/null |
          jq -r 'select(.action == "escalated" or .action == "raised_to_route") | .given_model' 2>/dev/null | tail -n 1 || true)
        [ -z "$from" ] || ran="${ran%.} (raised from $from by the Jev Agent hook)."
      fi
    fi
    [ "${JEV_ARTIFACTS:-1}" != 0 ] && [ "$status" = completed ] || finish
    text=$(jq -r 'if (.handbackReport.text | type) == "string" then .handbackReport.text
      else (.content | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") elif type == "string" then . else "" end) end' <<<"$resp")
    ;;
  SubagentStop)
    [ "${JEV_ARTIFACTS:-1}" != 0 ] || exit 0
    atype=$(jq -r '.agent_type // empty' <<<"$payload")
    [ -n "$atype" ] || exit 0 # the compaction agent and prompt suggestions
    agent=$(jq -r '.agent_id // empty' <<<"$payload")
    # Foreground agents are saved by their PostToolUse, which knows the description.
    jq -e --arg a "$agent" 'if has("background_tasks") then any(.background_tasks[]?; .id == $a) else true end' \
      <<<"$payload" >/dev/null || exit 0
    text=$(jq -r '.last_assistant_message // empty' <<<"$payload")
    if [ -z "$text" ]; then
      atp=$(jq -r '.agent_transcript_path // empty' <<<"$payload")
      [ -n "$atp" ] && [ -f "$atp" ] && text=$(jq_last_reply "$atp")
    fi
    desc=$(jq -r --arg a "$agent" '[.background_tasks[]? | select(.id == $a) | .description] | first // empty' <<<"$payload")
    model=""
    tuid=""
    ;;
  *) exit 0 ;;
esac
case $agent$tuid in *[!A-Za-z0-9._-]*) finish ;; esac
[ -n "$text" ] || finish

# "Artifact: <name>" on the first non-empty line: a deliverable, saved whatever its length.
marker=$(printf '%s\n' "$text" | grep -m 1 -v '^[[:space:]]*$' | sed -n 's/^[[:space:]*_]*[Aa]rtifact[*_]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -c 200 || true)
aname=""
if [ -n "$marker" ]; then
  aname=$(printf '%s' "$marker" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/--*/-/g' -e 's/^[-.]*//' -e 's/[-.]*$//' | cut -c1-80)
fi
[ -n "$aname" ] || [ "${#text}" -gt "$MIN" ] || finish

mkdir -p "$dir/.agents"
uid=${agent:-${tuid:-$$}}
mark="$dir/.agents/$uid"
path=""
if [ -f "$mark" ]; then
  path=$(cat "$mark")
  [ -f "$path" ] || path=""
fi
if [ -z "$path" ]; then
  if [ -n "$aname" ]; then
    name=$aname
    # a name another agent already used keeps both: this one gets its id appended
    if [ -e "$dir/$name.md" ]; then name="$name-$uid"; fi
  else
    n=$(($(find "$dir" -maxdepth 1 -name 'agent-*.md' | wc -l) + 1))
    slug=$(printf '%s' "${desc:-$atype}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-48)
    name="agent-$n-${slug:-result}-$uid"
  fi
  tmpf=$(mktemp "$dir/.tmp.XXXXXX")
  {
    printf '<!-- subagent %s (%s%s), %s, %s -->\n' "${agent:-?}" "${atype:-?}" "${model:+, $model}" "$(jev_now)" "${desc:-no description}"
    printf '%s\n' "$text"
  } >"$tmpf"
  size=$(wc -c <"$tmpf" | tr -d ' ')
  if [ "$size" -gt "$CAP" ]; then
    # cut on a character boundary: iconv -c drops a multi-byte character split by head -c
    head -c "$CAP" "$tmpf" | iconv -c -f UTF-8 -t UTF-8 >"$tmpf.cut" 2>/dev/null || head -c "$CAP" "$tmpf" >"$tmpf.cut"
    printf '\n\n[truncated by the Jev artifact hook: %s of %s bytes kept]\n' "$CAP" "$size" >>"$tmpf.cut"
    mv "$tmpf.cut" "$tmpf"
  fi
  mv "$tmpf" "$dir/$name.md"
  path="$dir/$name.md"
  printf '%s\n' "$path" >"$mark.$$" && mv "$mark.$$" "$mark"
  jev_log artifact.jsonl "$(jq -cn --arg e "$event" --arg p "$path" --argjson c "${#text}" --arg a "$agent" --arg m "$aname" \
    '{event: $e, status: "saved", path: $p, chars: $c, agent_id: $a} + (if $m == "" then {} else {marker: $m} end)')"
fi
finish "$path"
