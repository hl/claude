#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# live-teammate.sh — a real agent-team teammate, driven in tmux (teammates get
# their own tmux pane and process). Costs tokens; run with JEV_LIVE=1 via run.sh.
#
# A scratch project wires artifact-hook.sh on PostToolUse(Agent) and TeammateIdle
# (as settings.json does) plus a dump hook, and sets JEV_HOME and
# CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS in its settings env so the teammate's own
# process gets them too. The lead spawns a haiku teammate whose final reply
# starts "Artifact: live-demo", then runs one more Agent call and quotes the hook
# context it got. Proves: TeammateIdle fires in the teammate's process; the reply
# is saved in the LEAD's artifact directory with an INDEX.md line; the lead's
# next PostToolUse(Agent) tells it the path; the spawn gets the teammate wording.
# Writes sanitised evidence to test/evidence/teammate-live.txt.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
EVID="$HERE/evidence/teammate-live.txt"
SCRATCH=${JEV_SCRATCH:-/tmp/jev-live-team}
MODEL=${JEV_LIVE_PARENT_MODEL:-sonnet}
SESS=jevt$$
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/.claude" "$SCRATCH/dump"
export JEV_HOME="$SCRATCH/jevhome"
cat >"$SCRATCH/dump.sh" <<'EOF'
#!/usr/bin/env bash
# Record each hook's stdin, named by start time and event.
p=$(cat)
ts=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
printf '%s' "$p" >"$(dirname "$0")/dump/$ts-$(jq -r '.hook_event_name // "x"' <<<"$p").json"
EOF
chmod +x "$SCRATCH/dump.sh"
jq -n --arg d "$SCRATCH/dump.sh" --arg j "$J" --arg home "$JEV_HOME" '
  def dump: {type: "command", command: $d};
  def jev($s): {type: "command", command: "\($j)/\($s)", timeout: 10};
  {env: {JEV_HOME: $home, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"},
   hooks: {
    PostToolUse: [{matcher: "Agent", hooks: [dump, jev("artifact-hook.sh")]}],
    TeammateIdle: [{hooks: [dump, jev("artifact-hook.sh")]}],
    UserPromptSubmit: [{hooks: [dump]}]}}' >"$SCRATCH/.claude/settings.json"

pane() { tmux capture-pane -p -J -S -300 -t "$SESS" 2>/dev/null; }
say() { # type a line, then submit
  tmux send-keys -t "$SESS" -l "$1"
  sleep 1
  tmux send-keys -t "$SESS" C-m
}
wait_for() { # <function> <seconds>
  local _
  for _ in $(seq 1 "$2"); do
    "$1" && return 0
    sleep 1
  done
  return 1
}
have_index() { find "$JEV_HOME/artifacts" -name INDEX.md 2>/dev/null | grep -q .; }
two_agent_calls() { [ "$(find "$SCRATCH/dump" -name '*-PostToolUse.json' | wc -l)" -ge 2 ]; }

tmux kill-session -t "$SESS" 2>/dev/null
tmux new -d -s "$SESS" -x 200 -y 60 -c "$SCRATCH" "cd '$SCRATCH' && CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --setting-sources project --teammate-mode tmux --model $MODEL"
sleep 8
pane | grep -qi 'trust this folder' && tmux send-keys -t "$SESS" C-m && sleep 3

say 'Spawn one agent-team teammate with the Agent tool: name "live-writer", subagent_type general-purpose, model haiku, description "live demo deliverable". Its prompt: "Do not use any tools. Your final reply must be exactly these three lines: first line Artifact: live-demo, second line The live teammate deliverable., third line END-OF-LIVE-DEMO." Then wait for its message; do not reply to it yet.'
wait_for have_index 240 || echo "WARN: no INDEX.md within 240 s"
sleep 15
say 'Now run one foreground subagent with the Agent tool (no name, model haiku, description "say ok", prompt "Reply with the single word ok."). Then quote verbatim every line of hook additional context you received from that Agent call, one per line, prefixed with HOOK:.'
wait_for two_agent_calls 180 || echo "WARN: second Agent call not seen within 180 s"
sleep 40
pane >"$SCRATCH/pane.txt"
tmux kill-session -t "$SESS" 2>/dev/null

fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
first() { find "$SCRATCH/dump" -name "*-$1.json" | sort | head -n 1; }
spawn=$(first PostToolUse)
idle=$(first TeammateIdle)
lead=$(jq -r '.session_id // empty' "$spawn" 2>/dev/null)
ad="$JEV_HOME/artifacts/$lead"
[ -n "$spawn" ] && jq -e '.tool_response.status == "teammate_spawned"' "$spawn" >/dev/null &&
  ok "lead: PostToolUse(Agent) status teammate_spawned (team $(jq -r .tool_response.team_name "$spawn"))" || bad "no teammate_spawned PostToolUse"
[ -n "$idle" ] && [ "$(jq -r .session_id "$idle")" != "$lead" ] && jq -e '.teammate_name == "live-writer"' "$idle" >/dev/null &&
  ok "TeammateIdle fired in the teammate's own process (session $(jq -r '.session_id[0:8]' "$idle"), teammate_name live-writer, team_name $(jq -r .team_name "$idle"))" ||
  bad "TeammateIdle: $(cat "$idle" 2>/dev/null)"
[ -f "$ad/live-demo.md" ] && grep -q 'END-OF-LIVE-DEMO' "$ad/live-demo.md" &&
  ok "the teammate's reply is saved in the lead's directory: artifacts/<lead>/live-demo.md" || bad "no live-demo.md: $(find "$JEV_HOME/artifacts" -type f 2>/dev/null)"
grep -q -F "teammate live-writer (reply): $ad/live-demo.md" "$ad/INDEX.md" 2>/dev/null && ok "INDEX.md has its line" || bad "INDEX.md: $(cat "$ad/INDEX.md" 2>/dev/null)"
[ ! -s "$ad/.pending" ] && ok ".pending drained by the lead's next PostToolUse(Agent)" || bad ".pending not drained"
tr -d '\n' <"$SCRATCH/pane.txt" | tr -s ' ' | grep -q 'Teammate live-writer reply saved to' &&
  ok "the lead quotes \"Teammate live-writer reply saved to <path>\"" || bad "the lead never saw the path (pane.txt)"
tr -d '\n' <"$SCRATCH/pane.txt" | tr -s ' ' | grep -q 'Teammate live-writer spawned (model' &&
  ok "the spawn note reads \"Teammate live-writer spawned (model …)\"" || echo "note - the spawn note was not quoted on screen (only the second call's context was asked for)"

{
  echo "# Live agent-team teammate, Claude Code $(claude --version 2>/dev/null | head -n 1), teammate mode tmux"
  echo "# hooks that fired (start order):"
  for f in $(find "$SCRATCH/dump" -name '*.json' | sort); do
    jq -r --arg lead "$lead" '[(if .session_id == $lead then "lead    " else "teammate" end), .hook_event_name,
      (.tool_response.status // .teammate_name // (.prompt // "" | .[0:40] | gsub("\n"; " ")))] | join("  ")' "$f"
  done
  echo
  echo "# TeammateIdle payload:"
  jq -c . "$idle" 2>/dev/null
  echo
  echo "# $ad/INDEX.md:"
  cat "$ad/INDEX.md" 2>/dev/null
  echo
  echo "# live-demo.md:"
  cat "$ad/live-demo.md" 2>/dev/null
  echo
  echo "# artifact.jsonl:"
  cat "$JEV_HOME/log/artifact.jsonl" 2>/dev/null
  echo
  echo "# lead pane, lines naming the teammate or the hook:"
  grep -E 'Teammate|HOOK|saved to|live-writer' "$SCRATCH/pane.txt"
  echo
  echo "live-teammate: $fails failure(s)"
} | sed -e "s#$HOME#~#g" -e "s#/private/tmp#/tmp#g" >"$EVID"
echo "evidence: $EVID"
echo "live-teammate: $fails failure(s)"
[ "$fails" -eq 0 ]
