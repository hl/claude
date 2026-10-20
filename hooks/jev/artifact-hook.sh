#!/usr/bin/env bash
# artifact-hook.sh — tell the parent which model a subagent ran on, and persist
# subagent and teammate deliverables and long results as artifacts. Local only:
# no Jev call, in any session.
#
# Registered on three events, same script:
#   PostToolUse (matcher Agent)  an Agent call returned. tool_response is
#                                {status: "completed", agentId, resolvedModel,
#                                content: [{type: "text", text}], ...} for a
#                                foreground agent (from Claude Code 2.1.304 the
#                                report is in handbackReport.text),
#                                {status: "async_launched", agentId, resolvedModel}
#                                for a background one, or {status: "teammate_spawned",
#                                name, team_name, model, resolvedModel, ...} for an
#                                agent-team teammate. The parent gets additionalContext:
#                                "Subagent ran on <resolvedModel>." (completed only;
#                                plus "raised from <model> by the Jev Agent hook" when
#                                agent-route.sh changed it), "Background subagent
#                                running on <model>.", or "Teammate <name> spawned
#                                (model <m>)."; when the result was saved, "Subagent
#                                result (<description>) saved to <path>"; and any
#                                teammate saves not yet announced (.pending, below;
#                                only on the lead's own calls, which have no agent_id).
#   SubagentStop                 a background subagent finished (its id is in
#                                background_tasks): its final reply is
#                                last_assistant_message (2.1.302) or, when that is
#                                absent (2.1.304), the last SubagentHandback message
#                                or assistant text in agent_transcript_path. This is
#                                its only save; the parent is told nothing directly
#                                (SubagentStop output would go to the subagent), but
#                                the file is in the artifact index that compaction
#                                re-injects. Foreground agents stop before their
#                                PostToolUse fires and are left to it; in-process
#                                teammates (background task id != agent_id) are left
#                                to TeammateIdle.
#   TeammateIdle                 an agent-team teammate ended a turn. It fires in the
#                                teammate's own process (tmux/iTerm teammates: its own
#                                session_id and transcript_path) or, for in-process
#                                teammates, in the lead's (lead session_id, agent_id,
#                                the teammate transcript under <lead>/subagents/). The
#                                payload has teammate_name and team_name; the lead
#                                session is leadSessionId in ~/.claude/teams/<team>/
#                                config.json. From the teammate's last turn, its final
#                                reply and every SendMessage to team-lead are saved to
#                                the LEAD's artifact directory. No hook can reach the
#                                lead then (TeammateIdle output goes to the teammate),
#                                so the path goes to the lead's INDEX.md, to the
#                                artifact index compaction re-injects, and to .pending,
#                                which the lead's next PostToolUse(Agent) announces.
#
# What is saved:
#   - a reply whose first non-empty line is "Artifact: <name>", whatever its
#     length, as <name>.md (<name>-<id>.md if another agent already used it);
#   - any other reply longer than JEV_ARTIFACT_MIN_CHARS (2000), as
#     agent-<n>-<slug>-<id>.md (the agent id, the tool_use_id, or for a teammate
#     its name and the message id, keeps two same-described results apart).
# Files go to $JEV_HOME/artifacts/<session_id>/ via a mktemp file in the same
# directory and a rename, capped at JEV_ARTIFACT_MAX_BYTES (512 KB, cut on a
# character boundary, with a note). Each new file adds a line to INDEX.md there.
#
# Every PostToolUse(Agent) also logs {action: "ran", tool_use_id, agent_id,
# resolved_model, status, input_model} to route.jsonl. The compaction agent
# (empty agent_type) is skipped. Runs the daily state sweep (lib.sh). Fails
# open; never blocks. JEV_ARTIFACTS=0 turns saving off (the ran line stays).
# JEV_TEAMS_DIR overrides ${CLAUDE_CONFIG_DIR:-~/.claude}/teams.
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

