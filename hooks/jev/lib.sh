#!/usr/bin/env bash
# Shared helpers for the Jev (TypeSafe AI) hooks. Source it; don't run it.
#
# Jev is a decision model: one endpoint, typed questions in, typed answers out.
# Everything here fails open: callers get a non-zero return and decide to do
# nothing. The API key is never printed, logged or put on a command line.
#
# Env knobs (all optional):
#   JEV_DISABLED=1         short-circuit every hook and the CLI
#   TYPESAFE_API_KEY       key; else read from `export TYPESAFE_API_KEY=...` in ~/.zshenv
#   JEV_ZSHENV             file to read the key from (default ~/.zshenv)
#   TYPESAFE_BASE_URL      API base (default https://api.typesafe.ai)
#   JEV_MODEL              model (default jev-latest)
#   JEV_TIMEOUT            curl --max-time in seconds (default 8)
#   JEV_LONG_CONTEXT=1     send the long-context header up front (262k, slower)
#   JEV_HOME               state/log root (default ${XDG_STATE_HOME:-~/.local/state}/jev;
#                          an old ~/.claude/jev is moved there once, see below)
#   JEV_MIGRATE=0          never move an old ~/.claude/jev (the tests set this)
#   JEV_COOLDOWN           seconds to skip API calls after a timeout or connection
#                          failure (default 300; 0 disables the breaker)
#   JEV_CHARS_PER_TOKEN    chars-per-token used for the state budget (default 4)
#
# Every request body goes through redact.jq (secrets, Authorization headers,
# secret-named KEY=value, emails, IPv4) inside jev_call, so no caller can send
# unredacted text by accident.

