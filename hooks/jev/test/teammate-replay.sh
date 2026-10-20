#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# teammate-replay.sh — replays agent-team teammate lifecycles, captured live from
# Claude Code 2.1.304 (test/evidence/teammate-payloads.jsonl, sanitised into
# fixtures/teammate/), through artifact-hook.sh and compact-session.sh. No API.
#
#   tmux teammate: PostToolUse(Agent) teammate_spawned in the lead, then the
#     teammate's own TeammateIdle (its session_id and transcript_path; the lead
#     comes from ~/.claude/teams/<team>/config.json leadSessionId)
#   in-process teammate: SubagentStop and TeammateIdle in the lead's process
#     (lead session_id, agent_id; transcript under <lead>/subagents/)
#
# Asserts: the teammate's "Artifact: demo" reply is saved in the LEAD's artifact
# directory, INDEX.md gets one line, the lead's next PostToolUse(Agent) announces
# it once, replays are idempotent, SendMessage deliverables are saved, short
# replies are not, the lead is found without a team config, and compaction lists
# the file but not INDEX.md.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FX="$HERE/fixtures/teammate"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID JEV_SCOPE JEV_ARTIFACTS JEV_ARTIFACT_MIN_CHARS
W=$(mktemp -d "${TMPDIR:-/tmp}/jev-team.XXXXXX")
trap 'rm -rf "$W"' EXIT
export JEV_HOME="$W/home" JEV_TEAMS_DIR="$W/teams"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
LEAD=4233033d-a65a-4ed0-b3b6-1c5eb09c4a7d # tmux run: lead
MATE=9c1ef456-bbdd-4f98-b00c-234e738ddd77 # tmux run: the teammate's own session
IPL=9c088b13-f183-4b7f-bf73-de6ddd4f512e  # in-process run: lead
IPA=ademo-inproc-6f7df3a66d2829a9         # in-process run: the teammate's agent id
PD="$W/projects/-tmp-jev-teams"
mkdir -p "$PD/$IPL/subagents" "$JEV_TEAMS_DIR/session-4233033d"
cp "$FX/transcript-tmux.jsonl" "$PD/$MATE.jsonl"
cp "$FX/transcript-inproc.jsonl" "$PD/$IPL/subagents/agent-$IPA.jsonl"
: >"$PD/$IPL.jsonl"
cp "$FX/team-config.json" "$JEV_TEAMS_DIR/session-4233033d/config.json"
# payloads point at the scratch projects dir
fx() { jq -c --arg pd "$PD" '(.transcript_path |= ($pd + "/" + (split("/") | last)))
  | if .agent_transcript_path then .agent_transcript_path |= ($pd + "/" + (split("/") | .[-3:] | join("/"))) else . end' "$FX/$1"; }
hook() { "$J/artifact-hook.sh"; }
ctxof() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"; }
ad="$JEV_HOME/artifacts/$LEAD"
post() { # <session> <tool_use_id> -> a lead's foreground Agent call that returns a short answer
  jq -cn --arg s "$1" --arg t "$2" '{session_id: $s, hook_event_name: "PostToolUse", tool_name: "Agent", tool_use_id: $t,
    tool_input: {description: "say ok", prompt: "Reply ok.", model: "haiku"},
    tool_response: {status: "completed", agentId: "a1b2c3", resolvedModel: "claude-haiku-5-5", content: [{type: "text", text: "ok"}]}}' | hook
}

# --- 1. the spawn: teammate wording, not "Subagent ran on"
o=$(fx spawn-tmux.json | hook)
[ "$(ctxof "$o")" = "Teammate demo-writer spawned (model claude-haiku-5-5)." ] &&
  ok "spawn: teammate_spawned -> \"Teammate demo-writer spawned (model claude-haiku-5-5).\"" || bad "spawn: $o"
