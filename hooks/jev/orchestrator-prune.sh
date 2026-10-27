#!/usr/bin/env bash
# orchestrator-prune.sh — keeps .orchestrator.md lean. No Jev call.
#
# Hook (SessionStart; PostToolUse Edit|Write on a file named .orchestrator.md):
#   - a finished section (heading marked DONE / BLOCKED, or Status: done, blocked,
#     merged) shrinks to its heading, stamped " (closed <today>)" the first time;
#     the heading goes too once that stamp is more than JEV_ORCH_KEEP_DAYS (3)
#     days old (an unstamped heading is stamped, never dropped);
#   - what is removed is appended to $JEV_HOME/orchestrator-archive/<path>.md
#     (the file is gitignored, so this is its only history; never swept);
#   - PostToolUse only: tells the session what was pruned (re-read before the
#     next edit) and, when the file is still over JEV_ORCH_MAX_LINES (80), which
#     live sections to condense or close: over JEV_ORCH_SECTION_MAX (20) lines,
#     or dated more than JEV_ORCH_STALE_DAYS (14) ago. SessionStart prunes
#     silently, so sessions that don't maintain the file are not nagged.
#
# CLI: orchestrator-prune.sh [--dry-run] <file>   (prints the report)
#
# JEV_ORCH_PRUNE=0 or JEV_DISABLED=1 turns it off. Writes are atomic (temp file +
# mv) and skipped when the file changed while being pruned. Never fails.
set -uo pipefail
trap 'exit 0' EXIT

JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export JEV_HOOK=orchestrator-prune
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

KEEP_DAYS=${JEV_ORCH_KEEP_DAYS:-3}
STALE_DAYS=${JEV_ORCH_STALE_DAYS:-14}
MAX_LINES=${JEV_ORCH_MAX_LINES:-80}
SECTION_MAX=${JEV_ORCH_SECTION_MAX:-20}

jev_disabled && exit 0
# Byte semantics: a stray invalid UTF-8 byte must not abort awk mid-file.
export LC_ALL=C
[ "${JEV_ORCH_PRUNE:-1}" = 0 ] && exit 0

cli=0 dry=0 event="" orch=""
if [ $# -gt 0 ]; then
  cli=1
  [ "$1" = --dry-run ] && { dry=1; shift; }
  orch=${1:-}
else
  payload=$(cat)
  event=$(jq -r '.hook_event_name // empty' <<<"$payload")
  case $event in
    PostToolUse)
      orch=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
      [ "$(basename "$orch")" = .orchestrator.md ] || exit 0
      ;;
    SessionStart)
      cwd=$(jq -r '.cwd // empty' <<<"$payload")
      for d in "${CLAUDE_PROJECT_DIR:-}" "$cwd"; do
        [ -n "$d" ] && [ -f "$d/.orchestrator.md" ] && { orch="$d/.orchestrator.md"; break; }
      done
      ;;
    *) exit 0 ;;
  esac
fi
[ -n "$orch" ] && [ -f "$orch" ] || exit 0
orch=$(cd "$(dirname "$orch")" && pwd)/.orchestrator.md

# days_ago <n>: the UTC date n days ago (BSD date, then GNU)
days_ago() { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d; }
# keep_cutoff: a finished heading closed before it is dropped; stale_cutoff: a live
# section dated before it is named for closing in the size report.
today=$(days_ago 0)
keep_cutoff=$(days_ago "$KEEP_DAYS")
stale_cutoff=$(days_ago "$STALE_DAYS")
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/jev-orch.XXXXXX") || exit 0
trap 'rm -rf "$tmpd"; exit 0' EXIT

