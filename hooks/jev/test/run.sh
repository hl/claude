#!/usr/bin/env bash
# run.sh — every Jev hook test.
#
#   hooks/jev/test/run.sh             offline + API tests (API tests skip without a key)
#   JEV_LIVE=1 hooks/jev/test/run.sh  also drive real Claude Code sessions (tmux + claude -p;
#                                     costs tokens; rewrites test/evidence/)
#
# offline.sh         shellcheck, key parsing, extraction, fail-open matrix (no key, unreachable,
#                    hanging, blackhole, bad key, JEV_DISABLED), circuit breaker
# offline-hooks.sh   policy.jq as code; route.sh, the Agent hook (scope, skips, route ids),
#                    artifacts, one request per compaction step, injection, sweep (fake Jev)
# zero-traffic.sh    10 turns through every Jev hook in settings.json: 0 requests in an ordinary
#                    project; in a Claudette project only on Agent spawns and compaction
# redact.sh          redaction unit tests + planted secrets never reach a captured request body
# route-eval.sh      routing eval on the committed sanitised fixture (JEV_EVAL_SET=<file> for a
#                    local labelled set); zero opus under-routing, <= 2% sonnet
# agent-route-api.sh escalation, route ids and scope against the live API
# compact-fixture.sh planted facts + fake summary: omitted facts re-injected, both hook orders
# latency.sh         wall time per hook
# live-agent.sh      claude -p with and without .orchestrator.md: scope gate, escalation, and
#                    "Subagent ran on <model>" reaching the parent
# live-artifact.sh   real PostToolUse(Agent) / SubagentStop payloads; results saved and cited
# live-compact.sh    tmux /compact: order, Jev traffic per session, injection after the boundary
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
. "$HERE/../lib.sh"

results=()
run() { # <name> <script>
  echo
  echo "=== $1"
  if "$HERE/$2"; then results+=("PASS  $1"); else results+=("FAIL  $1"); fi
}
skip() { results+=("SKIP  $1 ($2)"); }

run offline offline.sh
run offline-hooks offline-hooks.sh
run zero-traffic zero-traffic.sh
run redact redact.sh
api=(route-eval agent-route-api compact-fixture latency)
if [ "${JEV_DISABLED:-0}" = 1 ]; then
  for t in "${api[@]}"; do skip "$t" "JEV_DISABLED=1"; done
elif jev_load_key; then
  for t in "${api[@]}"; do run "$t" "$t.sh"; done
else
  for t in "${api[@]}"; do skip "$t" "no TYPESAFE_API_KEY"; done
fi
if [ "${JEV_LIVE:-0}" = 1 ]; then
  run live-agent live-agent.sh
  run live-artifact live-artifact.sh
  run live-compact live-compact.sh
else
  for t in live-agent live-artifact live-compact; do skip "$t" "set JEV_LIVE=1"; done
fi

echo
echo "=== summary"
printf '%s\n' "${results[@]}"
! printf '%s\n' "${results[@]}" | grep -q '^FAIL'
