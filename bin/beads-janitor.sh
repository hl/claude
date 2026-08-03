#!/bin/zsh
# beads-janitor — "crons watch, models act": hourly launchd job that finds beads
# repos with in-flight work and dispatches a headless Mnemosyne sweep in each.
# Runs independently of herdr/Ananke; canonical copy lives in ~/.claude/bin,
# launchd unit in ~/.claude/launchd/ai.fates.janitor.plist.
set -u

PROJECTS="${JANITOR_PROJECTS:-$HOME/Projects}"
LOG_DIR="$HOME/.claude/logs"
LOCK="$LOG_DIR/janitor.lock"
mkdir -p "$LOG_DIR"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# One sweep at a time — a slow sweep must not stack on the next tick.
if ! mkdir "$LOCK" 2>/dev/null; then
  log "lock held ($LOCK), skipping tick"
  exit 0
fi
trap 'rmdir "$LOCK"' EXIT

SWEEP_PROMPT='Janitor sweep of this repo. (1) bd prime. (2) For every in_progress bead: find its PR (bead comments, or gh search by bead id). PR merged -> close the bead with the PR link; PR closed unmerged -> bd note the bead as needing redispatch and add label needs-human. (3) Claimed/in_progress beads with no PR and no update in 24h -> bd note them as possibly stale (do NOT unclaim). (4) Sign writes with --actor janitor. Report one line per action taken; take no other action.'

for beads_dir in "$PROJECTS"/*/.beads(N); do
  repo="${beads_dir%/.beads}"
  count=$(bd -C "$repo" count --status in_progress 2>/dev/null | tr -dc '0-9')
  if [[ -z "$count" || "$count" == "0" ]]; then
    continue
  fi
  log "sweeping ${repo##*/} ($count in_progress)"
  (cd "$repo" && claude -p --agent mnemosyne --dangerously-skip-permissions "$SWEEP_PROMPT") 2>&1 | tail -5
  log "done: ${repo##*/}"
done
log "tick complete"