before=$(cksum <"$orch")
awk -v mode=prune -v cutoff="$keep_cutoff" -v today="$today" -f "$JEV_DIR/orchestrator.awk" "$orch" >"$tmpd/tagged" 2>/dev/null || exit 0
grep '^[KCS]' "$tmpd/tagged" | cut -c3- | cat -s >"$tmpd/new"
grep '^[AD]' "$tmpd/tagged" | cut -c3- >"$tmpd/gone"
collapsed=$(grep -c '^[CS]' "$tmpd/tagged")
stamped=$(grep -c '^S' "$tmpd/tagged")
changed=0
cmp -s "$tmpd/new" "$orch" || changed=1
# Already-collapsed headings come back as C (or S) too: count only those that lost a body.
pruned=$(awk -F'\t' '$1 == "C" || $1 == "S" { c = 1; next } $1 == "A" && c { n++; c = 0 } $1 == "D" { c = 0 } $1 == "K" && $2 !~ /^[ \t]*$/ { c = 0 } END { print n + 0 }' "$tmpd/tagged")
dropped=$(grep -c '^D' "$tmpd/tagged")

adir="$JEV_HOME/orchestrator-archive"
archive="$adir/$(printf '%s' "${orch%/.orchestrator.md}" | sed -e 's|^/||' -e 's|[^A-Za-z0-9._-]|_|g').md"
if [ "$changed" = 1 ] && [ "$dry" = 0 ]; then
  lk="$JEV_HOME/.orch-$(printf '%s' "$orch" | cksum | cut -d' ' -f1).lock"
  mkdir -p "$adir" 2>/dev/null && mkdir "$lk" 2>/dev/null || exit 0
  trap 'rmdir "$lk" 2>/dev/null; rm -rf "$tmpd"; exit 0' EXIT
  if [ "$(cksum <"$orch")" = "$before" ]; then
    if [ -s "$tmpd/gone" ]; then
      { printf '\n<!-- archived %s from %s -->\n' "$(jev_now)" "$orch"; cat "$tmpd/gone"; } >>"$archive" || exit 0
    fi
    if ! { cp "$tmpd/new" "$orch.jev-tmp" && mv "$orch.jev-tmp" "$orch"; }; then
      rm -f "$orch.jev-tmp"
      exit 0
    fi
    jev_log orchestrator.jsonl "$(jq -cn --arg f "$orch" --argjson p "$pruned" --argjson d "$dropped" --argjson s "$stamped" \
      --argjson l "$(wc -l <"$tmpd/new" | tr -d ' ')" '{event: "prune", file: $f, collapsed: $p, stamped: $s, dropped: $d, lines: $l}')"
  else
    changed=0
  fi
fi

# --- report on the pruned text
lines=$(wc -l <"$tmpd/new" | tr -d ' ')
msg=""
if [ "$changed" = 1 ] && { [ "$pruned" -gt 0 ] || [ "$dropped" -gt 0 ] || [ "$stamped" -gt 0 ]; }; then
  msg="Pruned .orchestrator.md: $pruned finished section(s) collapsed to their heading, $stamped heading(s) stamped (closed $today), $dropped finished heading(s) closed before $keep_cutoff dropped. Removed text is in $archive. Re-read the file before editing it again."
fi
if [ "$lines" -gt "$MAX_LINES" ]; then
  big=$(awk -v mode=report -f "$JEV_DIR/orchestrator.awk" "$tmpd/new" | awk -F'\t' -v m="$SECTION_MAX" -v c="$stale_cutoff" '
    { h = $2; sub(/^#+[ \t]*/, "", h); d = substr(h, 1, 10)
      if ($1 > m) printf "- %s (%d lines): condense to its live state\n", h, $1
      else if (d ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && d < c) printf "- %s: dated before %s; close it (DONE or BLOCKED: stale) unless still running\n", h, c }' | head -n 12)
  msg="${msg:+$msg }.orchestrator.md is $lines lines (limit $MAX_LINES). Bring it under the limit now, keeping only live state, open items and standing decisions; finished sections are archived automatically once marked DONE or BLOCKED.${big:+
$big}"
fi

if [ "$cli" = 1 ]; then
  tag=""; [ "$dry" = 1 ] && tag=" [dry run]"
  echo "$orch: $lines lines after prune (collapsed $pruned, dropped $dropped, collapsed headings $collapsed)$tag"
  [ -z "$msg" ] || printf '%s\n' "$msg"
elif [ "$event" = PostToolUse ] && [ -n "$msg" ]; then
  jq -cn --arg c "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
fi
exit 0
