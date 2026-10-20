#!/usr/bin/env bash
# outcome.sh — record how a routed task went, keyed by route.sh's id.
#
#   outcome.sh <route-id> '{"rounds": 2, "escalated": false, "verdict": "PASS", "final_model": "sonnet"}'
#
# Appends {action: "outcome", id, ...} to ~/.local/state/jev/log/route.jsonl. Fields
# (all optional, others are kept): rounds (review rounds), escalated (true when
# a fresh agent one tier up took over), verdict (the final review verdict, or
# "blocked"), final_model (the model that finished the work). test/tune.sh
# reads these: an escalated or failed route means the routed tier was too low.
# Exits 2 on bad arguments, 0 otherwise. Sends nothing anywhere.
set -euo pipefail
JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JEV_HOOK=outcome
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

id=${1:-}
obj=${2:-}
[ -n "$id" ] && [ -n "$obj" ] || {
  echo "usage: outcome.sh <route-id> '<json object>'" >&2
  exit 2
}
obj=$(jq -c 'if type == "object" then . else error("not an object") end' <<<"$obj" 2>/dev/null) || {
  echo "outcome.sh: second argument must be a JSON object" >&2
  exit 2
}
if ! grep -q "\"id\":\"$id\"" "$JEV_LOG_DIR/route.jsonl" 2>/dev/null; then
  echo "outcome.sh: warning: no route.sh call with id $id in $JEV_LOG_DIR/route.jsonl (recorded anyway)" >&2
fi
jev_log route.jsonl "$(jq -c --arg id "$id" '{action: "outcome", id: $id} + del(.action, .id)' <<<"$obj")"
echo "recorded outcome for $id"