o=$(fx spawn-tmux.json | jq -c '.tool_response |= del(.resolvedModel, .model)' | hook)
[ -z "$o" ] && ok "spawn: model unknown -> no note at all" || bad "spawn without model: $o"
jq -e -s 'map(select(.action == "ran")) | length == 2 and all(.status == "teammate_spawned")' "$JEV_HOME/log/route.jsonl" >/dev/null &&
  ok "spawn: ran records keep status teammate_spawned" || bad "spawn: ran records"

# --- 2. tmux teammate goes idle: saved in the lead's directory
o=$(fx idle-tmux.json | hook)
rc=$?
[ "$rc" = 0 ] && [ -z "$o" ] && ok "TeammateIdle: exit 0, no output (nothing goes back to the teammate)" || bad "TeammateIdle output: rc=$rc $o"
[ -f "$ad/demo.md" ] && grep -q '^END-OF-DEMO$' "$ad/demo.md" && head -n 1 "$ad/demo.md" | grep -q '^<!-- teammate demo-writer@session-4233033d (general-purpose, claude-haiku-5-5), ' &&
  ok "TeammateIdle: the teammate's \"Artifact: demo\" reply -> artifacts/<lead>/demo.md" || bad "TeammateIdle: no demo.md in the lead's dir: $(find "$JEV_HOME/artifacts" -type f)"
[ ! -d "$JEV_HOME/artifacts/$MATE" ] && ok "TeammateIdle: nothing under the teammate's own session" || bad "TeammateIdle: wrote under the teammate session"
[ "$(grep -c . "$ad/INDEX.md" 2>/dev/null)" = 1 ] && grep -q -F "teammate demo-writer (reply): $ad/demo.md — Artifact: demo" "$ad/INDEX.md" &&
  ok "TeammateIdle: INDEX.md line: $(sed "s#$W#<tmp>#" "$ad/INDEX.md")" || bad "INDEX.md: $(cat "$ad/INDEX.md" 2>/dev/null)"
grep -q -F "Teammate demo-writer reply saved to $ad/demo.md" "$ad/.pending" 2>/dev/null &&
  ok "TeammateIdle: queued for the lead (.pending)" || bad ".pending: $(cat "$ad/.pending" 2>/dev/null)"
jq -e -s --arg l "$LEAD" 'map(select(.event == "TeammateIdle")) | length == 1 and .[0].session_id == $l and .[0].marker == "demo"' "$JEV_HOME/log/artifact.jsonl" >/dev/null &&
  ok "TeammateIdle: artifact.jsonl record under the lead's session" || bad "artifact.jsonl: $(cat "$JEV_HOME/log/artifact.jsonl")"

# --- 3. the same idle again (a teammate idles after every turn): idempotent
fx idle-tmux.json | hook >/dev/null
[ "$(find "$ad" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" = 2 ] && [ "$(grep -c . "$ad/INDEX.md")" = 1 ] && [ "$(grep -c . "$ad/.pending")" = 1 ] &&
  ok "replay: same turn again -> no second file, index line or announcement" || bad "replay: $(ls "$ad"; cat "$ad/INDEX.md" "$ad/.pending")"

# --- 4. the lead's next Agent call announces it, once
o=$(post "$LEAD" toolu_next1)
c=$(ctxof "$o")
[ "$(printf '%s\n' "$c" | head -n 1)" = "Subagent ran on claude-haiku-5-5." ] && printf '%s\n' "$c" | grep -q -F "Teammate demo-writer reply saved to $ad/demo.md" && [ ! -e "$ad/.pending" ] &&
  ok "lead's next PostToolUse(Agent): \"Teammate demo-writer reply saved to <path>\" reaches the lead" || bad "announce: $c"
o=$(post "$LEAD" toolu_next2)
[ "$(ctxof "$o")" = "Subagent ran on claude-haiku-5-5." ] && ok "announced once only" || bad "announced twice: $o"

