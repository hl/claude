#!/usr/bin/env bash
# artifact.sh — save a deliverable (report, review, findings) where it survives
# compaction, and index it in the session's ledger.
#
#   artifact.sh <name> [--from-file <path>] [--session <id>]     (content on stdin otherwise)
#
# Writes ~/.claude/jev/artifacts/<session_id>/<name>.md, prints that path, and
# appends an `artifact` fact to the ledger (so compaction re-injects the index).
# Writing the same name again replaces the file and supersedes the old fact.
#
# Session id, first match wins: --session, $CLAUDE_CODE_SESSION_ID (exported to
# Bash tool commands and hooks by Claude Code 2.1.302, subagents included),
# $CLAUDE_SESSION_ID, the pointer ledger.sh keeps for $CLAUDE_PID, the pointer
# for the current directory (or $CLAUDE_PROJECT_DIR). Exits 2 when none is found.
# Local only: nothing is sent anywhere.
set -euo pipefail
JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JEV_HOOK=artifact
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

usage() {
  echo "usage: artifact.sh <name> [--from-file <path>] [--session <id>]   (content on stdin otherwise)" >&2
  exit 2
}
name=${1:-}
[ -n "$name" ] && [ "${name#-}" = "$name" ] || usage
shift
from="" sid=""
while [ $# -gt 0 ]; do
  case $1 in
    --from-file)
      [ $# -ge 2 ] || usage
      from=$2
      shift 2
      ;;
    --session)
      [ $# -ge 2 ] || usage
      sid=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

pointer() { sed -n 1p "$JEV_HOME/sessions/$1" 2>/dev/null || true; }
cwd_key() { # physical path, as ledger.sh writes it
  local p
  p=$(cd "$1" 2>/dev/null && pwd -P) || p=$1
  printf '%s' "$p" | cksum | cut -d' ' -f1
}
[ -n "$sid" ] || sid=${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}
[ -n "$sid" ] || [ -z "${CLAUDE_PID:-}" ] || sid=$(pointer "pid-$CLAUDE_PID")
[ -n "$sid" ] || sid=$(pointer "cwd-$(cwd_key "$PWD")")
[ -n "$sid" ] || [ -z "${CLAUDE_PROJECT_DIR:-}" ] || sid=$(pointer "cwd-$(cwd_key "$CLAUDE_PROJECT_DIR")")
case $sid in
  '') echo "artifact.sh: no session id (pass --session <id>)" >&2 && exit 2 ;;
  *[!A-Za-z0-9._-]*) echo "artifact.sh: bad session id" >&2 && exit 2 ;;
esac

name=${name%.md}
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/--*/-/g' -e 's/^[-.]*//' | cut -c1-80)
[ -n "$name" ] || usage
dir="$JEV_HOME/artifacts/$sid"
mkdir -p "$dir"
path="$dir/$name.md"
if [ -n "$from" ]; then
  [ -r "$from" ] || {
    echo "artifact.sh: cannot read $from" >&2
    exit 2
  }
  cat "$from" >"$path.tmp"
else
  cat >"$path.tmp"
fi
[ -s "$path.tmp" ] || {
  rm -f "$path.tmp"
  echo "artifact.sh: empty content, nothing saved" >&2
  exit 2
}
mv "$path.tmp" "$path"

# First meaningful line as the title in the index.
title=$(grep -m 1 -v -e '^[[:space:]]*$' -e '^<!--' "$path" | sed -e 's/^#* *//' | cut -c1-120 || true)
"$JEV_DIR/ledger.sh" --add "$sid" artifact 2.5 "Artifact $name: $path${title:+ — $title}" "" "$path" >/dev/null 2>&1 || true
echo "$path"