# jq_turn_items <teammate transcript>: first {done: <the last turn ends in text>},
# then one JSON line per result of the teammate's last JEV_TEAMMATE_TURNS (3) turns
# (a turn is the records after a prompt): its final reply (the turn's last content
# block, when that is text) and each SendMessage to team-lead. Older turns are
# looked at again so a reply that was not yet on disk at its own idle is saved at
# the next one; the marks make that idempotent.
# {key (message uuid or tool_use id, shortened), kind: reply|message, text, summary, model}
jq_turn_items() {
  jq -cR 'fromjson? | select(.type == "user" or .type == "assistant")
    | (.message.content | if type == "string" then [{type: "text", text: .}] elif type == "array" then . else [] end) as $c
    | if .type == "user" then {p: any($c[]; .type != "tool_result")}
      else {u: (.uuid // ""), m: (.message.model // null), b: [$c[]
        | if .type == "text" then {text}
          elif .type == "tool_use" and .name == "SendMessage" then {id: (.id // ""), send: .input}
          elif .type == "tool_use" then {tool: true} else empty end]} end' < <(tail -c "${JEV_TEAMMATE_TAIL:-1048576}" "$1" 2>/dev/null) 2>/dev/null |
    jq -s -c --argjson turns "${JEV_TEAMMATE_TURNS:-3}" '
      def short: if test("^toolu_") then .[6:] | .[-16:] else .[0:8] end | gsub("[^A-Za-z0-9_-]"; "");
      def results:
        map(select(has("b"))) as $as
        | ($as | map(.m // empty) | last) as $model
        | [$as[] | .u as $u | .b[] | . + {u: $u}] as $blocks
        | [$blocks[] | select(.send) | .send as $s
           | select((($s.to // $s.recipient) // "") == "team-lead")
           | {key: (.id | short), kind: "message", summary: ($s.summary // ""), model: $model,
              text: ([$s.message, $s.content] | map(select(type == "string" and length > 0)) | first // "")}
           | select(.text != "")] as $msgs
        | ($blocks | last) as $final
        | {done: (($final.text // null) != null),
           items: ((if $final.text and ([$msgs[].text] | index($final.text) | not)
             then [{key: ($final.u | short), kind: "reply", summary: "", model: $model, text: $final.text}] else [] end) + $msgs)};
      . as $r
      | ([-1] + [range(length) | select($r[.].p == true)]) as $starts
      | [$starts[-$turns:][] as $s | ($starts | map(select(. > $s)) | first // ($r | length)) as $e | $r[($s + 1):$e] | results] as $t
      | {done: (($t | last | .done) // false)}, ($t[].items[])' 2>/dev/null || true
}

# team_lead <team> <payload session> <transcript path> <teammate>: the lead session id of a team
# (a config that does not list the teammate is not trusted: team names can be reused)
team_lead() {
  local cfg lead="" pre m
  cfg="${JEV_TEAMS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams}/$1/config.json"
  [ -f "$cfg" ] && lead=$(jq -r --arg n "$4" 'select(any(.members[]?; .name == $n)) | .leadSessionId // empty' "$cfg" 2>/dev/null || true)
  if [ -z "$lead" ]; then
    # default team names are session-<first 8 of the lead's id>
    case $1 in session-????????) pre=${1#session-} ;; *) pre="" ;; esac
    if [ -n "$pre" ]; then
      case $2 in "$pre"*) lead=$2 ;; esac
      if [ -z "$lead" ] && [ -n "$3" ]; then
        m=$(find "$(dirname "$3")" -maxdepth 1 -name "$pre*.jsonl" 2>/dev/null | head -n 2)
        [ "$(printf '%s\n' "$m" | grep -c .)" = 1 ] && lead=$(basename "$m" .jsonl)
      fi
    fi
  fi
  case $lead in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$lead"
}

payload=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$payload")
sid=$(jq -r '.session_id // empty' <<<"$payload")
case $sid in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
JEV_SESSION=$sid
export JEV_SESSION
dir="$JEV_HOME/artifacts/$sid"
jev_sweep "$sid"

# save <text> <uid> <who>: save one result under $dir unless <uid> already was (path= set either way;
# empty when nothing was saved). Uses $desc, $atype, $model, $agent for the header and the name.
save() {
  local text=$1 uid=$2 who=$3 marker aname mark name n slug tmpf size first
  path=""
  [ -n "$text" ] || return 0
  # "Artifact: <name>" on the first non-empty line: a deliverable, saved whatever its length.
  marker=$(printf '%s\n' "$text" | grep -m 1 -v '^[[:space:]]*$' | sed -n 's/^[[:space:]*_]*[Aa]rtifact[*_]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -c 200 || true)
  aname=""
  if [ -n "$marker" ]; then
    aname=$(printf '%s' "$marker" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/--*/-/g' -e 's/^[-.]*//' -e 's/[-.]*$//' | cut -c1-80)
  fi
  [ -n "$aname" ] || [ "${#text}" -gt "$MIN" ] || return 0
  mkdir -p "$dir/.agents"
  mark="$dir/.agents/$uid"
  if [ -f "$mark" ]; then
    path=$(cat "$mark")
    [ -f "$path" ] || path=""
    return 0
  fi
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
    printf '<!-- %s %s (%s%s), %s, %s -->\n' "$(case $who in teammate*) echo teammate ;; *) echo subagent ;; esac)" "${agent:-?}" "${atype:-?}" "${model:+, $model}" "$(jev_now)" "${desc:-no description}"
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
  # INDEX.md: one line per saved file, oldest first (a single short append, atomic)
  first=$(printf '%s\n' "$text" | grep -m 1 -v '^[[:space:]]*$' | tr -d '\r' | cut -c1-100 || true)
  printf -- '- %s %s: %s — %s\n' "$(jev_now)" "$who" "$path" "$first" >>"$dir/INDEX.md"
  jev_log artifact.jsonl "$(jq -cn --arg e "$event" --arg p "$path" --argjson c "${#text}" --arg a "$agent" --arg m "$aname" --arg w "$who" --arg wt "${waited:-}" \
    '{event: $e, status: "saved", path: $p, chars: $c, agent_id: $a, who: $w} + (if $m == "" then {} else {marker: $m} end) + (if $wt == "" then {} else {waited_s: ($wt | tonumber)} end)')"
}

# finish [saved-path]: on PostToolUse, tell the parent the model, the path and any
# teammate saves not yet announced; then exit.
ran=""
finish() {
  local pend=""
  if [ "$event" = PostToolUse ]; then
    # only the lead's own Agent calls: an in-process teammate's carry its agent_id
    if [ -z "$(jq -r '.agent_id // empty' <<<"$payload")" ] && [ -s "$dir/.pending" ] &&
      mv "$dir/.pending" "$dir/.pending.$$" 2>/dev/null; then
      pend=$(cat "$dir/.pending.$$" 2>/dev/null || true)
      rm -f "$dir/.pending.$$"
    fi
    if [ -n "$ran" ] || [ -n "${1:-}" ] || [ -n "$pend" ]; then
      jq -cn --arg r "$ran" --arg p "${1:-}" --arg d "${desc:-}" --arg pend "$pend" '{hookSpecificOutput: {hookEventName: "PostToolUse",
        additionalContext: ([if $r != "" then $r else empty end,
          if $p != "" then "Subagent result" + (if $d == "" then "" else " (\($d))" end) + " saved to \($p)" else empty end,
          if $pend != "" then $pend | rtrimstr("\n") else empty end] | join("\n"))}}'
    fi
  fi
  exit 0
}

agent="" tuid="" desc="" atype="" model=""
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
    from=""
    if [ -n "$tuid" ]; then
      from=$(grep -F "\"tool_use_id\":\"$tuid\"" "$JEV_LOG_DIR/route.jsonl" 2>/dev/null |
        jq -r 'select(.action == "escalated" or .action == "raised_to_route") | .given_model' 2>/dev/null | tail -n 1 || true)
    fi
    case $status in
      completed) [ -z "$model" ] || ran="Subagent ran on $model${from:+ (raised from $from by the Jev Agent hook)}." ;;
      async_launched) [ -z "$model" ] || ran="Background subagent running on $model${from:+ (raised from $from by the Jev Agent hook)}." ;;
      teammate_spawned)
        # its result comes later, as a teammate message; TeammateIdle saves it
        tname=$(jq -r '.name // .teammate_id // empty' <<<"$resp" | tr -cd 'A-Za-z0-9._@-' | cut -c1-64)
        tmodel=$(jq -r '.resolvedModel // .model // empty' <<<"$resp")
        [ -z "$tname" ] || [ -z "$tmodel" ] || ran="Teammate $tname spawned (model $tmodel${from:+, raised from $from by the Jev Agent hook})."
        ;;
    esac
    [ "${JEV_ARTIFACTS:-1}" != 0 ] && [ "$status" = completed ] || finish
    text=$(jq -r 'if (.handbackReport.text | type) == "string" then .handbackReport.text
      else (.content | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") elif type == "string" then . else "" end) end' <<<"$resp")
    case $agent$tuid in *[!A-Za-z0-9._-]*) finish ;; esac
    save "$text" "${agent:-${tuid:-$$}}" "subagent${desc:+ ($desc)}"
    finish "$path"
    ;;
  SubagentStop)
    [ "${JEV_ARTIFACTS:-1}" != 0 ] || exit 0
    atype=$(jq -r '.agent_type // empty' <<<"$payload")
    [ -n "$atype" ] || exit 0 # the compaction agent and prompt suggestions
    agent=$(jq -r '.agent_id // empty' <<<"$payload")
    case $agent in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
    # Foreground agents are saved by their PostToolUse, which knows the description.
    jq -e --arg a "$agent" 'if has("background_tasks") then any(.background_tasks[]?; .id == $a) else true end' \
      <<<"$payload" >/dev/null || exit 0
    text=$(jq -r '.last_assistant_message // empty' <<<"$payload")
    if [ -z "$text" ]; then
      atp=$(jq -r '.agent_transcript_path // empty' <<<"$payload")
      [ -n "$atp" ] && [ -f "$atp" ] && text=$(jq_last_reply "$atp")
    fi
    desc=$(jq -r --arg a "$agent" '[.background_tasks[]? | select(.id == $a) | .description] | first // empty' <<<"$payload")
    save "$text" "$agent" "background subagent${desc:+ ($desc)}"
    ;;
  TeammateIdle)
    [ "${JEV_ARTIFACTS:-1}" != 0 ] || exit 0
    team=$(jq -r '.team_name // empty' <<<"$payload")
    tname=$(jq -r '.teammate_name // empty' <<<"$payload")
    case $team in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
    case $tname in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
    tp=$(jq -r '.transcript_path // empty' <<<"$payload")
    aid=$(jq -r '.agent_id // empty' <<<"$payload")
    case $aid in *[!A-Za-z0-9._-]*) exit 0 ;; esac
    # in-process teammates share the lead's process: their transcript sits under the lead's
    if [ -n "$aid" ]; then atp="${tp%.jsonl}/subagents/agent-$aid.jsonl"; else atp=$tp; fi
    [ -n "$atp" ] && [ -f "$atp" ] || exit 0
    if ! lead=$(team_lead "$team" "$sid" "$tp" "$tname"); then
      jev_log artifact.jsonl "$(jq -cn --arg t "$team" --arg n "$tname" '{event: "TeammateIdle", status: "no_lead", team: $t, teammate: $n}')"
      exit 0
    fi
    JEV_SESSION=$lead
    dir="$JEV_HOME/artifacts/$lead"
    agent=${aid:-$tname@$team}
    atype=$(jq -r '.agent_type // empty' <<<"$payload")
    tsid=${aid:-$sid}
    # TeammateIdle can fire before the turn's last message is on disk (seen live,
    # about 0.1 s): wait up to JEV_TEAMMATE_WAIT (3) s for the last turn to end in
    # text, re-reading the transcript's tail only when its size changes, and giving
    # up once the size has not changed for 0.8 s (a turn that ended without text).
    fsize() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }
    items=$(jq_turn_items "$atp")
    tdone=$(head -n 1 <<<"$items" | jq -r '.done' 2>/dev/null || true)
    size=$(fsize "$atp")
    i=0 still=0
    while [ "$tdone" != true ] && [ "$i" -lt "$((${JEV_TEAMMATE_WAIT:-3} * 5))" ] && [ "$still" -lt 4 ]; do
      sleep 0.2
      i=$((i + 1))
      now=$(fsize "$atp")
      if [ "$now" = "$size" ]; then
        still=$((still + 1))
        continue
      fi
      still=0
      size=$now
      items=$(jq_turn_items "$atp")
      tdone=$(head -n 1 <<<"$items" | jq -r '.done' 2>/dev/null || true)
    done
    waited=$(awk -v i="$i" 'BEGIN { printf "%.1f", i * 0.2 }')
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      jq -e 'has("key")' <<<"$item" >/dev/null 2>&1 || continue
      key=$(jq -r '.key' <<<"$item")
      kind=$(jq -r '.kind' <<<"$item")
      summary=$(jq -r '.summary' <<<"$item" | tr -d '\r\n' | cut -c1-80)
      model=$(jq -r '.model // empty' <<<"$item")
      text=$(jq -r '.text' <<<"$item")
      case $key in '' | *[!A-Za-z0-9_-]*) continue ;; esac
      desc="$tname${summary:+: $summary}"
      save "$text" "$tname-${tsid:0:8}-$key" "teammate $tname ($kind)"
      [ -n "$path" ] || continue
      if [ ! -f "$dir/.agents/$tname-${tsid:0:8}-$key.announced" ]; then
        : >"$dir/.agents/$tname-${tsid:0:8}-$key.announced"
        printf 'Teammate %s %s%s saved to %s\n' "$tname" "$kind" "${summary:+ ($summary)}" "$path" >>"$dir/.pending"
      fi
    done <<<"$items"
    ;;
  *) exit 0 ;;
esac
exit 0