# --- 5. in-process teammate: SubagentStop left alone, TeammateIdle saves under the lead
ipd="$JEV_HOME/artifacts/$IPL"
fx subagentstop-inproc.json | hook >/dev/null
[ ! -e "$ipd/demo.md" ] && ok "in-process: the teammate's SubagentStop (task id != agent_id) saves nothing" || bad "in-process SubagentStop saved"
fx idle-inproc.json | hook >/dev/null
[ -f "$ipd/demo.md" ] && grep -q 'in-process demo deliverable' "$ipd/demo.md" && grep -q -F 'teammate demo-inproc (reply)' "$ipd/INDEX.md" &&
  ok "in-process: TeammateIdle (lead process, agent_id) -> <lead>/subagents transcript -> artifacts/<lead>/demo.md (lead from the team name, no config)" ||
  bad "in-process idle: $(find "$JEV_HOME/artifacts/$IPL" 2>/dev/null)"

# --- 6. no team config: the lead from session-<8> + the lead's transcript in the projects dir
H2="$W/home2"
rm -f "$JEV_TEAMS_DIR/session-4233033d/config.json"
: >"$PD/$LEAD.jsonl"
fx idle-tmux.json | JEV_HOME="$H2" hook >/dev/null
[ -f "$H2/artifacts/$LEAD/demo.md" ] && ok "no team config: lead found as the one <projects>/4233033d*.jsonl" || bad "fallback lead: $(find "$H2" -type f)"
rm -f "$PD/$LEAD.jsonl"
fx idle-tmux.json | JEV_HOME="$W/home3" hook >/dev/null
[ ! -d "$W/home3/artifacts/$LEAD" ] && jq -e -s 'any(.status == "no_lead")' "$W/home3/log/artifact.jsonl" >/dev/null &&
  ok "no config and no lead transcript: nothing saved, no_lead logged" || bad "no lead: $(find "$W/home3" -type f)"
cp "$FX/team-config.json" "$JEV_TEAMS_DIR/session-4233033d/config.json"

# --- 7. a later turn: a long SendMessage to team-lead is saved; the short final reply is not
long=$(printf 'Finding %s: the retry loop drops the last page.\n' $(seq 1 60))
jq -cn --arg long "$long" '
  {type: "user", uuid: "u-0002", message: {role: "user", content: "<teammate-message teammate_id=\"team-lead\">\nNow survey the retry loop.\n</teammate-message>"}},
  {type: "assistant", uuid: "a-0003", message: {role: "assistant", model: "claude-haiku-5-5", content: [{type: "tool_use", id: "toolu_01SendMsgAAAA1234567890", name: "SendMessage",
     input: {to: "team-lead", summary: "Retry loop survey", message: $long}}]}},
  {type: "user", uuid: "u-0004", message: {role: "user", content: [{type: "tool_result", tool_use_id: "toolu_01SendMsgAAAA1234567890", content: "sent"}]}},
  {type: "assistant", uuid: "a-0005", message: {role: "assistant", model: "claude-haiku-5-5", content: [{type: "text", text: "Sent the survey to the lead."}]}}' >>"$PD/$MATE.jsonl"
fx idle-tmux.json | hook >/dev/null
f=$(find "$ad" -maxdepth 1 -name 'agent-*-demo-writer-retry-loop-survey-*.md' | head -n 1)
[ -n "$f" ] && grep -q 'Finding 60' "$f" && [ "$(find "$ad" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" = 3 ] &&
  grep -q -F "teammate demo-writer (message): $f" "$ad/INDEX.md" && grep -q -F "Teammate demo-writer message (Retry loop survey) saved to $f" "$ad/.pending" &&
  ok "SendMessage turn: the 3 KB message -> $(basename "$f"); the short final reply and the earlier turn are not saved again" ||
  bad "SendMessage turn: $(ls "$ad"; cat "$ad/INDEX.md")"
