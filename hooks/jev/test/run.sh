#!/usr/bin/env bash
# run.sh — every Jev hook test.
#
#   hooks/jev/test/run.sh             offline + API tests (API tests skip without a key)
#   JEV_LIVE=1 hooks/jev/test/run.sh  also drive real Claude Code sessions (tmux + claude -p;
#                                     costs tokens; rewrites test/evidence/)
#
# offline.sh         shellcheck, key parsing, extraction, fail-open matrix (no key, unreachable,
#                    hanging, blackhole, bad key, JEV_DISABLED, JEV_LEDGER=0), circuit breaker
# offline-v2.sh      policy.jq as code; ledger, artifacts and injection against a local fake Jev
# redact.sh          redaction unit tests + planted secrets never reach a captured request body
# route-eval.sh      routing eval: the local real set if ~/.claude/jev/eval/labelled.jsonl exists,
#                    else the committed sanitised fixture; zero opus under-routing, <= 2% sonnet
# agent-route-api.sh escalate / fill / log semantics of the Agent hook
# compact-fixture.sh planted facts + fake summary: omitted facts re-injected, both hook orders, v1 mode
# ledger-fixture.sh  14-turn session, 2 corrections, A-B-A, an artifact, 2 compactions (evidence b)
# ledger-restore.sh  A, B, A again (short and long restatement), 3 runs each, must all pass
# latency.sh         wall time per hook, ledger replayed per turn on the fixture and a real transcript
# live-agent.sh      updatedInput on Agent really changes the subagent model (fill + escalate)
# live-artifact.sh   real Stop / PostToolUse(Agent) / SubagentStop payloads; long results saved and cited
# live-compact.sh    tmux /compact with the Stop ledger: order, injection after the boundary, answer
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
run offline-v2 offline-v2.sh
run redact redact.sh
api=(route-eval agent-route-api compact-fixture ledger-fixture ledger-restore latency)
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
