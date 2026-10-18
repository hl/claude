#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# live-artifact.sh — real `claude -p` sessions (costs tokens; JEV_LIVE=1 via run.sh).
#
#  1. foreground Agent call with a > 2,000-char result: PostToolUse(Agent) saves it
#     and the parent cites the path it was told ("Subagent result saved to <path>")
#  2. background Agent call (run_in_background): tool_response is async_launched,
#     so SubagentStop saves it
#  3. the Stop hook builds the ledger, which indexes both artifacts
# Records the real Stop, PostToolUse(Agent) and SubagentStop payloads (sanitised:
# $HOME -> ~, long strings cut) as test/evidence/payload-*.json.
# Only project settings are loaded (--setting-sources project), so the user's
# own hooks do not run in the scratch session.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
EVID="$HERE/evidence"
SCRATCH=${JEV_SCRATCH:-/tmp/jev-live-artifact}
mkdir -p "$EVID" "$SCRATCH/.claude" "$SCRATCH/dump"
rm -rf "$SCRATCH/jevhome" "$SCRATCH"/dump/*
export JEV_HOME="$SCRATCH/jevhome"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

cat >"$SCRATCH/dump.sh" <<'EOF'
#!/usr/bin/env bash
ts=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
cat >"$(dirname "$0")/dump/$ts-$1.json"
EOF
chmod +x "$SCRATCH/dump.sh"
jq -n --arg d "$SCRATCH/dump.sh" --arg j "$J" '
  def dump($e): {type: "command", command: "\($d) \($e)"};
  def jev($s): {type: "command", command: "\($j)/\($s)", timeout: 10};
  {hooks: {
    Stop: [{hooks: [dump("Stop"), jev("ledger.sh")]}],
    PostToolUse: [{matcher: "Agent", hooks: [dump("PostToolUse-Agent"), jev("artifact-hook.sh")]}],
    SubagentStop: [{hooks: [dump("SubagentStop"), jev("artifact-hook.sh")]}]}}' >"$SCRATCH/.claude/settings.json"

sanitise() { sed -e "s#$HOME#~#g" -e "s#/private$SCRATCH#<scratch>#g" -e "s#$SCRATCH#<scratch>#g"; }
cut() { jq 'def c: if type == "string" and length > 300 then .[0:300] + " …[\(length) chars]" else . end;
  walk(c)' "$1" | sanitise; }

prompt="Do exactly this, then stop:
1. Use the Agent tool once in the foreground (run_in_background false), subagent_type \"general-purpose\", model \"haiku\", description \"List fruit tastes\", prompt: \"Reply with a numbered list of 40 different fruits, each followed by two full sentences (at least 30 words) describing its taste and texture. Your reply must be at least 4,000 characters. No tools.\"
2. Use the Agent tool once in the background (run_in_background true), subagent_type \"general-purpose\", model \"haiku\", description \"List vegetable tastes\", prompt: \"Reply with a numbered list of 40 different vegetables, each followed by two full sentences (at least 30 words) describing its taste and texture. Your reply must be at least 4,000 characters. No tools.\" Wait for it to finish.
3. Reply with two lines: 'foreground: <the path where the first result was saved, exactly as you were told, or NONE>' and 'background: <the path for the second, or NONE>'."
(cd "$SCRATCH" && timeout 600 claude -p --setting-sources project --model sonnet "$prompt") >"$SCRATCH/reply.txt" 2>&1
reply=$(cat "$SCRATCH/reply.txt")
sid=$(jq -r '.session_id' "$(find "$SCRATCH/dump" -name '*-Stop.json' | sort | tail -n 1)" 2>/dev/null)
adir="$JEV_HOME/artifacts/$sid"

# payload evidence: the first of each kind (foreground PostToolUse, background PostToolUse, SubagentStop, Stop)
fg=$(for f in $(find "$SCRATCH/dump" -name '*-PostToolUse-Agent.json' | sort); do jq -e '.tool_response | type == "object" and .status == "completed"' "$f" >/dev/null 2>&1 && echo "$f"; done | sed -n 1p)
bg=$(for f in $(find "$SCRATCH/dump" -name '*-PostToolUse-Agent.json' | sort); do jq -e '(.tool_response | if type == "string" then fromjson else . end) | .status == "async_launched"' "$f" >/dev/null 2>&1 && echo "$f"; done | sed -n 1p)
ss=$(find "$SCRATCH/dump" -name '*-SubagentStop.json' | sort | sed -n 1p)
st=$(find "$SCRATCH/dump" -name '*-Stop.json' | sort | tail -n 1)
[ -n "$fg" ] && cut "$fg" >"$EVID/payload-PostToolUse-Agent-foreground.json"
[ -n "$bg" ] && cut "$bg" >"$EVID/payload-PostToolUse-Agent-background.json"
[ -n "$ss" ] && cut "$ss" >"$EVID/payload-SubagentStop.json"
[ -n "$st" ] && cut "$st" >"$EVID/payload-Stop.json"

[ -n "$fg" ] && jq -e '.tool_response | (.content | type == "array") and (.agentId | type == "string") and (.resolvedModel | type == "string")' "$fg" >/dev/null &&
  ok "PostToolUse(Agent), foreground: tool_response is an object with status completed, content[], agentId, resolvedModel" || bad "foreground PostToolUse payload not as relied on"
[ -n "$bg" ] && ok "PostToolUse(Agent), background: tool_response status async_launched (no result yet)" || bad "no background PostToolUse payload"
[ -n "$ss" ] && jq -e '(.agent_id | type == "string") and (.agent_type | type == "string") and (.last_assistant_message | type == "string") and has("agent_transcript_path")' "$ss" >/dev/null &&
  ok "SubagentStop: agent_id, agent_type, last_assistant_message, agent_transcript_path present" || bad "SubagentStop payload not as relied on"
[ -n "$st" ] && jq -e '(.session_id | type == "string") and (.transcript_path | type == "string") and has("stop_hook_active") and (has("agent_id") | not)' "$st" >/dev/null &&
  ok "Stop: session_id, transcript_path, stop_hook_active present; no agent_id on the main session" || bad "Stop payload not as relied on"

fgf=$(find "$adir" -name 'agent-*-list-fruit-tastes.md' 2>/dev/null | sed -n 1p)
bgf=$(find "$adir" -name 'agent-*-list-vegetable-tastes.md' 2>/dev/null | sed -n 1p)
[ -n "$fgf" ] && [ "$(wc -c <"$fgf")" -gt 2000 ] && ok "foreground result saved: $(basename "$fgf") ($(wc -c <"$fgf" | tr -d ' ') bytes)" || bad "foreground result not saved"
[ -n "$bgf" ] && ok "background result saved on SubagentStop: $(basename "$bgf")" || bad "background result not saved"
if [ -n "$fgf" ] && grep -qF "$fgf" <<<"$reply"; then
  ok "parent cited the saved path: $(grep -m1 'foreground' <<<"$reply" | sanitise)"
else bad "parent did not cite ${fgf:-the foreground file}: $(sanitise <<<"$reply")"; fi
jq -e -s '[.[] | select(.kind == "artifact")] | length >= 2' "$JEV_HOME/ledger/$sid.jsonl" >/dev/null 2>&1 &&
  ok "ledger indexes both artifacts" || bad "ledger missing artifact facts"
jq -e -s 'any(.[]; .event == "step" and .status == "ok")' "$JEV_HOME/log/ledger.jsonl" >/dev/null 2>&1 &&
  ok "Stop hook ran ledger steps in the live session ($(jq -r -s '[.[] | select(.event == "step") | .status] | join(",")' "$JEV_HOME/log/ledger.jsonl"))" || bad "no ledger step ran"
{
  echo "# live-artifact.sh — $(date -u +%Y-%m-%dT%H:%MZ), $(claude --version 2>/dev/null | head -n 1)"
  echo "## parent's final reply"
  sanitise <<<"$reply"
  echo "## artifacts"
  find "$adir" -name '*.md' -exec sh -c 'printf "%s %s bytes, first line: %s\n" "$1" "$(wc -c <"$1" | tr -d " ")" "$(head -n 1 "$1" | cut -c1-120)"' _ {} \; | sanitise
  echo "## artifact.jsonl"
  sanitise <"$JEV_HOME/log/artifact.jsonl"
  echo "## ledger"
  jq -c '{id, kind, score, text: .text[0:140]}' "$JEV_HOME/ledger/$sid.jsonl" | sanitise
  echo "## parent transcript: hook additionalContext the parent received"
  jq -c 'select(.type == "attachment" and (.attachment.type // "" | test("hook"))) | .attachment | {type, hookEvent, content: (.content | tostring | .[0:200])}' \
    "$(jq -r .transcript_path "$st")" 2>/dev/null | sanitise | grep -i 'saved' | head -n 3
} >"$EVID/artifact-live.txt"
cat "$EVID/artifact-live.txt"
echo "live-artifact: $fails failure(s)"
[ "$fails" -eq 0 ]