# the same text as final reply and as SendMessage: one file
jq -cn --arg long "${long//retry/paging}" '
  {type: "user", uuid: "u-0006", message: {role: "user", content: "<teammate-message teammate_id=\"team-lead\">\nAnd paging?\n</teammate-message>"}},
  {type: "assistant", uuid: "a-0007", message: {role: "assistant", model: "claude-haiku-5-5", content: [{type: "tool_use", id: "toolu_01SendMsgBBBB1234567890", name: "SendMessage", input: {to: "team-lead", message: $long}}]}},
  {type: "user", uuid: "u-0008", message: {role: "user", content: [{type: "tool_result", tool_use_id: "toolu_01SendMsgBBBB1234567890", content: "sent"}]}},
  {type: "assistant", uuid: "a-0009", message: {role: "assistant", model: "claude-haiku-5-5", content: [{type: "text", text: $long}]}}' >>"$PD/$MATE.jsonl"
fx idle-tmux.json | hook >/dev/null
[ "$(find "$ad" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" = 4 ] && ok "a reply that repeats its own SendMessage is saved once" || bad "duplicate reply: $(ls "$ad")"
# the race seen live: TeammateIdle fires before the turn's final message is on disk
jq -cn '{type: "user", uuid: "u-0010", message: {role: "user", content: "<teammate-message teammate_id=\"team-lead\">\nLast one.\n</teammate-message>"}}' >>"$PD/$MATE.jsonl"
fx idle-tmux.json | hook >/dev/null &
hp=$!
sleep 0.6
jq -cn '{type: "assistant", uuid: "a-0011", message: {role: "assistant", model: "claude-haiku-5-5", content: [{type: "text", text: "Artifact: late-flush\nWritten after the idle event."}]}}' >>"$PD/$MATE.jsonl"
wait "$hp"
[ -f "$ad/late-flush.md" ] && ok "flush race: the final message lands 0.6 s after TeammateIdle -> the hook waits and saves late-flush.md" || bad "flush race: $(ls "$ad")"
# a reply missed at its own idle is caught at the next one (the last 3 turns are looked at)
jq -cn '{type: "user", uuid: "u-0012", message: {role: "user", content: "<teammate-message teammate_id=\"team-lead\">\nMissed?\n</teammate-message>"}},
  {type: "assistant", uuid: "a-0013", message: {role: "assistant", model: "claude-haiku-5-5", content: [{type: "text", text: "Artifact: missed-once\nNo idle saw this turn."}]}},
  {type: "user", uuid: "u-0014", message: {role: "user", content: "<teammate-message teammate_id=\"team-lead\">\nThanks.\n</teammate-message>"}},
  {type: "assistant", uuid: "a-0015", message: {role: "assistant", model: "claude-haiku-5-5", content: [{type: "text", text: "You are welcome."}]}}' >>"$PD/$MATE.jsonl"
fx idle-tmux.json | hook >/dev/null
[ -f "$ad/missed-once.md" ] && ok "a turn whose idle saved nothing is saved at the next idle" || bad "missed turn: $(ls "$ad")"
JEV_ARTIFACTS=0 JEV_HOME="$W/home4" hook < <(fx idle-tmux.json) >/dev/null
[ ! -d "$W/home4/artifacts" ] && ok "JEV_ARTIFACTS=0: TeammateIdle saves nothing" || bad "JEV_ARTIFACTS=0 saved"

# --- 8. compaction: the index lists the teammate files, not INDEX.md
o=$(jq -cn --arg s "$LEAD" '{session_id: $s, hook_event_name: "SessionStart", source: "compact", cwd: "/tmp"}' | "$J/compact-session.sh")
c=$(ctxof "$o")
printf '%s\n' "$c" | grep -q -F "$ad/demo.md" && ! printf '%s\n' "$c" | grep -q 'INDEX\.md' &&
  ok "compaction: artifact index lists demo.md and the SendMessage file, not INDEX.md" || bad "compaction index: $c"

echo "teammate-replay: $fails failure(s)"
[ "$fails" -eq 0 ]