JEV_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# State lives outside ~/.claude: that directory is a public repo and a protected
# directory for Claude Code, so nothing the hooks write should land in it. A
# ~/.claude/jev left by an earlier version is moved once (whole, or entry by
# entry into an existing new home) and replaced by a one-line pointer file.
jev_migrate_home() {
  local old="$HOME/.claude/jev" new=$1 e
  [ -d "$old" ] && [ ! -L "$old" ] || return 0
  mkdir -p "$(dirname "$new")" 2>/dev/null || return 0
  if [ ! -e "$new" ]; then
    mv "$old" "$new" 2>/dev/null || return 0
  else
    for e in "$old"/* "$old"/.[!.]*; do
      [ -e "$e" ] || continue
      [ -e "$new/$(basename "$e")" ] || mv "$e" "$new/" 2>/dev/null || true
    done
    rmdir "$old" 2>/dev/null || return 0
  fi
  printf 'Jev hook state moved to %s (set JEV_HOME to change it); this file can be deleted.\n' "$new" >"$old" 2>/dev/null || true
}
if [ -z "${JEV_HOME:-}" ]; then
  JEV_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/jev"
  [ "${JEV_MIGRATE:-1}" = 0 ] || jev_migrate_home "$JEV_HOME"
fi
JEV_LOG_DIR="$JEV_HOME/log"
JEV_BASE_URL=${TYPESAFE_BASE_URL:-https://api.typesafe.ai}
JEV_MODEL=${JEV_MODEL:-jev-latest}
# Measured ~5.6 chars/token on prose; code, paths and JSON tokenise worse, so
# budget with 4 to stay clear of the 32k-per-question limit.
JEV_CHARS_PER_TOKEN=${JEV_CHARS_PER_TOKEN:-4}
JEV_HOOK=${JEV_HOOK:-jev}
JEV_SESSION=${JEV_SESSION:-}
JEV_KEY=

jev_disabled() { [ "${JEV_DISABLED:-0}" = 1 ]; }

jev_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# jev_log <file-basename> <json-object>: append one line, adding ts/hook/session_id.
# Parallel requests log at the same time and an answer line can exceed the
# size an append writes atomically, so appends take a short mkdir lock
# (given up after ~1 s rather than ever blocking a hook).
jev_log() {
  local file=$1 obj=$2 line i=0 lk
  mkdir -p "$JEV_LOG_DIR" 2>/dev/null || return 0
  line=$(jq -cn --arg ts "$(jev_now)" --arg hook "$JEV_HOOK" --arg sid "$JEV_SESSION" --argjson o "$obj" \
    '{ts: $ts, hook: $hook, session_id: $sid} + $o' 2>/dev/null) || return 0
  lk="$JEV_LOG_DIR/.$file.lock"
  while ! mkdir "$lk" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || break
    sleep 0.02
  done
  printf '%s\n' "$line" >>"$JEV_LOG_DIR/$file" 2>/dev/null || true
  rmdir "$lk" 2>/dev/null || true
}

# jev_load_key: sets JEV_KEY; returns 1 if no key is found.
jev_load_key() {
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then
    JEV_KEY=$TYPESAFE_API_KEY
    return 0
  fi
  local f=${JEV_ZSHENV:-$HOME/.zshenv} line val
  [ -r "$f" ] || return 1
  # Last assignment wins, as it would in the shell. No eval: strip quotes by hand.
  line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?TYPESAFE_API_KEY=' "$f" | tail -n 1) || return 1
  val=${line#*TYPESAFE_API_KEY=}
  val=${val%%[[:space:]]#*}
  val=${val%"${val##*[![:space:]]}"}
  case $val in
    \"*\") val=${val#\"} val=${val%\"} ;;
    \'*\') val=${val#\'} val=${val%\'} ;;
  esac
  case $val in '' | *'$'* | *'`'*) return 1 ;; esac
  JEV_KEY=$val
}

# jev_state_budget_chars [question_tokens]: max chars of state that keep
# state + question under the per-question limit.
jev_state_budget_chars() {
  local qtok=${1:-1000} limit=30000
  [ "${JEV_LONG_CONTEXT:-0}" = 1 ] && limit=250000
  echo $(((limit - qtok) * JEV_CHARS_PER_TOKEN))
}

# Cooldown stamp: epoch of the last timeout/connection failure. While it is
# younger than JEV_COOLDOWN seconds (default 300), jev_call fails fast. One
# stamp per hook family, so a slow routing call does not switch off compaction
# help (and vice versa): $JEV_HOME/cooldown.route, $JEV_HOME/cooldown.compact
# (compaction hooks and the ledger share the state-keeping family).
jev_cooldown_file() {
  case $JEV_HOOK in
    compact-* | ledger*) echo "$JEV_HOME/cooldown.compact" ;;
    *) echo "$JEV_HOME/cooldown.route" ;; # route.sh, agent-route.sh
  esac
}
jev_cooling_down() {
  local t
  t=$(cat "$(jev_cooldown_file)" 2>/dev/null) || return 1
  case $t in '' | *[!0-9]*) return 1 ;; esac
  [ $(($(date +%s) - t)) -lt "${JEV_COOLDOWN:-300}" ]
}
jev_start_cooldown() {
  mkdir -p "$JEV_HOME" 2>/dev/null && date +%s >"$(jev_cooldown_file)" 2>/dev/null || true
}

# redact: text on stdin -> redacted text on stdout (see redact.jq).
redact() { jq -Rrs -L "$JEV_LIB_DIR" 'include "redact"; redact'; }

# jev_lock <dir> [stale-seconds]: take a mkdir lock; returns 1 if another live
# holder has it. mkdir is the lock; <dir>/at records "<epoch> <pid>" right after.
# A lock is broken only when its holder is gone (pid not running) or it is
# older than stale-seconds (default 60). With no `at` yet (a holder between
# mkdir and writing it), the directory's own mtime is its age, so a fresh lock
# is never broken. Breaking renames the directory away first, so of two
# breakers only one can win.
jev_lock() {
  local d=$1 stale=${2:-60} t="" pid="" now
  if mkdir "$d" 2>/dev/null; then
    printf '%s %s\n' "$(date +%s)" "$$" >"$d/at" 2>/dev/null
    return 0
  fi
  now=$(date +%s)
  read -r t pid <"$d/at" 2>/dev/null || true
  case $t in '' | *[!0-9]*)
    t=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo "$now")
    pid=""
    ;;
  esac
  case $pid in *[!0-9]*) pid="" ;; esac
  if [ $((now - t)) -lt "$stale" ] && { [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; }; then
    return 1
  fi
  mv "$d" "$d.broken.$$" 2>/dev/null || return 1
  rm -rf "$d.broken.$$" 2>/dev/null
  mkdir "$d" 2>/dev/null || return 1
  printf '%s %s\n' "$(date +%s)" "$$" >"$d/at" 2>/dev/null
  return 0
}
jev_unlock() { rm -rf "$1" 2>/dev/null || true; }

# jev_call: request body JSON on stdin -> response JSON on stdout.
# Returns non-zero on any failure (no key, network, timeout, HTTP error, missing
# answers). Logs one line per call to jev.jsonl. Retries once with the
# long-context header if the API says max_tokens_exceeded.
jev_call() {
  local body tmp out rc http secs status extra long=${JEV_LONG_CONTEXT:-0} attempt=0 ms
  body=$(cat)
  if jev_disabled; then return 1; fi
  # Redact before anything leaves the machine. A body that fails to parse is
  # not sent at all.
  body=$(jq -c -L "$JEV_LIB_DIR" 'include "redact"; redact_all' <<<"$body" 2>/dev/null) || return 1
  if ! jev_load_key; then
    jev_log jev.jsonl '{"status":"no_key","ms":0}'
    return 1
  fi
  if jev_cooling_down; then
    jev_log jev.jsonl '{"status":"cooldown","ms":0}'
    return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/jev.XXXXXX") || return 1
  while :; do
    attempt=$((attempt + 1))
    extra=()
    [ "$long" = 1 ] && extra=(-H "TypeSafe-Danger-Zone-Long-Context: true")
    rc=0
    out=$(
      printf '%s' "$body" | curl -sS --fail-with-body --max-time "${JEV_TIMEOUT:-8}" \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$JEV_KEY") \
        -H 'Content-Type: application/json' \
        ${extra[@]+"${extra[@]}"} \
        -o "$tmp" -w '%{http_code} %{time_total}' \
        --data-binary @- "$JEV_BASE_URL/v1/systemone" 2>/dev/null
    ) || rc=$?
    http=${out%% *}
    secs=${out#* }
    ms=$(awk -v s="${secs:-0}" 'BEGIN { printf "%d", s * 1000 }' 2>/dev/null || echo 0)
    if [ "$rc" -ne 0 ] && [ "$long" != 1 ] && [ "$attempt" -eq 1 ] &&
      grep -q max_tokens_exceeded "$tmp" 2>/dev/null; then
      jev_log jev.jsonl "$(jq -cn --argjson ms "$ms" '{status: "max_tokens_retry", ms: $ms}')"
      long=1
      continue
    fi
    break
  done

  if [ "$rc" -eq 28 ]; then
    status=timeout
  elif [ "$rc" -ne 0 ]; then
    if [ -n "$http" ] && [ "$http" != 000 ]; then status="http_$http"; else status="curl_$rc"; fi
  elif ! jq -e --argjson q "$(jq -c '.questions | keys' <<<"$body")" \
    '(.answers | type == "object") and ([$q[] as $k | .answers | has($k)] | all)' "$tmp" >/dev/null 2>&1; then
    status=bad_response
  else
    status=ok
  fi
  # Circuit breaker: a hanging or unreachable API should cost one timeout, not
  # one per hook. Timeouts and connection-level failures start a cooldown.
  case $status in
    timeout | curl_6 | curl_7 | curl_35 | curl_52 | curl_56 | http_429 | http_5??) jev_start_cooldown ;;
    ok) rm -f "$(jev_cooldown_file)" 2>/dev/null ;;
  esac

  if [ "$status" = ok ]; then
    jev_log jev.jsonl "$(jq -c --argjson ms "$ms" --arg long "$long" '{
        status: "ok", ms: $ms, long_context: ($long == "1"), model: .model,
        input_tokens: .usage.input_tokens,
        answers: (.answers | map_values(del(.legend, .type)))}' "$tmp")"
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  # Error bodies are API messages, never our state; keep the error type only.
  jev_log jev.jsonl "$(jq -cn --arg s "$status" --argjson ms "${ms:-0}" \
    --arg err "$(jq -r '(.detail | if type == "object" then .error_type elif type == "array" then .[0].type else . end) // empty' "$tmp" 2>/dev/null | head -c 80)" \
    '{status: $s, ms: $ms} + (if $err == "" then {} else {error: $err} end)')"
  rm -f "$tmp"
  return 1
}
