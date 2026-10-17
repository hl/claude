#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# offline.sh — no API needed. shellcheck, key parsing, extraction, and the
# fail-open contract: with no key, an unreachable or hanging API, a bad key, or
# JEV_DISABLED=1, every hook exits 0 with no stdout, well inside its timeout.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jev-off.XXXXXX")
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}

# --- shellcheck
if command -v shellcheck >/dev/null; then
  if out=$(shellcheck -x "$J"/*.sh "$HERE"/*.sh 2>&1); then ok "shellcheck clean ($(find "$J" -name '*.sh' | wc -l | tr -d ' ') scripts)"; else
    bad "shellcheck"
    echo "$out"
  fi
else echo "skip - shellcheck not installed"; fi

# --- key lookup from a zshenv-style file (fake keys only)
keytest() { # <file-content> <expected or empty>
  local f="$WORK/zshenv"
  printf "%s\n" "$1" >"$f"
  env -u TYPESAFE_API_KEY JEV_ZSHENV="$f" "$HERE/key-matches.sh" "$2" &&
    ok "key parse: ${1//$'\n'/ | } -> '$2'" || bad "key parse: ${1//$'\n'/ | } (want '$2')"
}
keytest 'export TYPESAFE_API_KEY="apikDOUBLE"' apikDOUBLE
keytest "export TYPESAFE_API_KEY='apikSINGLE'" apikSINGLE
keytest 'TYPESAFE_API_KEY=apikBARE   # comment' apikBARE
keytest $'export TYPESAFE_API_KEY="old"\nexport TYPESAFE_API_KEY="apikLAST"' apikLAST
# shellcheck disable=SC2016 # literal $(...) on purpose: it must be rejected
keytest 'export TYPESAFE_API_KEY="$(security find-generic-password -w)"' ''
keytest 'export OTHER=1' ''

# --- extraction (deterministic, no API)
ex=$("$J/compact-pre.sh" --extract "$FIX/transcript.jsonl")
for want in user decision file url branch error todo; do
  jq -e --arg k "$want" 'any(.facts[]; .kind == $k)' <<<"$ex" >/dev/null && ok "extract: has a '$want' fact" || bad "extract: no '$want' fact"
done
jq -e '[.facts[].text] | (any(test("pg-staging-3")) and any(test("priv/repo/migrations")) and any(test("pull/2417")) and any(test("feat/event-fanout-streams")) and any(test("fanout_streams_enabled")))' <<<"$ex" >/dev/null &&
  ok "extract: planted facts found (incl. queued prompt)" || bad "extract: planted facts missing"
jq -e '([.facts[].text] | any(test("pre-boundary|pull/1111|secret thoughts|Caveat:|system-reminder|Attribution lines"))) or (.tail | test("secret thoughts|huge file content"))' <<<"$ex" >/dev/null &&
  bad "extract: leaked pre-boundary, thinking, meta or reminder text" || ok "extract: skips pre-boundary records, thinking, meta and system-reminders"
jq -e '.facts | (map(.n) == [range(1; length + 1)])' <<<"$ex" >/dev/null && ok "extract: facts numbered 1..N in order" || bad "extract: numbering"
exb=$("$J/compact-pre.sh" --extract "$FIX/transcript-background.jsonl")
jq -e '([.facts[].text] | any(test("/compact"))) or (.tail | test("/compact"))' <<<"$exb" >/dev/null &&
  bad "extract: slash command extracted as a fact" || ok "extract: typed slash commands (/compact ...) are skipped"
exc=$("$J/compact-pre.sh" --extract "$FIX/transcript-carried.jsonl")
jq -e '[.facts[].text] | any(test("/tmp is full")) and (any(test("^User said: /compact")) | not)' <<<"$exc" >/dev/null &&
  ok "extract: keeps a user message starting with a path (\"/tmp is full\"), drops a bare /compact" || bad "extract: slash-command filter wrong"
jq -e '[.facts[] | select(.kind == "carried") | .text] | (length == 2) and (.[0] | test("pg-staging-7"))' <<<"$exc" >/dev/null &&
  ok "extract: facts re-injected by a previous compaction are carried, in order" || bad "extract: carried facts missing"
cap=$(JEV_COMPACT_MAX_FACTS=5 "$J/compact-pre.sh" --extract "$FIX/transcript.jsonl" | jq '.facts | length')
[ "$cap" = 5 ] && ok "extract: JEV_COMPACT_MAX_FACTS caps by recency" || bad "extract: cap gave $cap"

# --- fail-open matrix
cp "$FIX/transcript.jsonl" "$WORK/t.jsonl"
p_pre=$(jq -cn --arg tp "$WORK/t.jsonl" '{session_id: "off", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "auto"}')
p_sub=$(jq -cn --arg m "$(cat "$FIX/summary.txt")" '{session_id: "off-post", hook_event_name: "SubagentStop", agent_type: "", last_assistant_message: $m}')
p_post=$(jq -cn --arg m "$(cat "$FIX/summary.txt")" '{session_id: "off-post", hook_event_name: "PostCompact", trigger: "auto", compact_summary: $m}')
p_sess='{"session_id":"off","hook_event_name":"SessionStart","source":"compact"}'
p_agent='{"session_id":"off","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"x","prompt":"Fix the typo in README.md line 3.","subagent_type":"general-purpose"}}'

# A listener that accepts and never answers, to exercise curl --max-time.
port=$((20000 + RANDOM % 20000))
# The FIFO stays open on fd 9, so nc never sees EOF and nothing is orphaned.
mkfifo "$WORK/ncin"
nc -lk 127.0.0.1 "$port" <"$WORK/ncin" >/dev/null 2>&1 &
ncpid=$!
exec 9>"$WORK/ncin"
sleep 0.3

seed_state() { # <jev-home>: a scored, unconsumed state file for session "off-post"
  mkdir -p "$1/compact"
  jq -c --argjson e "$(date +%s)" '{session_id: "off-post", phase: "pre", jev_ok: true, extracted_epoch: $e,
    facts: [.facts[] | . + {score: 2, legend: "Important"}]}' <<<"$ex" >"$1/compact/off-post.json"
}

failopen() { # <label> <limit-seconds> <env...> -- run every hook
  local label=$1 limit=$2 h p out rc t0 t1 secs
  shift 2
  for hp in "compact-pre.sh:$p_pre" "compact-post.sh:$p_sub" "compact-post.sh:$p_post" "compact-session.sh:$p_sess" "agent-route.sh:$p_agent"; do
    h=${hp%%:*} p=${hp#*:}
    # Give compact-post a valid scored state so it really calls the API.
    [ "$h" = compact-post.sh ] && [ "$label" != disabled ] && seed_state "$WORK/home-$label"
    t0=$(date +%s)
    out=$(env "$@" JEV_HOME="$WORK/home-$label" "$J/$h" <<<"$p" 2>/dev/null)
    rc=$?
    t1=$(date +%s)
    secs=$((t1 - t0))
    if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$secs" -le "$limit" ]; then ok "fail-open [$label] $h: exit 0, no output, ${secs}s"; else bad "fail-open [$label] $h: rc=$rc secs=$secs out=${out:0:120}"; fi
  done
}
failopen no-key 3 -u TYPESAFE_API_KEY JEV_ZSHENV=/dev/null
failopen disabled 3 JEV_DISABLED=1
failopen unreachable 3 TYPESAFE_API_KEY=apikFAKE TYPESAFE_BASE_URL=http://127.0.0.1:9
failopen hanging-api 6 TYPESAFE_API_KEY=apikFAKE TYPESAFE_BASE_URL="http://127.0.0.1:$port" JEV_TIMEOUT=2 JEV_ROUTE_TIMEOUT=2
if [ "${JEV_OFFLINE_BADKEY:-1}" = 1 ]; then
  failopen bad-key 10 TYPESAFE_API_KEY=apikNOTAREALKEY
fi

# circuit breaker: one timeout, then fast failures until JEV_COOLDOWN expires
h="$WORK/home-hanging-api"
jq -e -s '[.[] | .status] | (index("timeout") != null) and (index("cooldown") != null)' "$h/log/jev.jsonl" >/dev/null 2>&1 &&
  ok "circuit breaker: calls after a timeout fail fast (cooldown logged)" || bad "circuit breaker: no cooldown after timeout"
hang() { env TYPESAFE_API_KEY=apikFAKE TYPESAFE_BASE_URL="http://127.0.0.1:$port" JEV_ROUTE_TIMEOUT=2 JEV_HOME="$h" "$@" "$J/agent-route.sh" <<<"$p_agent" >/dev/null 2>&1; }
t0=$(date +%s)
hang
t1=$(date +%s)
hang JEV_COOLDOWN=0
t2=$(date +%s)
[ $((t1 - t0)) -le 1 ] && [ $((t2 - t1)) -ge 2 ] &&
  ok "circuit breaker: skipped call took $((t1 - t0))s; JEV_COOLDOWN=0 calls again ($((t2 - t1))s timeout)" ||
  bad "circuit breaker timing: $((t1 - t0))s / $((t2 - t1))s"
exec 9>&-
kill "$ncpid" 2>/dev/null

# disabled means no API call at all, and no state written
[ ! -e "$WORK/home-disabled/log/jev.jsonl" ] && [ ! -e "$WORK/home-disabled/compact" ] &&
  ok "JEV_DISABLED=1: no API call logged, no state written" || bad "JEV_DISABLED=1 still did work"
# failures are logged with a status, and the key never reaches a log
jq -e -s 'any(.[]; .status == "no_key")' "$WORK/home-no-key/log/jev.jsonl" >/dev/null 2>&1 && ok "no-key failure logged" || bad "no-key failure not logged"
jq -e -s 'any(.[]; .status == "timeout")' "$WORK/home-hanging-api/log/jev.jsonl" >/dev/null 2>&1 && ok "timeout logged" || bad "timeout not logged"
if grep -rq 'apikFAKE\|apikNOTAREALKEY' "$WORK"/home-*; then bad "a key value reached a log or state file"; else ok "no key value in any log or state file"; fi
[ -f "$WORK/home-bad-key/log/jev.jsonl" ] && { jq -e -s 'any(.[]; .status == "http_401")' "$WORK/home-bad-key/log/jev.jsonl" >/dev/null && ok "bad key logged as http_401" || bad "bad key not logged as http_401"; }

# route.sh CLI: non-zero on failure, so callers fall back
env -u TYPESAFE_API_KEY JEV_ZSHENV=/dev/null JEV_HOME="$WORK/h" "$J/route.sh" "x" >/dev/null 2>&1 && bad "route.sh exit 0 without key" || ok "route.sh: non-zero exit without a key"
JEV_DISABLED=1 "$J/route.sh" "x" >/dev/null 2>&1 && bad "route.sh exit 0 when disabled" || ok "route.sh: non-zero exit when disabled"

echo "offline: $fails failure(s)"
[ "$fails" -eq 0 ]
