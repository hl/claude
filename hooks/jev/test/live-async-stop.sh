#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# live-async-stop.sh — does a Stop hook with "async": true run without holding up the
# turn, and is its output ignored? (tmux, interactive claude; JEV_LIVE=1 via run.sh)
#
# The scratch Stop hook logs its start, sleeps 4 s, logs its end and prints a block
# decision asking for the word PINEAPPLE. Asserts: the reply is on screen before the
# hook ends, the hook ran for both turns, and PINEAPPLE never appears. With JEV_LIVE=1
# or JEV_EVIDENCE=1 it rewrites test/evidence/async-stop.txt.
set -uo pipefail
export JEV_MIGRATE=0 # tests never move this machine's real ~/.claude/jev
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S=${JEV_SCRATCH_ASYNC:-/tmp/jev-live-async}
SESS=jeva$$
rm -rf "$S"
mkdir -p "$S/.claude"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
cat >"$S/hook.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
d=$(dirname "$0")
perl -MTime::HiRes=time -e 'printf "%.3f start\n", time' >>"$d/log"
sleep 4
perl -MTime::HiRes=time -e 'printf "%.3f end\n", time' >>"$d/log"
echo '{"decision":"block","reason":"ASYNC-HOOK-OUTPUT: say the word PINEAPPLE"}'
EOF
chmod +x "$S/hook.sh"
jq -n --arg h "$S/hook.sh" '{hooks: {Stop: [{hooks: [{type: "command", command: $h, async: true, timeout: 10}]}]}}' >"$S/.claude/settings.json"

tmux kill-session -t "$SESS" 2>/dev/null
tmux new -d -s "$SESS" -x 200 -y 50 -c "$S" "cd '$S' && claude --setting-sources project --model haiku"
sleep 8
tmux capture-pane -p -t "$SESS" | grep -qi trust && tmux send-keys -t "$SESS" C-m && sleep 3
t0=$(now)
tmux send-keys -t "$SESS" -l "Reply with exactly: DONE1"
sleep 1
tmux send-keys -t "$SESS" C-m
t1=""
for _ in $(seq 1 120); do
  if tmux capture-pane -p -t "$SESS" | grep -q '⏺ DONE1'; then
    t1=$(now)
    break
  fi
  sleep 0.25
done
sleep 7
tmux send-keys -t "$SESS" -l "Reply with exactly: DONE2"
sleep 1
tmux send-keys -t "$SESS" C-m
sleep 12
tmux capture-pane -p -t "$SESS" >"$S/pane.txt"
tmux kill-session -t "$SESS" 2>/dev/null

end1=$(awk '$2 == "end" { print $1; exit }' "$S/log" 2>/dev/null)
starts=$(grep -c start "$S/log" 2>/dev/null || echo 0)
[ -n "$t1" ] && [ -n "$end1" ] && awk -v a="$t1" -v b="$end1" 'BEGIN { exit !(a < b) }' &&
  ok "the reply was on screen at $t1, before the async hook ended at $end1: the turn did not wait" || bad "turn waited for the hook (reply ${t1:-none}, hook end ${end1:-none})"
[ "$starts" -ge 2 ] && ok "the async hook ran after both turns ($starts runs)" || bad "async hook ran $starts times"
grep -q PINEAPPLE "$S/pane.txt" && bad "the async hook's block output was acted on" || ok "its block output was ignored (no PINEAPPLE, no continued turn)"

if [ "${JEV_LIVE:-0}" = 1 ] || [ "${JEV_EVIDENCE:-0}" = 1 ]; then
  {
    echo "# live-async-stop.sh — $(date -u +%Y-%m-%dT%H:%MZ), $(claude --version 2>/dev/null | head -n 1)"
    echo '# Stop hook {"type": "command", "async": true}: logs start, sleeps 4 s, logs end, then prints'
    echo '# {"decision": "block", "reason": "... say the word PINEAPPLE"}. Two prompts in a tmux session (haiku).'
    sed 's/^/hook /' "$S/log"
    echo "prompt 1 sent at $t0; its reply was on screen at ${t1:-never}; the first hook run ended at ${end1:-never}."
    echo "PINEAPPLE in the pane: $(grep -c PINEAPPLE "$S/pane.txt")"
  } >"$HERE/evidence/async-stop.txt"
fi
echo "live-async-stop: $fails failure(s)"
[ "$fails" -eq 0 ]
