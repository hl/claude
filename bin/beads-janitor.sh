#!/bin/zsh
# beads-janitor — "crons watch, models act": hourly launchd job that finds beads
# repos with in-flight work and dispatches a headless Mnemosyne sweep in each.
# Runs independently of herdr/Ananke; canonical copy lives in ~/.claude/bin,
# launchd unit in ~/.claude/launchd/ai.fates.janitor.plist.
set -u

PROJECTS="${JANITOR_PROJECTS:-$HOME/Projects}"
LOG_DIR="$HOME/.claude/logs"
LOCK="$LOG_DIR/janitor.lock"
SWEEP_TIMEOUT="${JANITOR_SWEEP_TIMEOUT:-900}"  # seconds per repo sweep
mkdir -p "$LOG_DIR"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# One sweep at a time — a slow sweep must not stack on the next tick. The EXIT
# trap doesn't fire on SIGKILL/power loss, so a held lock is only honored while
# its recorded holder is still alive; otherwise it's reaped.
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then print $$ > "$LOCK/pid"; return 0; fi
  local holder
  holder=$(cat "$LOCK/pid" 2>/dev/null)
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    return 1
  fi
  log "reaping stale lock (holder ${holder:-unknown} is gone)"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null && { print $$ > "$LOCK/pid"; return 0; }
  return 1
}

if ! acquire_lock; then
  log "lock held by live pid $(cat "$LOCK/pid" 2>/dev/null), skipping tick"
  exit 0
fi
trap 'rm -rf "$LOCK"' EXIT

SWEEP_PROMPT='Janitor sweep of this repo. (1) bd prime. (2) For every in_progress bead: find its PR (bead comments, or gh search by bead id). PR merged -> close the bead with the PR link; PR closed unmerged -> bd note the bead as needing redispatch and add label needs-human. (3) Claimed/in_progress beads with no PR and no update in 24h -> bd note them as possibly stale (do NOT unclaim). (4) Sign writes with --actor janitor. Report one line per action taken; take no other action.'

# Run one sweep with a hard deadline — a hung claude must never outlive the tick
# and wedge the lock. Logs the exit code; on timeout, kills and logs loudly.
sweep_repo() {
  local repo=$1 out pid rc waited=0
  out=$(mktemp "$LOG_DIR/sweep.XXXXXX")
  (cd "$repo" && claude -p --agent mnemosyne --dangerously-skip-permissions "$SWEEP_PROMPT") > "$out" 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null && (( waited < SWEEP_TIMEOUT )); do
    sleep 5; (( waited += 5 ))
  done
  if kill -0 $pid 2>/dev/null; then
    kill -TERM $pid 2>/dev/null; sleep 5; kill -KILL $pid 2>/dev/null
    log "KILLED: sweep of ${repo##*/} exceeded ${SWEEP_TIMEOUT}s — investigate $out"
    return 1
  fi
  wait $pid; rc=$?
  if (( rc != 0 )); then
    log "FAILED: sweep of ${repo##*/} exited $rc — output follows"
  fi
  tail -5 "$out"
  (( rc == 0 )) && rm -f "$out"
  return $rc
}

for beads_dir in "$PROJECTS"/*/.beads(N); do
  repo="${beads_dir%/.beads}"
  count=$(bd -C "$repo" count --status in_progress 2>/dev/null | tr -dc '0-9')
  if [[ -z "$count" || "$count" == "0" ]]; then
    continue
  fi
  log "sweeping ${repo##*/} ($count in_progress)"
  sweep_repo "$repo"
  log "done: ${repo##*/}"
done
log "tick complete"
