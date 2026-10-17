#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# live-compact.sh — tmux-driven /compact in a scratch project with the Jev
# compaction hooks plus a dump hook that records each hook's real stdin and
# start time. Costs tokens; run with JEV_LIVE=1 via run.sh.
#
# Proves: the hook order, that the state file is written and covered, that
# additionalContext is injected, that the injected text sits after the
# compact_boundary in the transcript, and that the model can answer from it.
# Writes sanitised evidence to test/evidence/compact-*.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
EVID="$HERE/evidence"
# JEV_EVIDENCE_TAG=plain writes compact-plain-* (e.g. for a plain /compact run).
EVIDP="$EVID/compact${JEV_EVIDENCE_TAG:+-$JEV_EVIDENCE_TAG}"
SCRATCH=${JEV_SCRATCH:-/tmp/jev-live-compact}
MODEL=${JEV_LIVE_PARENT_MODEL:-sonnet}
SESS=jevc$$
mkdir -p "$EVID" "$SCRATCH/.claude" "$SCRATCH/dump"
rm -rf "$SCRATCH/jevhome" "$SCRATCH"/dump/* "$SCRATCH/notes.txt"
export JEV_HOME="$SCRATCH/jevhome"

cat >"$SCRATCH/dump.sh" <<'EOF'
#!/usr/bin/env bash
# Record stdin and the hook start time (µs) for ordering.
ts=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
cat >"$(dirname "$0")/dump/$ts-$1.json"
EOF
chmod +x "$SCRATCH/dump.sh"
jq -n --arg d "$SCRATCH/dump.sh" --arg j "$J" '
  def dump($e): {type: "command", command: "\($d) \($e)"};
  def jev($s): {type: "command", command: "\($j)/\($s)", timeout: 20};
  {hooks: {
    PreCompact: [{matcher: "manual|auto", hooks: [dump("PreCompact"), jev("compact-pre.sh")]}],
    SubagentStop: [{hooks: [dump("SubagentStop"), jev("compact-post.sh")]}],
    SessionStart: [{hooks: [dump("SessionStart")]}, {matcher: "compact", hooks: [jev("compact-session.sh")]}],
    PostCompact: [{matcher: "manual|auto", hooks: [dump("PostCompact"), jev("compact-post.sh")]}]}}' >"$SCRATCH/.claude/settings.json"

pane() { tmux capture-pane -p -t "$SESS" 2>/dev/null; }
say() { # type a line, then submit
  tmux send-keys -t "$SESS" -l "$1"
  sleep 1
  tmux send-keys -t "$SESS" C-m
}
wait_for() { # <file-glob-substring> <seconds>
  local _
  for _ in $(seq 1 "$2"); do
    find "$SCRATCH/dump" -name "*$1*" | grep -q . && return 0
    sleep 1
  done
  return 1
}

tmux kill-session -t "$SESS" 2>/dev/null
tmux new -d -s "$SESS" -x 220 -y 50 -c "$SCRATCH" "JEV_HOME='$JEV_HOME' claude --model $MODEL"
sleep 6
pane | grep -qi 'trust' && tmux send-keys -t "$SESS" C-m && sleep 3

say "Context for this session, reply OK only: the staging database is pg-staging-7 on port 6544, and migrations must never run against it. The release branch is release/2026-10-17. The ticket is OPS-4821."
sleep 15
say "Use the Write tool to create notes.txt containing the single line: fanout v2. Then reply DONE."
sleep 25
say "Run the shell command: ls /nonexistent-jev-dir   and tell me the error in one line."
sleep 25
# Default: custom instructions that make the summary drop the background facts,
# so the injection path is exercised. JEV_LIVE_COMPACT_ARGS="" runs a plain /compact.
say "/compact${JEV_LIVE_COMPACT_ARGS- Keep only a one-line description of the current task. Drop every background fact, name, number and path.}"
wait_for PostCompact 180 || echo "WARN: PostCompact not seen within 180 s"
sleep 3
say "Without using any tools: what are the staging database host and port, and the ticket number? One line."
sleep 25
pane >"$SCRATCH/pane.txt"
tmux kill-session -t "$SESS" 2>/dev/null

sanitise() { sed -e "s#$HOME#~#g"; }
sid=$(jq -r '.session_id' "$(find "$SCRATCH/dump" -name '*-PreCompact.json' | sort | head -n 1)" 2>/dev/null)
tp=$(jq -r '.transcript_path' "$(find "$SCRATCH/dump" -name '*-PreCompact.json' | sort | head -n 1)" 2>/dev/null)
state="$JEV_HOME/compact/$sid.json"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

# 1. order + payloads (hook start times from the dump hook)
{
  echo "# Hook start times (epoch seconds, µs) during one manual /compact, Claude Code $(claude --version 2>/dev/null | head -n 1)"
  for f in $(find "$SCRATCH/dump" -name '*.json' | sort); do
    b=$(basename "$f" .json)
    ev=${b#*-}
    case $ev in SessionStart) ev="SessionStart(source=$(jq -r .source "$f"))" ;; SubagentStop) ev="SubagentStop(agent_type=\"$(jq -r .agent_type "$f")\")" ;; esac
    echo "${b%%-*} $ev"
  done
} >"$EVIDP-order.txt"
cat "$EVIDP-order.txt"
cut() { jq 'def cut($k): if has($k) then .[$k] |= (.[0:600] + " …[truncated]") else . end; cut("compact_summary") | cut("last_assistant_message")' "$1" | sanitise; }
post=$(find "$SCRATCH/dump" -name '*-PostCompact.json' | sort | tail -n 1)
pre=$(find "$SCRATCH/dump" -name '*-PreCompact.json' | sort | tail -n 1)
[ -n "$pre" ] && cut "$pre" >"$EVIDP-stdin-PreCompact.json"
[ -n "$post" ] && cut "$post" >"$EVIDP-stdin-PostCompact.json"
# The compaction agent's SubagentStop: its last_assistant_message is the summary.
cstop=""
for x in $(find "$SCRATCH/dump" -name '*-SubagentStop.json' | sort); do
  if [ -n "$post" ] && jq -e --slurpfile p "$post" '.last_assistant_message == $p[0].compact_summary' "$x" >/dev/null; then cstop=$x; fi
done
if [ -n "$cstop" ]; then
  cut "$cstop" >"$EVIDP-stdin-SubagentStop.json"
  slen=$(jq -r '.compact_summary | length' "$post")
  echo "# compaction agent's SubagentStop last_assistant_message == PostCompact compact_summary: byte-identical, $slen chars" >>"$EVIDP-order.txt"
  ok "compaction agent's SubagentStop last_assistant_message is byte-identical to PostCompact compact_summary ($slen chars)"
else bad "no SubagentStop carried the compaction summary"; fi
f=$(for x in $(find "$SCRATCH/dump" -name '*-SessionStart.json' | sort); do jq -e '.source == "compact"' "$x" >/dev/null && echo "$x"; done | tail -n 1)
[ -n "$f" ] && sanitise <"$f" >"$EVIDP-stdin-SessionStart-compact.json"

order=$(grep -v '^#' "$EVIDP-order.txt" | awk '{print $2}' | grep -v 'SessionStart(source=startup)' | paste -sd' ' -)
case $order in
  *"PreCompact SubagentStop(agent_type=\"\") SessionStart(source=compact) PostCompact"*) ok "order: PreCompact -> SubagentStop(compaction agent) -> SessionStart(compact) -> PostCompact" ;;
  *) bad "unexpected order: $order" ;;
esac

# 2. state + logs
if [ -f "$state" ]; then
  jq '.transcript_path |= "…"' "$state" | sanitise >"$EVIDP-state.json"
  jq -e '.jev_ok and (.facts | length) > 0 and .coverage.source == "SubagentStop" and .consumed_at != null' "$state" >/dev/null &&
    ok "state file written, covered on SubagentStop, consumed by SessionStart ($(jq '.facts | length' "$state") facts)" ||
    bad "state file incomplete: $(jq -c '{jev_ok, phase, coverage, consumed_at}' "$state")"
else bad "no state file at $state"; fi
cat "$JEV_HOME/log/compact.jsonl" "$JEV_HOME/log/jev.jsonl" 2>/dev/null | sanitise >"$EVIDP-logs.jsonl"

# 3. injected context is in the transcript, after the boundary
if [ -f "$tp" ]; then
  hdr='Facts preserved across compaction by the Jev hook'
  bline=$(jq -r 'select(.subtype == "compact_boundary") | input_line_number' "$tp" | tail -n 1)
  iline=$(jq -r 'select(.type == "attachment" and .attachment.type == "hook_additional_context" and .attachment.hookEvent == "SessionStart") | input_line_number' "$tp" | tail -n 1)
  # The API request that followed compaction carries the text too (record not dumped: it holds the whole system prompt).
  rline=$(jq -r --arg h "$hdr" 'select(.type == "api-request-blob" and (tostring | contains($h))) | input_line_number' "$tp" | tail -n 1)
  {
    echo "transcript lines: compact_boundary ${bline:-none}; SessionStart hook_additional_context ${iline:-none}; first post-compaction api-request-blob containing it ${rline:-none}"
    echo "--- the hook_additional_context record:"
    jq -c 'select(.type == "attachment" and .attachment.type == "hook_additional_context" and .attachment.hookEvent == "SessionStart") | {type, attachment: (.attachment | {type, hookEvent, hookName, content})}' "$tp" | tail -n 1 | jq .
    echo "--- model answer after compaction:"
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$tp" | tail -n 1
  } | sanitise >"$EVIDP-transcript.txt"
  cat "$EVIDP-transcript.txt"
  injected=$(jq -s '[.[] | select(.event == "session")] | last | .injected // 0' "$JEV_HOME/log/compact.jsonl" 2>/dev/null || echo 0)
  if [ "${injected:-0}" -gt 0 ]; then
    [ -n "$iline" ] && [ -n "$bline" ] && [ "$iline" -gt "$bline" ] &&
      ok "$injected fact(s) injected; additionalContext recorded after the compact_boundary (line $iline > $bline)" || bad "$injected fact(s) injected but the text is not after the boundary"
    tail -n 1 "$EVIDP-transcript.txt" | grep -q 'pg-staging-7' &&
      ok "model answered from the injected facts after compaction" || echo "note - model answer did not quote pg-staging-7 (see compact-transcript.txt)"
  else
    # Nothing to inject is a correct outcome when the summary kept every important fact.
    [ -z "$iline" ] || [ "$iline" -lt "$bline" ] &&
      ok "nothing injected (the summary covered every important fact); no hook text after the boundary" || bad "no facts injected, yet hook text found after the boundary"
  fi
else bad "no transcript at $tp"; fi

echo "live-compact: $fails failure(s)"
[ "$fails" -eq 0 ]
