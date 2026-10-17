#!/usr/bin/env bash
# run.sh — every Jev hook test.
#
#   hooks/jev/test/run.sh             offline + API tests (API tests skip without a key)
#   JEV_LIVE=1 hooks/jev/test/run.sh  also drive real Claude Code sessions (tmux + claude -p;
#                                     costs tokens; rewrites test/evidence/)
#
# offline.sh         shellcheck, key parsing, extraction, fail-open matrix, JEV_DISABLED
# route-eval.sh      labelled routing eval: accuracy >= 80%, zero opus under-routing
# agent-route-api.sh fill / escalate / never-lower / skip semantics of the Agent hook
# compact-fixture.sh planted facts + fake summary: omitted facts re-injected, both hook orders
# latency.sh         wall time per hook against budgets
# live-agent.sh      updatedInput on Agent really changes the subagent model (fill + escalate)
# live-compact.sh    tmux /compact: hook order, state file, injected context after the boundary
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
if [ "${JEV_DISABLED:-0}" = 1 ]; then
  for t in route-eval agent-route-api compact-fixture latency; do skip "$t" "JEV_DISABLED=1"; done
elif jev_load_key; then
  run route-eval route-eval.sh
  run agent-route-api agent-route-api.sh
  run compact-fixture compact-fixture.sh
  run latency latency.sh
else
  for t in route-eval agent-route-api compact-fixture latency; do skip "$t" "no TYPESAFE_API_KEY"; done
fi
if [ "${JEV_LIVE:-0}" = 1 ]; then
  run live-agent live-agent.sh
  run live-compact live-compact.sh
else
  skip live-agent "set JEV_LIVE=1"
  skip live-compact "set JEV_LIVE=1"
fi

echo
echo "=== summary"
printf '%s\n' "${results[@]}"
! printf '%s\n' "${results[@]}" | grep -q '^FAIL'
